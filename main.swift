import Cocoa
import SwiftUI
import ScreenCaptureKit
import OpenGL.GL3
import CoreMedia

final class Model: ObservableObject, CodexStateModel {
    @Published var size: Double = UserDefaults.standard.object(forKey: "size") as? Double ?? 440 { didSet { save(); appDelegate?.resizePet() } }
    @Published var lens: Double = UserDefaults.standard.object(forKey: "lens") as? Double ?? 13 { didSet { save() } }
    @Published var speed: Double = UserDefaults.standard.object(forKey: "speed") as? Double ?? 0.6 { didSet { save() } }
    @Published var brightness: Double = UserDefaults.standard.object(forKey: "brightness") as? Double ?? 2.2 { didSet { save() } }
    @Published var tilt: Double = UserDefaults.standard.object(forKey: "tilt") as? Double ?? 1.48 { didSet { save() } }
    @Published var roll: Double = UserDefaults.standard.object(forKey: "roll") as? Double ?? 0.18 { didSet { save() } }
    @Published var style: Int = UserDefaults.standard.integer(forKey:"style") { didSet { save() } }
    @Published var kind = UserDefaults.standard.integer(forKey:"kind") {didSet{save()}}
    @Published var spin = UserDefaults.standard.object(forKey:"spin") as? Double ?? 0.7 {didSet{save()}}
    @Published var charge = UserDefaults.standard.object(forKey:"charge") as? Double ?? 0.5 {didSet{save()}}
    @Published var mass = UserDefaults.standard.object(forKey:"mass") as? Double ?? 1.0 {didSet{save()}}
    @Published var wander = UserDefaults.standard.bool(forKey:"wander") {didSet{save();appDelegate?.savePosition()}}
    @Published var travelSpeed = UserDefaults.standard.object(forKey:"travelSpeed") as? Double ?? 35 {didSet{save()}}
    @Published var customColor = UserDefaults.standard.bool(forKey:"customColor") {didSet{save()}}
    @Published var colorHex = UserDefaults.standard.string(forKey:"colorHex") ?? "#FFAA55" {didSet{save()}}
    @Published var codexAuto = UserDefaults.standard.object(forKey:"codexAuto") as? Bool ?? true { didSet { save(); appDelegate?.codexBridge?.restartIfNeeded() } }
    @Published var backgroundFPS = CaptureCadence.normalized(UserDefaults.standard.integer(forKey:"backgroundFPS")) {
        didSet {
            guard !CommandLine.arguments.contains("--self-test") else{return}
            UserDefaults.standard.set(backgroundFPS,forKey:"backgroundFPS")
            appDelegate?.checkScreen()
        }
    }
    @Published var codexState: CodexActivityState = .idle
    @Published var codexSource = "等待 Codex 桌面状态"
    @Published var codexDetail = ""
    @Published var codexPulse: Double = 0
    var hasSpin:Bool {kind==1 || kind==3}
    var hasCharge:Bool {kind==2 || kind==3}
    var effectiveCharge:Double {hasCharge ? min(charge,sqrt(max(0,0.98*0.98-pow(hasSpin ? spin:0,2)))):0}
    @Published var paused = false {didSet{appDelegate?.view?.needsDisplay=true}}
    @Published var visible = true
    @Published var captureState = "尚未开启桌面透镜"
    @Published var capturing = false
    @Published var error = ""
    func save() { guard !CommandLine.arguments.contains("--self-test") else {return};appDelegate?.view?.needsDisplay=true;let d=UserDefaults.standard; d.set(size,forKey:"size");d.set(lens,forKey:"lens");d.set(speed,forKey:"speed");d.set(brightness,forKey:"brightness");d.set(tilt,forKey:"tilt");d.set(roll,forKey:"roll");d.set(style,forKey:"style");d.set(kind,forKey:"kind");d.set(spin,forKey:"spin");d.set(charge,forKey:"charge");d.set(mass,forKey:"mass");d.set(wander,forKey:"wander");d.set(travelSpeed,forKey:"travelSpeed");d.set(customColor,forKey:"customColor");d.set(colorHex,forKey:"colorHex");d.set(codexAuto,forKey:"codexAuto") }
    func setCodexState(_ next:CodexActivityState,_ source:String,_ detail:String="") {
        let changed = codexState != next
        codexState = next
        codexSource = source
        codexDetail = detail
        if changed {appDelegate?.view?.needsDisplay=true}
        if changed && (next == .complete || next == .error) { codexPulse = 1.0 }
    }
    func setCodexState(_ next:CodexActivityState, source:String, detail:String="") { setCodexState(next, source, detail) }
    func reset() { size=440;lens=13;speed=0.6;brightness=2.2;tilt=1.48;roll=0.18;style=0;kind=0;spin=0.7;charge=0.5;mass=1;wander=false;travelSpeed=35;customColor=false;colorHex="#FFAA55";codexAuto=true;backgroundFPS=10;setCodexState(.idle, source:"等待 Codex 桌面状态");appDelegate?.centerPet() }
}
let model=Model()
var appDelegate: AppDelegate?
func log(_ message:String) { NSLog("[Singularity] %@",message) }

struct CaptureRetryBudget {
    private(set) var attempts=0
    private var healthySince:TimeInterval?
    mutating func connected(at now:TimeInterval) {healthySince=now}
    mutating func reset() {attempts=0;healthySince=nil}
    mutating func nextDelay(at now:TimeInterval)->TimeInterval? {
        // A briefly successful frame must not turn repeated failures into an endless loop.
        if let since=healthySince,now-since >= 30 {attempts=0}
        healthySince=nil
        let delays:[TimeInterval]=[1,2,4,8,16]
        guard attempts < delays.count else{return nil}
        defer{attempts+=1}
        return delays[attempts]
    }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Snapshot {
        let buffer: CVPixelBuffer
        let rect: CGRect
    }
    var stream: SCStream?
    let lock=NSLock()
    var frame: CVPixelBuffer?
    private var frameRect=CGRect.zero
    private var frameDisplayRect=CGRect.zero
    private var frameDisplayBounds=CGRect.zero
    private var frameUsesRegion=false
    var screenRect=CGRect.zero
    var displayID: CGDirectDisplayID=0
    var busy=false
    private var requestedScreen:NSScreen?
    private var requestedDisplayID:NSNumber?
    private var requestedRect=CGRect.zero
    private var requestSerial:UInt64=0
    private var frameStream:SCStream?
    private var startedStream:SCStream?
    private var requestPermission=false
    enum Suspension:Hashable {case sleep,display,session}
    private var suspensions=Set<Suspension>()
    private var suspended:Bool {!suspensions.isEmpty}
    private var retryTask:Task<Void,Never>?
    private var firstFrameTask:Task<Void,Never>?
    private var retryBudget=CaptureRetryBudget()
    private var regionAvailable=true
    private var desiredRegion=CGRect.zero
    private var pendingRegion:CGRect?
    private var regionUpdateID:UUID?
    private var captureScale:CGFloat=1
    private var wasDragging=false
    private var screenshotTask:Task<Void,Never>?
    private var screenshotWait:Task<Void,Error>?
    private var screenshotDeadline:Task<Void,Never>?
    private var screenshotAvailable=true
    private(set) var screenshotRequests=0
    private(set) var unchangedScreenshots=0
    private(set) var comparisonMilliseconds=[Double]()
    private var adaptiveCadence=AdaptiveCaptureCadence()
    var adaptiveSampling=true
    var selfTestScreenshotDelay:UInt64=0
    var selfTestStreamStartDelay:UInt64=0
    private(set) var activeID:UUID?
    private(set) var appliedFramesPerSecond=0
    private var desiredFramesPerSecond=0
    private(set) var configurationUpdates=0
    var forceFullDisplay=ProcessInfo.processInfo.environment["SINGULARITY_CAPTURE_FULL_DISPLAY"]=="1"
    var forceStream=ProcessInfo.processInfo.environment["SINGULARITY_CAPTURE_BACKEND"]=="stream"
    var benchmarkWindowFilter=false
    var benchmarkNominalResolution=false
    var framesPerSecond:Int?
    private var usesScreenshots:Bool {
        if #available(macOS 14.0, *) {return screenshotAvailable && !forceStream}
        return false
    }
    private var preferredFramesPerSecond:Int {
        CaptureCadence.rate(preferred:framesPerSecond ?? model.backgroundFPS,dragging:appDelegate?.view.dragging ?? false)
    }
    private var usesRegion:Bool {
        if #available(macOS 13.1, *) {return regionAvailable && !forceFullDisplay}
        return false
    }
    var wantsCapture:Bool {requestedScreen != nil}
    var retryPending:Bool {retryTask != nil}

