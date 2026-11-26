import Cocoa
import Combine
import SwiftUI

let model = Model(defaults: RunMode.selfTest ? nil : .standard)
var appDelegate: AppDelegate?
func log(_ message:String) { NSLog("[Singularity] %@",message) }

final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate,NSMenuDelegate {
    var pet:PetWindow!
    var view:PetView!
    var settings:NSWindow!
    var status:NSStatusItem!
    private var statusObservation: AnyCancellable?
    let capture=Capture()
    var codexBridge:CodexStateBridge?
    private var preferenceObservation: AnyCancellable?
    private var pendingResize: DispatchWorkItem?
    private func observePreferences() {
        preferenceObservation = model.changes.sink { [weak self] change in
            guard let self else { return }
            switch change {
            case .size:
                self.pendingResize?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.resizePet() }
                self.pendingResize = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
            case .bodyCount:
                self.view?.resetOrbits(); self.resizePet()
            case .drift: self.view?.orbits?.driftEnabled = model.systemDrift
            case .position: self.savePosition()
            case .cadence: self.checkScreen()
            case .codexMode: self.restartCodexBridge()
            case .redraw: break
            }
            self.view?.needsDisplay = true
        }
    }
    private var idleReasons=Set<Capture.Suspension>()
    func applicationDidFinishLaunching(_ notification:Notification) {
        let menu=NSMenu();let top=NSMenuItem();menu.addItem(top);let submenu=NSMenu();top.submenu=submenu
        submenu.addItem(withTitle:"关于奇点",action:#selector(about),keyEquivalent:"");submenu.addItem(withTitle:"设置…",action:#selector(showSettings),keyEquivalent:",");submenu.addItem(.separator());submenu.addItem(withTitle:"退出奇点",action:#selector(quit),keyEquivalent:"q");NSApp.mainMenu=menu
        observePreferences()
        let size=model.sceneSize
        pet=PetWindow(contentRect:NSRect(x:500,y:300,width:size,height:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        pet.title="奇点桌面宠物";pet.isOpaque=false;pet.backgroundColor = .clear;pet.hasShadow=false;pet.level = .floating;pet.hidesOnDeactivate=false;pet.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];pet.isReleasedWhenClosed=false
        guard let renderer = PetView(frame: NSRect(x: 0, y: 0, width: size, height: size), capture: capture) else {
            log("GL_PIXEL_FORMAT_UNAVAILABLE")
            if RunMode.selfTest { exit(1) }
            let alert = NSAlert()
            alert.messageText = "当前图形环境无法显示黑洞"
            alert.informativeText = "没有可用的 OpenGL 像素格式。奇点没有启动桌面采集，也不会更改设置。"
            alert.runModal(); NSApp.terminate(nil); return
        }
        view = renderer; view.autoresizingMask = [.width, .height]; pet.contentView = view
        let prefs = PreferenceReader(defaults: RunMode.selfTest ? nil : .standard)
        let savedX = prefs.coordinate("x"), savedY = prefs.coordinate("y")
        if let screen=NSScreen.main {pet.setFrameOrigin(NSPoint(x:screen.visibleFrame.minX+screen.visibleFrame.width*0.78-size/2,y:screen.visibleFrame.midY-size/2))}
        if let x=savedX,let y=savedY {
            let proposed=NSRect(x:x,y:y,width:size,height:size)
            pet.setFrameOrigin(PetPlacement.recoveredOrigin(for:proposed,screens:petScreens))
        }
        pet.orderFrontRegardless()
        settings = makeSettingsWindow()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusObservation = model.$capturing.combineLatest(model.$codexState).sink { [weak self] connected, activity in
            let name = Self.statusSymbol(connected: connected, activity: activity)
            let desc = "奇点 · \(connected ? "透镜已连接" : "透镜未连接") · \(activity.label)"
            let image = NSImage(systemSymbolName: name, accessibilityDescription: desc)
            image?.isTemplate = true
            self?.status.button?.image = image
            self?.status.button?.toolTip = desc
        }
        status.menu = makeMenu()
        if !RunMode.petOnly { showSettings() }
        if !RunMode.selfTest {
            codexBridge=CodexStateBridge(model:model)
            restartCodexBridge()
        }
        if RunMode.renderOnly {
            model.captureState="离屏渲染自测"
        } else if CGPreflightScreenCaptureAccess(){
            enableCapture(requestPermission:false)
        } else {
            model.captureState="需要屏幕录制权限"
            model.error="真实桌面扭曲需要屏幕录制权限。请在系统设置的屏幕录制权限中允许「奇点」，再点「连接透镜」。"
        }
        NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in self?.screenParametersChanged()}
        let workspace=NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName:NSWorkspace.didLaunchApplicationNotification,object:nil,queue:.main){[weak self] event in
            guard let app=event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier=="com.openai.codex" else{return}
            self?.codexBridge?.refresh()
        }
        let pauses:[(Notification.Name,Capture.Suspension)]=[
            (NSWorkspace.willSleepNotification,.sleep),
            (NSWorkspace.screensDidSleepNotification,.display),
            (NSWorkspace.sessionDidResignActiveNotification,.session)
        ]
        for (event,reason) in pauses {
            workspace.addObserver(forName:event,object:nil,queue:.main){[weak self] _ in
                Task{@MainActor in await self?.suspendActivity(reason)}
            }
        }
        let resumes:[(Notification.Name,Capture.Suspension)]=[
            (NSWorkspace.didWakeNotification,.sleep),
            (NSWorkspace.screensDidWakeNotification,.display),
            (NSWorkspace.sessionDidBecomeActiveNotification,.session)
        ]
        for (event,reason) in resumes {
            workspace.addObserver(forName:event,object:nil,queue:.main){[weak self] _ in
                Task{@MainActor in
                    await self?.resumeActivity(reason)
                }
            }
        }
        log("APP_READY")
        #if SELF_TEST
        if RunMode.selfTest {runSelfTest()}
        #endif
    }
    static func statusSymbol(connected: Bool, activity: CodexActivityState) -> String {
        switch activity {
        case .idle: return connected ? "circle.circle.fill" : "circle.dashed"
        case .thinking: return "sparkles"
        case .command: return "terminal"
        case .longTask: return "hourglass"
        case .complete: return "checkmark.circle"
        case .error: return "exclamationmark.circle"
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !RunMode.selfTest else { return }
        model.captureAuthorized = CGPreflightScreenCaptureAccess()
    }
    func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 790),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "奇点 · 黑洞控制室"
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: SettingsView(state: model))
        window.contentMinSize = NSSize(width: 520, height: 600)
        window.center()
        if !RunMode.selfTest { window.setFrameAutosaveName("Singularity.SettingsWindow") }
        window.delegate = self
        return window
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        menuNeedsUpdate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.target = self; return entry
        }
        func choices(_ title: String, _ names: [String], first: Int, selected: Int, action: Selector) {
            let child = NSMenu(title: title)
            for (i, name) in names.enumerated() {
                let option = child.addItem(withTitle: name, action: action, keyEquivalent: "")
                option.target = self; option.tag = first + i; option.state = option.tag == selected ? .on : .off
            }
            item(title, nil).submenu = child
        }
        item("黑洞设置…", #selector(showSettings), key: ",")
        menu.addItem(.separator())
        item("显示桌宠", #selector(togglePet)).state = model.visible ? .on : .off
        item("暂停流动", #selector(togglePause)).state = model.paused ? .on : .off
        choices("黑洞系统", PetChoices.systems, first: 1, selected: model.bodyCount, action: #selector(selectSystem(_:)))
        choices("吸积盘风格", PetChoices.styles, first: 0, selected: model.style, action: #selector(selectStyle(_:)))
        item("移回屏幕中央", #selector(centerPet))
        menu.addItem(.separator())
        item("Codex：" + model.codexState.label, nil).isEnabled = false
        item("退出奇点", #selector(quit), key: "q")
    }
    @objc private func togglePause() { model.paused.toggle() }
    @objc private func selectSystem(_ item: NSMenuItem) { model.bodyCount = item.tag }
    @objc private func selectStyle(_ item: NSMenuItem) { model.style = item.tag }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {showSettings();return true}
    @objc func showSettings(){
        guard !RunMode.performance else {log("PERFORMANCE_SETTINGS_LOCKED");return}
        if settings?.isMiniaturized==true {settings?.deminiaturize(nil)}
        settings?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        restartCodexBridge()
    }
    func windowWillClose(_ notification:Notification) {
        if notification.object as? NSWindow === settings {restartCodexBridge(settingsVisible:false)}
    }
    func windowDidMiniaturize(_ notification:Notification) {
        if notification.object as? NSWindow === settings {restartCodexBridge()}
    }
    func windowDidDeminiaturize(_ notification:Notification) {
        if notification.object as? NSWindow === settings {restartCodexBridge()}
    }
    @objc func about(){NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"奇点 · Singularity",.applicationVersion:RunMode.version,.credits:NSAttributedString(string:"引力透镜着色器基于 s0xDk/ghostty-blackhole；多体运动使用 Chipmunk2D（MIT）。")])}
    func applicationWillTerminate(_ notification:Notification){ if pendingResize != nil { resizePet() }; model.flushPreferences(); savePosition() }
    @objc func quit(){savePosition();NSApp.terminate(nil)}
    @objc func togglePet(){
        model.visible.toggle()
        if model.visible {
            pet.orderFrontRegardless()
            view.setRenderingActive(idleReasons.isEmpty)
            if CGPreflightScreenCaptureAccess(){enableCapture(requestPermission:false)}
        } else {
            pet.orderOut(nil)
            view.setRenderingActive(false)
            model.capturing=false;model.captureState="桌面透镜已暂停"
            Task{@MainActor in await capture.start(screen:nil)}
        }
        restartCodexBridge()
    }
    @objc func centerPet(){guard pet != nil,let s=NSScreen.main else{return};pet.setFrameOrigin(NSPoint(x:s.visibleFrame.midX-pet.frame.width/2,y:s.visibleFrame.midY-pet.frame.height/2));savePosition()}
    func resizePet(){
        pendingResize?.cancel(); pendingResize = nil
        guard pet != nil else{return}
        let center=NSPoint(x:pet.frame.midX,y:pet.frame.midY),side=model.sceneSize
        var frame=NSRect(x:center.x-side/2,y:center.y-side/2,width:side,height:side)
        frame.origin=PetPlacement.recoveredOrigin(for:frame,screens:petScreens)
        pet.setFrame(frame,display:true);savePosition();checkScreen()
    }
    func savePosition(){guard view != nil,pet != nil,!RunMode.selfTest else{return};UserDefaults.standard.set(pet.frame.minX,forKey:"x");UserDefaults.standard.set(pet.frame.minY,forKey:"y")}
    var petScreens:[PetScreen] {NSScreen.screens.map{PetScreen(frame:$0.frame,visibleFrame:$0.visibleFrame)}}
    func screenParametersChanged(){
        guard pet != nil else{return}
        if !view.dragging {
            let origin=PetPlacement.recoveredOrigin(for:pet.frame,screens:petScreens)
            if origin != pet.frame.origin {pet.setFrameOrigin(origin);savePosition()}
        }
        checkScreen()
    }
    func enableCapture(requestPermission:Bool=true,retryPreferredBackend:Bool=false){guard !RunMode.renderOnly,model.rendererError.isEmpty,model.visible,let screen=pet.screen ?? NSScreen.main else{return};model.captureState="正在连接桌面…";Task{@MainActor in await capture.start(screen:screen,requestPermission:requestPermission,retryPreferredBackend:retryPreferredBackend)}}
    func restartCodexBridge(settingsVisible:Bool?=nil){
        let settingsActive=settingsVisible ?? (settings?.isVisible==true && settings?.isMiniaturized==false)
        if idleReasons.isEmpty {codexBridge?.restartIfNeeded(active:model.visible || settingsActive)}
        else {codexBridge?.stop()}
    }
    @MainActor func suspendActivity(_ reason:Capture.Suspension) async {
        idleReasons.insert(reason)
        view.setRenderingActive(false)
        codexBridge?.stop()
        await capture.suspend(reason)
    }
    @MainActor func resumeActivity(_ reason:Capture.Suspension) async {
        guard idleReasons.remove(reason) != nil else{return}
        if idleReasons.isEmpty {
            view.setRenderingActive(model.visible)
            restartCodexBridge()
        }
        await capture.resume(reason,screen:pet.screen ?? NSScreen.main)
    }
    func checkScreen(){guard capture.wantsCapture,let s=pet.screen ?? NSScreen.main else{return};Task{@MainActor in await capture.retarget(screen:s)}}
    #if SELF_TEST
    func runSelfTest() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await NativeSelfTest.run(self)
        }
    }
    #endif
}
