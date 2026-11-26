import Cocoa
import SwiftUI

// A separate executable and bundle, with no AppDelegate launch, real state bridge,
// screen capture or production preference writes. Snapshots are offscreen; only the mouse
// interaction fixture gets a nonactivating window, ordered behind other windows.
precondition(RunMode.selfTest && CommandLine.arguments.count == 3)
let out = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let coordinator = AppDelegate()
let actualWindow = coordinator.makeSettingsWindow()
precondition(actualWindow.styleMask.contains(.resizable) && actualWindow.level == .normal)
precondition(actualWindow.contentMinSize == NSSize(width: 520, height: 600))
precondition(PetChoices.thumbnails.count == 4 && PetChoices.thumbnails.allSatisfy { $0?.isValid == true })
let menu = coordinator.makeMenu()
model.bodyCount = 2; model.style = 1; model.paused = true
coordinator.menuNeedsUpdate(menu)
precondition(menu.item(withTitle: "显示桌宠")?.state == .on)
model.visible = false; coordinator.menuNeedsUpdate(menu)
precondition(menu.item(withTitle: "显示桌宠")?.state == .off)
model.visible = true; coordinator.menuNeedsUpdate(menu)
precondition(menu.item(withTitle: "暂停流动")?.state == .on)
precondition(menu.item(withTitle: "黑洞系统")?.submenu?.item(withTitle: "双体")?.state == .on)
precondition(menu.item(withTitle: "吸积盘风格")?.submenu?.item(withTitle: "冷蓝")?.state == .on)
precondition(menu.item(withTitle: "Codex：" + model.codexState.label)?.isEnabled == false)

// These use actual AppKit actions and mouse events, not direct writes to the SwiftUI bindings.
func checkSettingsActions() {
    let state = Model(defaults: nil)
    let rect = NSRect(x: 50, y: 50, width: 520, height: 790)
    let host = NSHostingView(rootView: SettingsView(state: state).environment(\.locale, Locale(identifier: "zh_CN")).frame(width: rect.width, height: rect.height))
    let panel = NSPanel(contentRect: rect, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.hidesOnDeactivate = false; panel.appearance = NSAppearance(named: .darkAqua)
    panel.contentView = host; panel.order(.below, relativeTo: 0)
    defer { panel.orderOut(nil) }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.18)); host.layoutSubtreeIfNeeded() }
    func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    func dial(_ name: String) -> NSSlider? { views(host).compactMap { $0 as? NSSlider }.first { $0.accessibilityLabel() == name } }
    settle()
    guard let tabs = views(host).compactMap({ $0 as? NSSegmentedControl }).first(where: { $0.segmentCount == 5 }) else { fatalError("missing five-way navigation") }
    func select(_ index: Int) { tabs.selectedSegment = index; precondition(tabs.sendAction(tabs.action, to: tabs.target)); settle() }
    precondition(tabs.selectedSegment == 0 && dial("黑洞大小") != nil)
    select(1)
    guard let speed = dial("流动速度"), dial("黑洞大小") == nil else { fatalError("motion did not replace appearance") }
    speed.doubleValue = 1.2; precondition(speed.sendAction(speed.action, to: speed.target)); settle()
    precondition(state.speed == 1.2 && speed.accessibilityValueDescription() == "1.2×")
    select(0)
    guard let firstSlider = dial("黑洞大小") else { fatalError("no size control after returning to appearance") }
    let row = host.convert(firstSlider.bounds, from: firstSlider)
    let y = row.midY + (host.isFlipped ? -55 : 55) // thumbnail row immediately above the first slider
    for i in [1, 2, 3, 0] {
        let x = host.bounds.width * (CGFloat(i) + 0.5) / 4
        let pt = host.convert(NSPoint(x: x, y: y), to: nil)
        for (n, kind) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            guard let e = NSEvent.mouseEvent(with: kind, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: n+1, clickCount: 1, pressure: n == 0 ? 1 : 0) else { fatalError("fixture event") }
            NSApp.sendEvent(e) // Local dispatch addressed only to this QA panel; never post a system event.
        }
        settle(); precondition(state.style == i, "clicking card \(i) must update the model")
    }
    print("SETTINGS_ACTIONS_PASS navigation, slider plus accessibility value, four real thumbnail button clicks and menu visibility states")
}

func snap(_ name: String, _ tab: SettingsTab, width: CGFloat = 520, height: CGFloat = 790, setup: (Model) -> Void = { _ in }) throws {
    let state = Model(defaults: nil); setup(state)
    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    let host = NSHostingView(rootView: SettingsView(state: state, initialTab: tab).environment(\.locale, Locale(identifier: "zh_CN")).frame(width: width, height: height))
    let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua); host.appearance = window.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.23)); host.layoutSubtreeIfNeeded()
    func findPreview(_ view: NSView) -> PreviewImageView? {
        if let p = view as? PreviewImageView { return p }
        return view.subviews.lazy.compactMap(findPreview).first
    }
    guard let preview = findPreview(host) else { fatalError("missing native preview") }
    precondition(!preview.isAnimating, "offscreen does not run a timer")
    preview.renderStillForQA(); precondition(preview.frameCount == 1, "real GPU still, not the fallback icon")
    host.layoutSubtreeIfNeeded()
    precondition(host.bounds.size == rect.size)
    guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no backing store") }
    host.cacheDisplay(in: host.bounds, to: image)
    guard let data = image.representation(using: .png, properties: [:]), data.count > 12_000 else { fatalError("empty capture") }
    try data.write(to: out.appendingPathComponent(name + ".png"))
    print("SETTINGS_SNAPSHOT \(name) \(image.pixelsWide)x\(image.pixelsHigh)")
}
try snap("appearance", .appearance)
try snap("appearance-color", .appearance) { $0.customColor = true; $0.colorHex = "#8A5CFF"; $0.kind = 3 }
try snap("motion", .motion) { $0.bodyCount = 3; $0.wander = true }
try snap("codex", .codex)
try snap("codex-manual", .codex, width: 520, height: 600) {
    $0.codexMode = .manual; $0.setCodexState(.command, source: "手动预览")
}
try snap("lens", .lens) {
    $0.captureState = "需要屏幕录制权限"; $0.error = "请在系统设置中允许「奇点」，再点「连接透镜」。"
}
try snap("lens-connected", .lens) { $0.capturing = true; $0.captureAuthorized = true }
try snap("onboarding", .appearance) { $0.showOnboarding() }
try snap("reduce-motion", .motion) { $0.reduceMotion = true; $0.wander = true }
try snap("about", .about)
precondition(AppDelegate.statusSymbol(connected: true, activity: .idle) != AppDelegate.statusSymbol(connected: false, activity: .idle))
for activity in CodexActivityState.allCases { precondition(NSImage(systemSymbolName: AppDelegate.statusSymbol(connected: true, activity: activity), accessibilityDescription: nil) != nil) }
checkSettingsActions()
print("SETTINGS_QA_PASS 5 tabs, minimum window, file/manual states, menus and real SwiftUI captures")