    private func record(_ message:String) {
        log(message)
        guard !CommandLine.arguments.contains("--self-test") else{return}
        // Persist only lifecycle metadata, never frames or window/application titles.
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Singularity")
        let file=directory.appendingPathComponent("capture.log")
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            var data=(try? Data(contentsOf:file)) ?? Data()
            if data.count > 65_536 {data=Data()}
            data.append(Data("\(ISO8601DateFormatter().string(from:Date())) \(message)\n".utf8))
            try data.write(to:file,options:.atomic)
        } catch {log("CAPTURE_LOG_UNAVAILABLE")}
    }
    static func isRecoverable(_ error:Error)->Bool {
        let e=error as NSError
        if e.domain == "Singularity.Capture" {return (1...4).contains(e.code)}
        guard e.domain == SCStreamErrorDomain else{return false}
        switch SCStreamError.Code(rawValue:e.code) {
        case .failedToStart, .failedApplicationConnectionInvalid,
             .failedApplicationConnectionInterrupted, .failedNoMatchingApplicationContext,
             .internalError, .noWindowList, .noDisplayList, .noCaptureSource:
            return true
        default:
            // User refusal/stop, system stop and unknown errors require an explicit reconnect.
            return false
        }
    }
    private func captureError(_ code:Int,_ description:String)->NSError {
        NSError(domain:"Singularity.Capture",code:code,userInfo:[NSLocalizedDescriptionKey:description])
    }
    private func acceptFrames(from source:SCStream?,screen:NSScreen?=nil,region:Bool=false) {
        lock.lock();defer{lock.unlock()}
        frame=nil;frameRect = .zero;frameStream=source;frameUsesRegion=region
        if let screen {
            frameDisplayRect=screen.frame
            let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            frameDisplayBounds=CGDisplayBounds(id)
        }
    }
    @MainActor private func cancelPending() {
        retryTask?.cancel();retryTask=nil
        firstFrameTask?.cancel();firstFrameTask=nil
        screenshotDeadline?.cancel();screenshotDeadline=nil
        screenshotWait?.cancel();screenshotWait=nil
        pendingRegion=nil;regionUpdateID=nil
    }
    @MainActor func start(screen:NSScreen?,requestPermission:Bool=true) async {
        cancelPending();retryBudget.reset()
        self.requestPermission=requestPermission
        requestedScreen=screen;requestSerial &+= 1
        requestedDisplayID=screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        requestedRect=screen?.frame ?? .zero
        await reconcile()
    }
    @MainActor func suspend(_ reason:Suspension = .sleep) async {
        let wasSuspended=suspended
        suspensions.insert(reason)
        guard wantsCapture,!wasSuspended else{return}
        cancelPending();requestSerial &+= 1
        await reconcile()
    }
    @MainActor func resume(_ reason:Suspension = .sleep,screen:NSScreen?) async {
        guard suspensions.remove(reason) != nil,!suspended else{return}
        guard wantsCapture,let screen else{return}
        await start(screen:screen,requestPermission:false)
    }
    @MainActor func retarget(screen:NSScreen) async {
        guard wantsCapture else{return}
        let key=NSDeviceDescriptionKey("NSScreenNumber")
        if requestedDisplayID != screen.deviceDescription[key] as? NSNumber || requestedRect != screen.frame {
            await start(screen:screen,requestPermission:false)
            return
        }
        guard activeID != nil,let pet=appDelegate?.pet else{return}
        if screenshotTask==nil {
            guard let current=stream,startedStream === current else{return}
        }
        let dragging=appDelegate?.view.dragging ?? false
        let region=dragging || !usesRegion ? screen.frame :
            CaptureRegion.region(for:pet.frame,on:screen.frame,retaining:wasDragging ? nil:desiredRegion)
        wasDragging=dragging
        let fps=preferredFramesPerSecond
        guard region != desiredRegion || fps != desiredFramesPerSecond else{return}
        desiredRegion=region;desiredFramesPerSecond=fps
        if screenshotTask != nil {
            configurationUpdates+=1;adaptiveCadence.reset()
            screenshotWait?.cancel()
            return
        }
        guard let current=stream,startedStream === current else{return}
        pendingRegion=region
        guard regionUpdateID==nil else{return}
        let updateID=UUID(),serial=requestSerial
        regionUpdateID=updateID
        defer {if regionUpdateID==updateID {regionUpdateID=nil}}
        // Coalesce moves while ScreenCaptureKit applies a previous crop. Each frame
        // carries its own screen rect, so queued frames never use a newer crop origin.
        while regionUpdateID==updateID,let next=pendingRegion {
            pendingRegion=nil
            let nextFPS=desiredFramesPerSecond
            do {try await current.updateConfiguration(configuration(region:next,screen:screen))}
            catch {
                guard regionUpdateID==updateID,serial==requestSerial,stream === current else{return}
                regionAvailable=false
                record("CAPTURE_REGION_FALLBACK configuration")
                await start(screen:screen,requestPermission:false)
                return
            }
            guard regionUpdateID==updateID,serial==requestSerial,stream === current else{return}
            screenRect=next;appliedFramesPerSecond=nextFPS;configurationUpdates+=1
        }
    }
    @MainActor private func configuration(region:CGRect,screen:NSScreen)->SCStreamConfiguration {
        let config=SCStreamConfiguration()
        if #available(macOS 14.0, *),benchmarkNominalResolution {config.captureResolution = .nominal}
        config.sourceRect=CaptureRegion.sourceRect(region,on:screen.frame)
        config.width=max(1,Int((region.width*captureScale).rounded(.up)))
        config.height=max(1,Int((region.height*captureScale).rounded(.up)))
        config.pixelFormat=kCVPixelFormatType_32BGRA
        config.minimumFrameInterval=CMTime(value:1,timescale:CMTimeScale(preferredFramesPerSecond))
        config.queueDepth=3;config.showsCursor=false;config.capturesAudio=false
        return config
    }
    @MainActor private func reconcile() async {
        guard !busy else {return}
        busy=true;defer{busy=false}
        // Coalesce rapid hide/show/reconnect requests, but never drop the last one.
        while true {
            let serial=requestSerial
            await transition(to:suspended ? nil:requestedScreen,serial:serial)
            if serial == requestSerial {break}
        }
    }
    @MainActor private func transition(to screen:NSScreen?,serial:UInt64) async {
        let old=stream;stream=nil;startedStream=nil;activeID=nil
        screenshotWait?.cancel();screenshotWait=nil;adaptiveCadence.reset()
        screenshotTask?.cancel();screenshotTask=nil;acceptFrames(from:nil)
        model.capturing=false
        if let old {try? await old.stopCapture()}
        guard serial == requestSerial else {return}
        guard let screen else {
            model.captureState=suspended ? "等待桌面恢复":"桌面透镜已暂停";model.error=""
            record("CAPTURE_PAUSED")
            return
        }
        model.captureState="正在连接桌面…"
        do {
            if !CGPreflightScreenCaptureAccess() {
                if requestPermission {
                    log("PERMISSION_REQUEST bundle=\(Bundle.main.bundleIdentifier ?? "unknown") path=\(Bundle.main.bundlePath)")
                }
                guard requestPermission && CGRequestScreenCaptureAccess() else {
                    throw NSError(domain:SCStreamErrorDomain,code:SCStreamError.Code.userDeclined.rawValue)
                }
            }
            requestPermission=false
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
            guard serial == requestSerial else {return}
            let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            guard let display=content.displays.first(where:{$0.displayID==id}) else {throw captureError(1,"显示器暂不可用")}
            // Application exclusion survives hidden/new windows and prevents feedback
            // before WindowServer's on-screen window list has caught up.
            let own=content.applications.filter{$0.processID == ProcessInfo.processInfo.processIdentifier}
            guard !own.isEmpty else {throw captureError(2,"应用窗口尚未就绪")}
            let filter=benchmarkWindowFilter ?
                SCContentFilter(display:display,excludingWindows:content.windows.filter{$0.owningApplication?.processID==getpid()}) :
                SCContentFilter(display:display,excludingApplications:own,exceptingWindows:[])
            captureScale=screen.backingScaleFactor
            if #available(macOS 14.0, *) {captureScale=CGFloat(filter.pointPixelScale)}
            if !captureScale.isFinite || captureScale<=0 {captureScale=max(1,screen.backingScaleFactor)}
            let dragging=appDelegate?.view.dragging ?? false
            let region=usesRegion && !dragging ? CaptureRegion.region(for:appDelegate?.pet.frame ?? screen.frame,on:screen.frame):screen.frame
            desiredRegion=region
            desiredFramesPerSecond=preferredFramesPerSecond
            wasDragging=dragging
            let config=configuration(region:region,screen:screen)
            activeID=UUID()
            screenRect=region;displayID=id
            if #available(macOS 14.0, *),usesScreenshots {
                startScreenshots(filter:filter,screen:screen,serial:serial)
                record("CAPTURE_STARTED backend=screenshot display=\(id) excludedApps=\(own.count) pixels=\(config.width)x\(config.height) region=\(usesRegion)")
                watchForFirstFrame(serial:serial)
                return
            }
            let next=SCStream(filter:filter,configuration:config,delegate:self)
            try next.addStreamOutput(self,type:.screen,sampleHandlerQueue:DispatchQueue(label:"singularity.capture"))
            screenRect=region;displayID=id;stream=next
            acceptFrames(from:next,screen:screen,region:usesRegion)
            try await next.startCapture()
            if CommandLine.arguments.contains("--self-test"),selfTestStreamStartDelay>0 {
                try await Task.sleep(nanoseconds:selfTestStreamStartDelay)
            }
            guard serial == requestSerial,stream === next else {return}
            startedStream=next
            appliedFramesPerSecond=Int(config.minimumFrameInterval.timescale)
            await retarget(screen:screen)
            guard serial == requestSerial,stream === next else {return}
            if !model.capturing {
                model.captureState="等待桌面画面…"
                if latest() != nil {receivedFirstFrame(from:next)}
                else {watchForFirstFrame(serial:serial)}
            }
            record("CAPTURE_STARTED backend=stream display=\(id) excludedApps=\(own.count) pixels=\(config.width)x\(config.height) region=\(usesRegion)")
        } catch {
            guard serial == requestSerial else {return}
            // The delegate may already have handled a failure during startCapture().
            guard retryTask == nil,wantsCapture else{return}
            failed(error,serial:serial)
        }
    }
    @MainActor private func watchForFirstFrame(serial:UInt64) {
        firstFrameTask=Task{@MainActor [weak self] in
            do {try await Task.sleep(nanoseconds:8_000_000_000)} catch {return}
            guard let self,self.activeID != nil,serial==self.requestSerial,!model.capturing else{return}
            if self.screenshotTask != nil {self.screenshotAvailable=false}
            self.failed(self.captureError(3,"连接后未收到桌面画面"),serial:serial)
        }
    }
    @available(macOS 14.0, *)
    @MainActor private func startScreenshots(filter:SCContentFilter,screen:NSScreen,serial:UInt64) {
        let sourceID=activeID
        screenshotTask=Task{@MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,self.activeID==sourceID,self.requestSerial==serial else{return}
                let began=ProcessInfo.processInfo.systemUptime
                let region=self.desiredRegion
                let revision=self.configurationUpdates
                let config=self.configuration(region:region,screen:screen)
                self.screenshotRequests+=1
                self.screenshotDeadline=Task{@MainActor [weak self] in
                    do {try await Task.sleep(nanoseconds:3_000_000_000)} catch {return}
                    guard let self,self.activeID==sourceID,self.requestSerial==serial else{return}
                    self.screenshotAvailable=false
                    self.record("CAPTURE_SCREENSHOT_FALLBACK timeout")
                    self.failed(self.captureError(4,"桌面快照请求超时"),serial:serial)
                }
                do {
                    let sample=try await SCScreenshotManager.captureSampleBuffer(contentFilter:filter,configuration:config)
                    if CommandLine.arguments.contains("--self-test"),self.selfTestScreenshotDelay>0 {
                        try await Task.sleep(nanoseconds:self.selfTestScreenshotDelay)
                    }
                    guard !Task.isCancelled,self.activeID==sourceID,self.requestSerial==serial else{return}
                    self.screenshotDeadline?.cancel();self.screenshotDeadline=nil
                    guard let image=CMSampleBufferGetImageBuffer(sample) else {
                        throw self.captureError(4,"桌面快照没有有效图像")
                    }
                    let next=Snapshot(buffer:image,rect:region)
                    let preferred=self.preferredFramesPerSecond
                    let adaptive=self.adaptiveSampling && preferred==10
                    let comparisonStart=ProcessInfo.processInfo.systemUptime
                    let unchanged=adaptive && self.latestSnapshot().map{Self.samePixels($0,next)}==true
                    if adaptive,!unchanged,CommandLine.arguments.contains("--self-test"),
                       ProcessInfo.processInfo.environment["SINGULARITY_CAPTURE_DIAGNOSTICS"]=="1" {
                        log("CAPTURE_PIXELS_CHANGED uptime=\(ProcessInfo.processInfo.systemUptime) rect=\(region)")
                    }
                    if adaptive,CommandLine.arguments.contains("--self-test-performance"),self.comparisonMilliseconds.count<10_000 {
                        self.comparisonMilliseconds.append((ProcessInfo.processInfo.systemUptime-comparisonStart)*1000)
                    }
                    if unchanged {self.unchangedScreenshots+=1}
                    else {self.acceptSnapshot(next)}
                    self.screenRect=region
                    let fps=adaptive ? self.adaptiveCadence.rate(preferred:preferred,dragging:false,
                        changed:!unchanged,now:ProcessInfo.processInfo.systemUptime):preferred
                    self.appliedFramesPerSecond=fps
                    self.receivedFirstFrame(serial:serial)
                    // A move or preference change during capture must not wait at idle cadence.
                    if self.configurationUpdates != revision {continue}
                    let delay=max(0,1.0/Double(fps)-(ProcessInfo.processInfo.systemUptime-began))
                    let wait=Task {try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))}
                    self.screenshotWait=wait
                    try? await wait.value
                    guard !Task.isCancelled,self.activeID==sourceID,self.requestSerial==serial else{return}
                    self.screenshotWait=nil
                } catch {
                    guard !Task.isCancelled,self.activeID==sourceID,self.requestSerial==serial else{return}
                    self.screenshotDeadline?.cancel();self.screenshotDeadline=nil
                    // Unsupported snapshot paths fall back once; permission/user-stop
                    // errors still obey the same terminal policy as the stream backend.
                    if (error as NSError).domain=="Singularity.Capture" || Self.isRecoverable(error) {
                        self.screenshotAvailable=false
                        self.record("CAPTURE_SCREENSHOT_FALLBACK")
                    }
                    self.failed(error,serial:serial)
                    return
                }
            }
        }
    }
    static func samePixels(_ a:Snapshot,_ b:Snapshot)->Bool {
        guard a.rect==b.rect,
              CVPixelBufferGetPixelFormatType(a.buffer)==kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(b.buffer)==kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(a.buffer)==CVPixelBufferGetWidth(b.buffer),
              CVPixelBufferGetHeight(a.buffer)==CVPixelBufferGetHeight(b.buffer) else{return false}
        if a.buffer === b.buffer {return true}
        guard CVPixelBufferLockBaseAddress(a.buffer,.readOnly)==kCVReturnSuccess else{return false}
        defer {CVPixelBufferUnlockBaseAddress(a.buffer,.readOnly)}
        guard CVPixelBufferLockBaseAddress(b.buffer,.readOnly)==kCVReturnSuccess else{return false}
        defer {CVPixelBufferUnlockBaseAddress(b.buffer,.readOnly)}
        guard let lhs=CVPixelBufferGetBaseAddress(a.buffer),let rhs=CVPixelBufferGetBaseAddress(b.buffer) else{return false}
        let bytes=CVPixelBufferGetWidth(a.buffer)*4
        let leftStride=CVPixelBufferGetBytesPerRow(a.buffer),rightStride=CVPixelBufferGetBytesPerRow(b.buffer)
        guard bytes>0,leftStride>=bytes,rightStride>=bytes else{return false}
        // Padding is not image content and may change even on an unchanged desktop.
        for row in 0..<CVPixelBufferGetHeight(a.buffer) {
            if memcmp(lhs.advanced(by:row*leftStride),rhs.advanced(by:row*rightStride),bytes) != 0 {return false}
        }
        return true
    }
    private func acceptSnapshot(_ snapshot:Snapshot) {
        lock.lock();defer{lock.unlock()}
        frame=snapshot.buffer;frameRect=snapshot.rect
    }
    @MainActor private func receivedFirstFrame(from source:SCStream) {
        guard stream === source,startedStream === source,!model.capturing else{return}
        receivedFirstFrame(serial:requestSerial)
    }
    @MainActor private func receivedFirstFrame(serial:UInt64) {
        guard serial==requestSerial,activeID != nil,!model.capturing else{return}
        firstFrameTask?.cancel();firstFrameTask=nil
        model.capturing=true;model.captureState="桌面透镜已连接";model.error=""
        retryBudget.connected(at:ProcessInfo.processInfo.systemUptime)
        record("CAPTURE_FIRST_FRAME display=\(displayID)")
        appDelegate?.checkScreen()
    }
    @MainActor private func failed(_ error:Error,serial:UInt64) {
        guard serial == requestSerial else{return}
        let retired=stream
        stream=nil;startedStream=nil;activeID=nil
        screenshotTask?.cancel();screenshotTask=nil
        acceptFrames(from:nil);cancelPending()
        model.capturing=false;requestPermission=false
        let e=error as NSError
        record("CAPTURE_FAILURE domain=\(e.domain) code=\(e.code) display=\(displayID)")
        let stopped=Task {if let retired {try? await retired.stopCapture()}}
        guard wantsCapture,!suspended else{return}
        guard Self.isRecoverable(error),CGPreflightScreenCaptureAccess() else {
            requestedScreen=nil
            model.captureState="桌面采集已停止"
            model.error="请检查屏幕录制权限，然后点击「开启桌面透镜」。(\(e.domain) \(e.code))"
            return
        }
        guard let delay=retryBudget.nextDelay(at:ProcessInfo.processInfo.systemUptime) else {
            requestedScreen=nil
            model.captureState="桌面重连未成功"
            model.error="已尝试 5 次，请检查显示器与录屏权限后手动重连。(\(e.domain) \(e.code))"
            record("CAPTURE_RETRY_EXHAUSTED")
            return
        }
        model.captureState="桌面连接中断，\(Int(delay)) 秒后重连（\(retryBudget.attempts)/5）"
        model.error=""
        record("CAPTURE_RETRY attempt=\(retryBudget.attempts) delay=\(delay)")
        retryTask=Task{@MainActor [weak self] in
            do {try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))} catch {return}
            await stopped.value
            guard !Task.isCancelled,let self,serial == self.requestSerial,self.wantsCapture,!self.suspended else{return}
            self.retryTask=nil;self.requestSerial &+= 1
            await self.reconcile()
        }
    }
    func stream(_ stream:SCStream,didOutputSampleBuffer buffer:CMSampleBuffer,of type:SCStreamOutputType) {
        guard type == .screen,buffer.isValid, let image=CMSampleBufferGetImageBuffer(buffer) else{return}
        guard let attachments=CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],let raw=attachments.first?[.status] as? Int,raw==SCFrameStatus.complete.rawValue else{return}
        lock.lock()
        guard stream === frameStream else {lock.unlock();return}
        var rect=frameDisplayRect
        if frameUsesRegion {
            var reported:CGRect?
            if #available(macOS 13.1, *),
               let dictionary=attachments.first?[.screenRect] as? [String:Any] {
                reported=CGRect(dictionaryRepresentation:dictionary as CFDictionary)
            }
            guard let reported,let mapped=CaptureRegion.globalRect(reported,on:frameDisplayRect,displayBounds:frameDisplayBounds) else {
                lock.unlock()
                Task{@MainActor in
                    guard self.stream === stream,self.regionAvailable,let screen=self.requestedScreen else{return}
                    self.regionAvailable=false
                    self.record("CAPTURE_REGION_FALLBACK metadata")
                    await self.start(screen:screen,requestPermission:false)
                }
                return
            }
            rect=mapped
        }
        let first=frame == nil
        frame=image;frameRect=rect
        lock.unlock()
        if first {
            if ProcessInfo.processInfo.environment["SINGULARITY_CAPTURE_DIAGNOSTICS"]=="1" {
                log("CAPTURE_FRAME_METADATA pixels=\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image)) info=\(attachments)")
            }
            Task{@MainActor in self.receivedFirstFrame(from:stream)}
        }
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) { DispatchQueue.main.async {
        guard stream === self.stream else {return}
        self.failed(error,serial:self.requestSerial)
    } }
    func latest()->CVPixelBuffer? {lock.lock();defer{lock.unlock()};return frame}
    func latestSnapshot()->Snapshot? {
        lock.lock();defer{lock.unlock()}
        return frame.map{Snapshot(buffer:$0,rect:frameRect)}
    }
    @MainActor func interruptForSelfTest(_ error:NSError,sourceID:UUID?) {
        guard CommandLine.arguments.contains("--self-test"),let sourceID,sourceID==activeID else{return}
        failed(error,serial:requestSerial)
    }
    @MainActor func supplyBenchmarkSnapshot(_ snapshot:Snapshot) {
        guard CommandLine.arguments.contains("--self-test-performance") else{return}
        acceptSnapshot(snapshot)
        if !model.capturing {model.capturing=true}
    }
}

final class PetWindow:NSPanel {
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {false}
    // The overlay intentionally has transparent margins. Let it straddle a
    // display edge; PetPlacement handles recovery when a display disappears.
    override func constrainFrameRect(_ frameRect:NSRect,to screen:NSScreen?)->NSRect {frameRect}
}
final class PetView:NSOpenGLView {
    private struct UniformLocations {
        var desktop:GLint = -1
        var desktopSurface:GLint = -1
        var useDesktopSurface:GLint = -1
        var iResolution:GLint = -1
        var captureRect:GLint = -1
        var iTime:GLint = -1
        var lensDepth:GLint = -1
        var temperature:GLint = -1
        var inclination:GLint = -1
        var rollAngle:GLint = -1
        var brightness:GLint = -1
        var spin:GLint = -1
        var charge:GLint = -1
        var massScale:GLint = -1
        var codexState:GLint = -1
        var codexEnergy:GLint = -1
        var codexTrail:GLint = -1
        var codexParticles:GLint = -1
        var codexPulse:GLint = -1
        var codexEnergySmooth:GLint = -1
        var codexTrailSmooth:GLint = -1
        var codexParticlesSmooth:GLint = -1
        var diskPhase:GLint = -1
        var dustPhase:GLint = -1
        var customRGB:GLint = -1
        var useCustomColor:GLint = -1
        var style:GLint = -1
        var hasCapture:GLint = -1
        var useGeometryCache:GLint = -1
    }
    var program:GLuint=0, vao:GLuint=0, textureID:GLuint=0
    var timer:Timer?
    var clock:Float=0
    var diskPhase:Float=0
    var dustPhase:Float=0
    var codexEnergySmooth:Float=CodexActivityState.idle.energy
    var codexTrailSmooth:Float=CodexActivityState.idle.trail
    var codexParticlesSmooth:Float=CodexActivityState.idle.particleDensity
    var uploaded:CVPixelBuffer?
    var textureWidth:GLsizei=1
    var textureHeight:GLsizei=1
    private var desktopCache:CVOpenGLTextureCache?
    private var desktopSurface:CVOpenGLTexture?
    private var emptySurfaceTexture:GLuint=0
    private var surfaceImportAvailable=true
    private(set) var usingDesktopSurface=false
    private(set) var importedFrames=0
    private(set) var copiedFrames=0
    private(set) var drawnFrames=0
    private(set) var geometryCache:LensGeometryCache?
    private(set) var renderingActive=true
    private let geometryCachingEnabled=ProcessInfo.processInfo.environment["SINGULARITY_DISABLE_GEOMETRY_CACHE"] != "1"
    var benchmarkDirectGeometry=false
    private var renderedWindowFrame=CGRect.zero
    private var requestedCaptureFrame=CGRect.zero
    private var renderedCapture=false
    private var uniforms=UniformLocations()
    var dragStart=NSPoint.zero, originStart=NSPoint.zero
    var dragging=false
    var wanderState=Wander()
    var lastTick=ProcessInfo.processInfo.systemUptime
    var lastSave=ProcessInfo.processInfo.systemUptime
    let capture:Capture
    init(frame:NSRect,capture:Capture) {
        self.capture=capture
        let attrs:[NSOpenGLPixelFormatAttribute]=[UInt32(NSOpenGLPFAOpenGLProfile),UInt32(NSOpenGLProfileVersion3_2Core),UInt32(NSOpenGLPFAAccelerated),UInt32(NSOpenGLPFADoubleBuffer),UInt32(NSOpenGLPFAColorSize),24,UInt32(NSOpenGLPFAAlphaSize),8,0]
        super.init(frame:frame,pixelFormat:NSOpenGLPixelFormat(attributes:attrs)!)!
        wantsBestResolutionOpenGLSurface=true
    }
    required init?(coder:NSCoder) {fatalError()}
    override var isOpaque:Bool {false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func prepareOpenGL() {
        super.prepareOpenGL();openGLContext?.makeCurrentContext()
        var opaque:GLint=0;openGLContext?.setValues(&opaque,for:.surfaceOpacity)
        var swap:GLint=1;openGLContext?.setValues(&swap,for:.swapInterval)
        func compile(_ type:GLenum,_ source:String)->GLuint {
            let shader=glCreateShader(type)
            source.withCString {p in var ptr:UnsafePointer<GLchar>?=p;glShaderSource(shader,1,&ptr,nil)}
            glCompileShader(shader);var ok:GLint=0;glGetShaderiv(shader,GLenum(GL_COMPILE_STATUS),&ok)
            if ok==0 {var info=[GLchar](repeating:0,count:16384);glGetShaderInfoLog(shader,16384,nil,&info);log("SHADER_ERROR \(String(cString:info))");model.error="图形渲染初始化失败"}
            return shader
        }
        let vertex=compile(GLenum(GL_VERTEX_SHADER),try! String(contentsOf:Bundle.main.url(forResource:"blackhole",withExtension:"vert")!,encoding:.utf8))
        let source=try! String(contentsOf:Bundle.main.url(forResource:"blackhole",withExtension:"frag")!,encoding:.utf8)
        let fragment=compile(GLenum(GL_FRAGMENT_SHADER),source)
        program=glCreateProgram();glAttachShader(program,vertex);glAttachShader(program,fragment);glLinkProgram(program)
        var ok:GLint=0;glGetProgramiv(program,GLenum(GL_LINK_STATUS),&ok);log("GL_LINK \(ok)")
        let geometryFragment=compile(GLenum(GL_FRAGMENT_SHADER),source.replacingOccurrences(of:"#version 150",with:"#version 150\n#define GEOMETRY_PASS"))
        let geometryProgram=glCreateProgram()
        glAttachShader(geometryProgram,vertex);glAttachShader(geometryProgram,geometryFragment)
        for (i,name) in ["geometryBackground","geometryCrossing0","geometryCrossing1"].enumerated() {
            glBindFragDataLocation(geometryProgram,GLuint(i),name)
        }
        glLinkProgram(geometryProgram)
        var geometryOK:GLint=0;glGetProgramiv(geometryProgram,GLenum(GL_LINK_STATUS),&geometryOK)
        if geometryOK==1 {geometryCache=LensGeometryCache(program:geometryProgram)}
        else {glDeleteProgram(geometryProgram);log("GEOMETRY_CACHE_LINK_FAILED")}
        glDeleteShader(geometryFragment)
        glDeleteShader(vertex);glDeleteShader(fragment);glGenVertexArrays(1,&vao);glBindVertexArray(vao)
        cacheUniformLocations()
        if let context=openGLContext?.cglContextObj,let format=pixelFormat?.cglPixelFormatObj {
            let result=CVOpenGLTextureCacheCreate(kCFAllocatorDefault,nil,context,format,nil,&desktopCache)
            if result != kCVReturnSuccess {log("DESKTOP_CACHE_UNAVAILABLE code=\(result)")}
        }
        glGenTextures(1,&textureID);glBindTexture(GLenum(GL_TEXTURE_2D),textureID)
        glTexParameteri(GLenum(GL_TEXTURE_2D),GLenum(GL_TEXTURE_MIN_FILTER),GL_LINEAR);glTexParameteri(GLenum(GL_TEXTURE_2D),GLenum(GL_TEXTURE_MAG_FILTER),GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D),GLenum(GL_TEXTURE_WRAP_S),GL_CLAMP_TO_EDGE);glTexParameteri(GLenum(GL_TEXTURE_2D),GLenum(GL_TEXTURE_WRAP_T),GL_CLAMP_TO_EDGE)
        let pixels:[UInt8]=[0,0,0,255];pixels.withUnsafeBytes{glTexImage2D(GLenum(GL_TEXTURE_2D),0,GL_RGBA8,1,1,0,GLenum(GL_BGRA),GLenum(GL_UNSIGNED_BYTE),$0.baseAddress)}
        glGenTextures(1,&emptySurfaceTexture)
        glActiveTexture(GLenum(GL_TEXTURE1));glBindTexture(GLenum(GL_TEXTURE_RECTANGLE),emptySurfaceTexture)
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE),GLenum(GL_TEXTURE_MIN_FILTER),GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE),GLenum(GL_TEXTURE_MAG_FILTER),GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE),GLenum(GL_TEXTURE_WRAP_S),GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_RECTANGLE),GLenum(GL_TEXTURE_WRAP_T),GL_CLAMP_TO_EDGE)
        pixels.withUnsafeBytes{glTexImage2D(GLenum(GL_TEXTURE_RECTANGLE),0,GL_RGBA8,1,1,0,GLenum(GL_BGRA),GLenum(GL_UNSIGNED_BYTE),$0.baseAddress)}
        glActiveTexture(GLenum(GL_TEXTURE0))
        setRenderingActive(renderingActive)
    }
    func setRenderingActive(_ active:Bool) {
        renderingActive=active
        timer?.invalidate();timer=nil
        if active {
            guard program != 0 else{return}
            lastTick=ProcessInfo.processInfo.systemUptime
            let next=Timer(timeInterval:1.0/30,repeats:true){[weak self] _ in self?.tick()}
            next.tolerance=0.003;timer=next;RunLoop.main.add(next,forMode:.common)
            needsDisplay=true
        } else {
            openGLContext?.makeCurrentContext()
            uploaded=nil;desktopSurface=nil;usingDesktopSurface=false
            if let cache=desktopCache {CVOpenGLTextureCacheFlush(cache,0)}
            geometryCache?.release()
        }
    }
    private func cacheUniformLocations() {
        uniforms.desktop=glGetUniformLocation(program,"desktop")
        uniforms.desktopSurface=glGetUniformLocation(program,"desktopSurface")
        uniforms.useDesktopSurface=glGetUniformLocation(program,"useDesktopSurface")
        uniforms.iResolution=glGetUniformLocation(program,"iResolution")
        uniforms.captureRect=glGetUniformLocation(program,"captureRect")
        uniforms.iTime=glGetUniformLocation(program,"iTime")
        uniforms.lensDepth=glGetUniformLocation(program,"LENS_DEPTH")
        uniforms.temperature=glGetUniformLocation(program,"temperature")
        uniforms.inclination=glGetUniformLocation(program,"inclination")
        uniforms.rollAngle=glGetUniformLocation(program,"rollAngle")
        uniforms.brightness=glGetUniformLocation(program,"brightness")
        uniforms.spin=glGetUniformLocation(program,"spin")
        uniforms.charge=glGetUniformLocation(program,"charge")
        uniforms.massScale=glGetUniformLocation(program,"massScale")
        uniforms.codexState=glGetUniformLocation(program,"codexState")
        uniforms.codexEnergy=glGetUniformLocation(program,"codexEnergy")
        uniforms.codexTrail=glGetUniformLocation(program,"codexTrail")
        uniforms.codexParticles=glGetUniformLocation(program,"codexParticles")
        uniforms.codexPulse=glGetUniformLocation(program,"codexPulse")
        uniforms.codexEnergySmooth=glGetUniformLocation(program,"codexEnergySmooth")
        uniforms.codexTrailSmooth=glGetUniformLocation(program,"codexTrailSmooth")
        uniforms.codexParticlesSmooth=glGetUniformLocation(program,"codexParticlesSmooth")
        uniforms.diskPhase=glGetUniformLocation(program,"diskPhase")
        uniforms.dustPhase=glGetUniformLocation(program,"dustPhase")
        uniforms.customRGB=glGetUniformLocation(program,"customRGB")
        uniforms.useCustomColor=glGetUniformLocation(program,"useCustomColor")
        uniforms.style=glGetUniformLocation(program,"style")
        uniforms.hasCapture=glGetUniformLocation(program,"hasCapture")
        uniforms.useGeometryCache=glGetUniformLocation(program,"useGeometryCache")
        glUseProgram(program)
        for (i,name) in ["geometryMap","crossingMap0","crossingMap1"].enumerated() {
            set1i(glGetUniformLocation(program,name),GLint(i+2))
        }
    }
    @inline(__always) private func set1f(_ location:GLint,_ value:Float) { if location >= 0 { glUniform1f(location,value) } }
    @inline(__always) private func set1i(_ location:GLint,_ value:GLint) { if location >= 0 { glUniform1i(location,value) } }
    @inline(__always) private func set2f(_ location:GLint,_ x:Float,_ y:Float) { if location >= 0 { glUniform2f(location,x,y) } }
    @inline(__always) private func set3f(_ location:GLint,_ x:Float,_ y:Float,_ z:Float) { if location >= 0 { glUniform3f(location,x,y,z) } }
    @inline(__always) private func set4f(_ location:GLint,_ x:Float,_ y:Float,_ z:Float,_ w:Float) { if location >= 0 { glUniform4f(location,x,y,z,w) } }
    func advanceAnimation(dt:Double) {
        guard !model.paused else { return }
        let energy=Float(model.codexState.energy),trail=Float(model.codexState.trail),particles=Float(model.codexState.particleDensity)
        // Exponential easing avoids visible jumps when the bridge changes state at poll boundaries.
        let alpha=Float(1.0-exp(-dt/0.18))
        codexEnergySmooth += (energy-codexEnergySmooth)*alpha
        codexTrailSmooth += (trail-codexTrailSmooth)*alpha
        codexParticlesSmooth += (particles-codexParticlesSmooth)*alpha
        clock += Float(model.speed*dt)
        let spinDirection=(model.hasSpin && model.spin < 0) ? -1.0 : 1.0
        // Keep the old visual rates (the shader's disk wind was 5 rad/s at 1x)
        // while integrating state-dependent terms here, where they cannot jump
        // by multiplying a long-lived clock with a newly observed state.
        diskPhase += Float(model.speed*dt*5.0*(1.0+0.34*Double(codexEnergySmooth))*spinDirection)
        dustPhase += Float(model.speed*dt*(0.18+0.88*Double(codexEnergySmooth)))
        if model.codexPulse > 0 { model.codexPulse=max(0,model.codexPulse-dt*2.2) }
    }
    func tick() {
        let now=ProcessInfo.processInfo.systemUptime
        let dt=min(0.1,max(0,now-lastTick));lastTick=now
        guard let w=window,w.isVisible else{return}
        advanceAnimation(dt:dt)
        let mouse=NSEvent.mouseLocation
        let pointer=w.convertPoint(fromScreen:mouse)
        let hovering=hypot(pointer.x-bounds.midX,pointer.y-bounds.midY)<bounds.width*0.29
        if model.wander && !dragging && !hovering && !(appDelegate?.settings?.isVisible ?? false),let screen=w.screen {
            w.setFrameOrigin(wanderState.advance(origin:w.frame.origin,size:w.frame.size,screen:screen.visibleFrame,speed:model.travelSpeed,dt:dt))
            if now-lastSave>5 {appDelegate?.savePosition();lastSave=now}
        }
        if !dragging && !CommandLine.arguments.contains("--self-test") {
            let point=convert(pointer,from:nil)
            let ignores=hypot(point.x-bounds.midX,point.y-bounds.midY)>bounds.width*0.27
            if w.ignoresMouseEvents != ignores {w.ignoresMouseEvents=ignores}
        }
        if w.frame != requestedCaptureFrame {
            requestedCaptureFrame=w.frame
            appDelegate?.checkScreen()
        }
        if !model.paused || needsDisplay || capture.latest() !== uploaded ||
            w.frame != renderedWindowFrame || model.capturing != renderedCapture {needsDisplay=true}
    }
    override func draw(_ dirtyRect:NSRect) {
        guard program != 0,renderingActive else{return};openGLContext?.makeCurrentContext()
        drawnFrames+=1
        let backing=convertToBacking(bounds)
        let width=GLsizei(max(1,Int(backing.width.rounded(.up)))),height=GLsizei(max(1,Int(backing.height.rounded(.up))))
        renderFrame(width:width,height:height,useCapture:true)
        renderedWindowFrame=window?.frame ?? .zero;renderedCapture=model.capturing
        openGLContext?.flushBuffer()
    }
    private func bindDesktop(_ buffer:CVPixelBuffer,forceCPUUpload:Bool) {
        if uploaded === buffer && (!forceCPUUpload || !usingDesktopSurface) {return}
        if !forceCPUUpload,surfaceImportAvailable,CVPixelBufferGetIOSurface(buffer) != nil,let cache=desktopCache {
            var next:CVOpenGLTexture?
            let result=CVOpenGLTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,buffer,nil,&next)
            if result == kCVReturnSuccess,let next,CVOpenGLTextureGetTarget(next)==GLenum(GL_TEXTURE_RECTANGLE) {
                // The cache owns the IOSurface-backed texture. Keep its wrapper and source
                // buffer alive while the GL driver uses the shared image, without a CPU copy.
                desktopSurface=next;uploaded=buffer;usingDesktopSurface=true;importedFrames+=1
                if importedFrames==1 {log("DESKTOP_ZERO_COPY_ACTIVE")}
                // Release unused surface wrappers every frame: retaining them can
                // exhaust ScreenCaptureKit's three-frame pool and stall capture.
                CVOpenGLTextureCacheFlush(cache,0)
                return
            }
            surfaceImportAvailable=false
            log("DESKTOP_ZERO_COPY_FALLBACK code=\(result)")
        }
        desktopSurface=nil;usingDesktopSurface=false
        glActiveTexture(GLenum(GL_TEXTURE0));glBindTexture(GLenum(GL_TEXTURE_2D),textureID)
        let lockResult=CVPixelBufferLockBaseAddress(buffer,.readOnly)
        guard lockResult == kCVReturnSuccess else{return}
        defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        guard let base=CVPixelBufferGetBaseAddress(buffer) else{return}
        let bufferWidth=GLsizei(CVPixelBufferGetWidth(buffer)),bufferHeight=GLsizei(CVPixelBufferGetHeight(buffer))
        glPixelStorei(GLenum(GL_UNPACK_ROW_LENGTH),GLint(CVPixelBufferGetBytesPerRow(buffer)/4))
        if textureWidth != bufferWidth || textureHeight != bufferHeight {
            glTexImage2D(GLenum(GL_TEXTURE_2D),0,GL_RGBA8,bufferWidth,bufferHeight,0,GLenum(GL_BGRA),GLenum(GL_UNSIGNED_BYTE),nil)
            textureWidth=bufferWidth;textureHeight=bufferHeight
        }
        glTexSubImage2D(GLenum(GL_TEXTURE_2D),0,0,0,bufferWidth,bufferHeight,GLenum(GL_BGRA),GLenum(GL_UNSIGNED_BYTE),base)
        glPixelStorei(GLenum(GL_UNPACK_ROW_LENGTH),0)
        uploaded=buffer;copiedFrames+=1
    }
    func renderFrame(width:GLsizei,height:GLsizei,useCapture:Bool,captureBuffer:CVPixelBuffer?=nil,captureSourceRect:CGRect?=nil,forceCPUUpload:Bool=false,forceUncachedGeometry:Bool=false) {
        glBindVertexArray(vao)
        let values:[(String,Float)]=[
            ("LENS_DEPTH",Float(model.lens)),("inclination",Float(model.tilt)),
            ("rollAngle",Float(model.roll)),("spin",Float(model.hasSpin ? model.spin:0)),
            ("charge",Float(model.effectiveCharge)),("massScale",Float(model.mass))]
        let cached = geometryCachingEnabled && !forceUncachedGeometry && !benchmarkDirectGeometry && (geometryCache?.prepare(width:width,height:height,signature:values.map(\.1)+[Float(model.style)]) {p in
            for (name,value) in values {self.set1f(glGetUniformLocation(p,name),value)}
            self.set2f(glGetUniformLocation(p,"iResolution"),Float(width),Float(height))
            self.set1i(glGetUniformLocation(p,"style"),GLint(model.style))
        } ?? false)
        geometryCache?.bind()
        glViewport(0,0,width,height);glClearColor(0,0,0,0);glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        glUseProgram(program);glBindVertexArray(vao);glActiveTexture(GLenum(GL_TEXTURE0));glBindTexture(GLenum(GL_TEXTURE_2D),textureID)
        set1i(uniforms.useGeometryCache,cached ? 1:0)
        let snapshot=useCapture && captureBuffer==nil ? capture.latestSnapshot():nil
        let sourceRect=captureSourceRect ?? snapshot?.rect ?? capture.screenRect
        if useCapture,let buffer=captureBuffer ?? snapshot?.buffer {bindDesktop(buffer,forceCPUUpload:forceCPUUpload)}
        else if useCapture {
            uploaded=nil;desktopSurface=nil;usingDesktopSurface=false
            if let cache=desktopCache {CVOpenGLTextureCacheFlush(cache,0)}
        }
        glActiveTexture(GLenum(GL_TEXTURE0));glBindTexture(GLenum(GL_TEXTURE_2D),textureID)
        glActiveTexture(GLenum(GL_TEXTURE1))
        glBindTexture(GLenum(GL_TEXTURE_RECTANGLE),desktopSurface.map{CVOpenGLTextureGetName($0)} ?? emptySurfaceTexture)
        glActiveTexture(GLenum(GL_TEXTURE0))
        set1i(uniforms.desktopSurface,1);set1i(uniforms.useDesktopSurface,usingDesktopSurface ? 1:0)
        set1i(uniforms.desktop,0);set2f(uniforms.iResolution,Float(width),Float(height))
        set1f(uniforms.iTime,clock);set1f(uniforms.lensDepth,Float(model.lens));set1f(uniforms.temperature,model.style == 1 ? 15000:5500);set1f(uniforms.inclination,Float(model.tilt));set1f(uniforms.rollAngle,Float(model.roll));set1f(uniforms.brightness,Float(model.brightness))
        set1f(uniforms.spin,Float(model.hasSpin ? model.spin:0));set1f(uniforms.charge,Float(model.effectiveCharge));set1f(uniforms.massScale,Float(model.mass))
        set1f(uniforms.codexEnergy,model.codexState.energy);set1f(uniforms.codexTrail,model.codexState.trail);set1f(uniforms.codexParticles,model.codexState.particleDensity);set1f(uniforms.codexPulse,Float(model.codexPulse));set1i(uniforms.codexState,GLint(model.codexState.rawValue))
        set1f(uniforms.codexEnergySmooth,codexEnergySmooth);set1f(uniforms.codexTrailSmooth,codexTrailSmooth);set1f(uniforms.codexParticlesSmooth,codexParticlesSmooth);set1f(uniforms.diskPhase,diskPhase);set1f(uniforms.dustPhase,dustPhase)
        let rgb=RGB(hex:model.colorHex) ?? RGB(hex:"#FFAA55")!
        set3f(uniforms.customRGB,Float(rgb.r),Float(rgb.g),Float(rgb.b))
        set1i(uniforms.useCustomColor,model.customColor ? 1:0)
        set1i(uniforms.style,GLint(model.style));set1i(uniforms.hasCapture,useCapture && uploaded != nil && model.capturing ? 1:0)
        if let w=window,sourceRect.width>0 {let s=sourceRect;set4f(uniforms.captureRect,Float((w.frame.minX-s.minX)/s.width),Float((s.maxY-w.frame.maxY)/s.height),Float(w.frame.width/s.width),Float(w.frame.height/s.height))}
        glDrawArrays(GLenum(GL_TRIANGLES),0,3)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties();openGLContext?.update();needsDisplay=true
    }
    override func mouseDown(with event:NSEvent) {
        if event.clickCount==2 {appDelegate?.showSettings();return}
        log("DRAG_BEGIN");dragging=true;dragStart=NSEvent.mouseLocation;originStart=window!.frame.origin
        appDelegate?.checkScreen()
    }
    override func mouseDragged(with event:NSEvent) {let p=NSEvent.mouseLocation;window?.setFrameOrigin(NSPoint(x:originStart.x+p.x-dragStart.x,y:originStart.y+p.y-dragStart.y))}
    override func mouseUp(with event:NSEvent) {dragging=false;log("DRAG_END x=\(window!.frame.minX) y=\(window!.frame.minY)");appDelegate?.savePosition();appDelegate?.screenParametersChanged()}
    override func rightMouseDown(with event:NSEvent) {if let menu=appDelegate?.makeMenu(){NSMenu.popUpContextMenu(menu,with:event,for:self)}}
}

struct SettingsView:View {
    @ObservedObject var state:Model
    @State private var hexInput=""
    @State private var colorError=""
    var chosenColor:Binding<Color> {Binding(get:{let c=RGB(hex:state.colorHex)!;return Color(.sRGB,red:c.r,green:c.g,blue:c.b)},set:{c in
        if let n=NSColor(c).usingColorSpace(.sRGB){let h=String(format:"#%02X%02X%02X",Int((n.redComponent*255).rounded()),Int((n.greenComponent*255).rounded()),Int((n.blueComponent*255).rounded()));state.colorHex=h;hexInput=h;colorError=""}
    })}
    func applyHex(){if let rgb=RGB(hex:hexInput){state.colorHex=rgb.hex;hexInput=rgb.hex;colorError=""}else{colorError="请输入 #RRGGBB 或 #RGB，例如 #8A5CFF"}}
    let accent=Color(red:0.94,green:0.73,blue:0.43)
    func dial(_ title:String,_ value:Binding<Double>,_ range:ClosedRange<Double>,_ text:String)->some View {
        VStack(spacing:7){HStack{Text(title).foregroundStyle(Color.white.opacity(0.85));Spacer();Text(text).font(.system(size:11,design:.monospaced)).foregroundStyle(accent)};Slider(value:value,in:range).tint(accent)}
    }
    var body:some View {
        ScrollView {VStack(alignment:.leading,spacing:20){
            HStack(alignment:.center,spacing:18){
                ZStack{Circle().fill(.black).frame(width:66,height:66);Ellipse().stroke(accent.opacity(0.8),lineWidth:2).frame(width:92,height:24).rotationEffect(.degrees(-15));Circle().trim(from:0.02,to:0.49).stroke(accent,lineWidth:2).frame(width:53,height:53).rotationEffect(.degrees(180))}.frame(width:96,height:76)
                VStack(alignment:.leading,spacing:5){Text("奇点").font(.system(size:30,weight:.light,design:.serif));Text("S I N G U L A R I T Y").font(.system(size:10,design:.monospaced)).foregroundStyle(accent);Text("让一小片时空，停留在桌面。 ").font(.system(size:12)).foregroundStyle(.secondary)}
                Spacer()
            }
            VStack(alignment:.leading,spacing:10){HStack{Circle().fill(state.capturing ? Color.green:accent).frame(width:6,height:6);Text(state.captureState).font(.system(size:12));Spacer();Button(state.capturing ? "重连":"开启桌面透镜"){appDelegate?.enableCapture()}.controlSize(.small).disabled(!state.visible)};if !state.error.isEmpty {Text(state.error).font(.system(size:11)).foregroundStyle(accent).fixedSize(horizontal:false,vertical:true)};if !state.capturing && state.visible {HStack {
                    Button("打开屏幕录制设置"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)}
                    Button("在访达中显示当前应用"){NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])}
                }.font(.system(size:11))}}.padding(14).background(Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:10))
            Picker("桌面背景刷新",selection:$state.backgroundFPS) {
                Text("自动 · 2–10 FPS").tag(10)
                Text("均衡 · 15 FPS").tag(15)
                Text("流畅 · 30 FPS").tag(30)
            }.pickerStyle(.segmented)
            VStack(alignment:.leading,spacing:11){
                HStack{Text("Codex 状态联动").font(.headline);Spacer();Text(state.codexState.label).font(.system(size:11,design:.monospaced)).foregroundStyle(accent)}
                Toggle("自动检测 Codex 桌面状态",isOn:$state.codexAuto).tint(accent)
                if !state.codexAuto {
                    Picker("预览状态",selection:Binding(get:{state.codexState.rawValue},set:{raw in if let next=CodexActivityState(rawValue:raw){state.setCodexState(next,source:"手动预览",detail:"")}})) {
                        ForEach(CodexActivityState.allCases,id:\.rawValue){item in Text(item.label).tag(item.rawValue)}
                    }
                }
                Text("来源：\(state.codexSource)").font(.system(size:11)).foregroundStyle(.secondary)
                if !state.codexDetail.isEmpty {Text(state.codexDetail).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).lineLimit(2)}
                Text("自动模式通过本机 Codex 渲染器状态判断；无法连接时保持空闲，不读取对话内容。").font(.system(size:11)).foregroundStyle(.secondary)
            }.padding(14).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
            VStack(alignment:.leading,spacing:13){
                Text("黑洞分型").font(.headline)
                Picker("黑洞类型",selection:$state.kind){Text("史瓦西 · Schwarzschild").tag(0);Text("旋转 · Kerr").tag(1);Text("带电 · Reissner–Nordström").tag(2);Text("旋转带电 · Kerr–Newman").tag(3)}
                Text(state.kind==0 ? "不旋转、不带电；吸积盘本身仍可流动。" : "视觉近似：展示自旋偏移、拖曳或带电收缩，非精确时空模拟。").font(.system(size:11)).foregroundStyle(.secondary)
                dial("质量尺度",$state.mass,0.65...1.35,String(format:"%.2f×",state.mass))
                if state.hasSpin {dial("自旋 a*（正负控制方向）",$state.spin,-0.95...0.95,String(format:"%.2f",state.spin))}
                if state.hasCharge {dial("电荷 q*",$state.charge,0...0.95,String(format:"%.2f",state.effectiveCharge))}
                if state.kind==3 {Text("有效电荷随自旋限制，保持 a*² + q*² ≤ 0.98²。").font(.system(size:11)).foregroundStyle(.secondary)}
            }.padding(14).background(Color.white.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
            VStack(alignment:.leading,spacing:12){
                Toggle("桌面随机漫游",isOn:$state.wander).tint(accent)
                if state.wander {dial("移动速度",$state.travelSpeed,5...180,"\(Int(state.travelSpeed)) pt/s")}
                Text("在当前屏幕内漫游，碰到边缘随机折返。鼠标靠近、拖动或打开设置时暂停；关闭设置后继续。").font(.system(size:11)).foregroundStyle(.secondary)
            }
            VStack(alignment:.leading,spacing:12){
                Toggle("自定义吸积盘颜色",isOn:$state.customColor).tint(accent)
                if state.customColor {
                    HStack{ColorPicker("颜色",selection:chosenColor,supportsOpacity:false);TextField("#RRGGBB",text:$hexInput).textFieldStyle(.roundedBorder).frame(width:105).onSubmit{applyHex()};Button("应用"){applyHex()}}
                    if !colorError.isEmpty {Text(colorError).foregroundStyle(.orange).font(.system(size:11))}
                    Text("只改变吸积盘色调，桌面原色和黑色事件视界保持不变。").font(.system(size:11)).foregroundStyle(.secondary)
                }
            }.onAppear{hexInput=state.colorHex}.onChange(of:state.colorHex){hexInput=$0}
            VStack(alignment:.leading,spacing:12){Text("吸积盘风格").font(.system(size:12)).foregroundStyle(.secondary);Picker("",selection:$state.style){Text("炽金").tag(0);Text("冷蓝").tag(1);Text("星环").tag(2);Text("纯透镜").tag(3)}.pickerStyle(.segmented).labelsHidden()}
            VStack(spacing:17){dial("黑洞大小",$state.size,280...700,"阴影直径约 \(Int(state.size * 0.17)) pt");dial("引力透镜",$state.lens,3...24,String(format:"%.1f",state.lens));dial("吸积盘亮度",$state.brightness,0.3...3.5,String(format:"%.1f",state.brightness));dial("轨道倾角",$state.tilt,0.2...1.56,String(format:"%.0f°",state.tilt*180/Double.pi));dial("画面旋转",$state.roll,-0.8...0.8,String(format:"%.0f°",state.roll*180/Double.pi));dial("流动速度",$state.speed,0.1...1.8,String(format:"%.1f×",state.speed))}
            Divider().overlay(Color.white.opacity(0.05))
            HStack{Button(state.paused ? "继续流动":"暂停流动"){state.paused.toggle()};Button(state.visible ? "隐藏宠物":"显示宠物"){appDelegate?.togglePet()};Spacer();Button("恢复默认"){state.reset()}}
            HStack{Text("拖动黑洞移动 · 双击或右键打开设置").font(.system(size:11)).foregroundStyle(.secondary);Spacer();Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.9")").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)}
        }.padding(26)}.frame(width:520,height:790).background(Color(red:0.055,green:0.06,blue:0.075)).preferredColorScheme(.dark)
    }
}

final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    var pet:PetWindow!
    var view:PetView!
    var settings:NSWindow!
    var status:NSStatusItem!
    let capture=Capture()
    var codexBridge:CodexStateBridge?
    private var idleReasons=Set<Capture.Suspension>()
    func applicationDidFinishLaunching(_ notification:Notification) {
        let menu=NSMenu();let top=NSMenuItem();menu.addItem(top);let submenu=NSMenu();top.submenu=submenu
        submenu.addItem(withTitle:"关于奇点",action:#selector(about),keyEquivalent:"");submenu.addItem(withTitle:"设置…",action:#selector(showSettings),keyEquivalent:",");submenu.addItem(.separator());submenu.addItem(withTitle:"退出奇点",action:#selector(quit),keyEquivalent:"q");NSApp.mainMenu=menu
        let size=model.size
        pet=PetWindow(contentRect:NSRect(x:500,y:300,width:size,height:size),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        pet.title="奇点桌面宠物";pet.isOpaque=false;pet.backgroundColor = .clear;pet.hasShadow=false;pet.level = .floating;pet.hidesOnDeactivate=false;pet.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];pet.isReleasedWhenClosed=false
        view=PetView(frame:pet.contentView!.bounds,capture:capture);view.autoresizingMask=[.width,.height];pet.contentView=view
        let d=UserDefaults.standard
        let savedX=d.object(forKey:"x") as? Double, savedY=d.object(forKey:"y") as? Double
        if let screen=NSScreen.main {pet.setFrameOrigin(NSPoint(x:screen.visibleFrame.minX+screen.visibleFrame.width*0.78-size/2,y:screen.visibleFrame.midY-size/2))}
        if let x=savedX,let y=savedY {
            let proposed=NSRect(x:x,y:y,width:size,height:size)
            pet.setFrameOrigin(PetPlacement.recoveredOrigin(for:proposed,screens:petScreens))
        }
        pet.orderFrontRegardless()
        settings=NSWindow(contentRect:NSRect(x:0,y:0,width:490,height:700),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        settings.level=NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+1);settings.title="奇点 · 黑洞控制室";settings.contentView=NSHostingView(rootView:SettingsView(state:model));settings.isReleasedWhenClosed=false;settings.center();settings.appearance=NSAppearance(named:.darkAqua)
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength);status.button?.image=NSImage(systemSymbolName:"circle.circle",accessibilityDescription:"奇点");status.menu=makeMenu()
        if !CommandLine.arguments.contains("--pet-only") { showSettings() }
        if !CommandLine.arguments.contains("--self-test") {
            codexBridge=CodexStateBridge(model:model)
            codexBridge?.restartIfNeeded()
        }
        if CommandLine.arguments.contains("--self-test-render-only") {
            model.captureState="离屏渲染自测"
        } else if CGPreflightScreenCaptureAccess(){
            enableCapture(requestPermission:false)
        } else {
            model.captureState="需要屏幕录制权限"
            model.error="真实桌面扭曲需要屏幕录制权限。请点击「开启桌面透镜」，或在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许「奇点」。"
        }
        NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in self?.screenParametersChanged()}
        let workspace=NSWorkspace.shared.notificationCenter
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
        if CommandLine.arguments.contains("--self-test") {runSelfTest()}
    }
    func makeMenu()->NSMenu {let m=NSMenu();m.addItem(withTitle:"黑洞设置…",action:#selector(showSettings),keyEquivalent:",");m.addItem(withTitle:"显示 / 隐藏宠物",action:#selector(togglePet),keyEquivalent:"");m.addItem(withTitle:"将黑洞移回屏幕中央",action:#selector(centerPet),keyEquivalent:"");m.addItem(.separator());m.addItem(withTitle:"退出奇点",action:#selector(quit),keyEquivalent:"q");for i in m.items{i.target=self};return m}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {showSettings();return true}
    @objc func showSettings(){settings?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func about(){NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"奇点 · Singularity",.applicationVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.2.9",.credits:NSAttributedString(string:"引力透镜着色器基于 s0xDk/ghostty-blackhole（MIT）。")])}
    func applicationWillTerminate(_ notification:Notification){savePosition()}
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
    }
    @objc func centerPet(){guard pet != nil,let s=NSScreen.main else{return};pet.setFrameOrigin(NSPoint(x:s.visibleFrame.midX-pet.frame.width/2,y:s.visibleFrame.midY-pet.frame.height/2));savePosition()}
    func resizePet(){guard pet != nil else{return};let center=NSPoint(x:pet.frame.midX,y:pet.frame.midY);pet.setFrame(NSRect(x:center.x-model.size/2,y:center.y-model.size/2,width:model.size,height:model.size),display:true);savePosition()}
    func savePosition(){guard pet != nil,!CommandLine.arguments.contains("--self-test") else{return};UserDefaults.standard.set(pet.frame.minX,forKey:"x");UserDefaults.standard.set(pet.frame.minY,forKey:"y")}
    var petScreens:[PetScreen] {NSScreen.screens.map{PetScreen(frame:$0.frame,visibleFrame:$0.visibleFrame)}}
    func screenParametersChanged(){
        guard pet != nil else{return}
        if !view.dragging {
            let origin=PetPlacement.recoveredOrigin(for:pet.frame,screens:petScreens)
            if origin != pet.frame.origin {pet.setFrameOrigin(origin);savePosition()}
        }
        checkScreen()
    }
    func enableCapture(requestPermission:Bool=true){guard model.visible,let screen=pet.screen ?? NSScreen.main else{return};model.captureState="正在连接桌面…";Task{@MainActor in await capture.start(screen:screen,requestPermission:requestPermission)}}
    func restartCodexBridge(){
        if idleReasons.isEmpty {codexBridge?.restartIfNeeded()}
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
    func checkScreen(){guard capture.wantsCapture,let s=pet.screen else{return};Task{@MainActor in await capture.retarget(screen:s)}}
    func runSelfTest(){DispatchQueue.main.asyncAfter(deadline:.now()+2){NativeSelfTest.run(self)}}
}
if CommandLine.arguments.contains("--capture-policy-test") {
    NativeSelfTest.recoveryPolicyChecks()
    exit(0)
}
let app=NSApplication.shared
let delegate=AppDelegate();appDelegate=delegate
app.setActivationPolicy(.regular);app.delegate=delegate;app.run()
