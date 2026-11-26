import Cocoa
import ScreenCaptureKit
import CoreMedia

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
    // The producer has completed each retained buffer; all consumers only read it.
    struct Snapshot: @unchecked Sendable {
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
    private var screenWaitTask:Task<Void,Never>?
    private(set) var awaitingScreen=false
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

    private static let lifecycleLog = CaptureLog(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Singularity", isDirectory: true))
    private static let logQueue = DispatchQueue(label: "singularity.capture.lifecycle-log", qos: .utility)
    private func record(_ message: String) {
        log(message)
        guard !RunMode.selfTest else { return }
        // Lifecycle metadata only, never pixels, titles or conversation data.
        Self.logQueue.async {
            do { try Self.lifecycleLog.append(message) }
            catch { log("CAPTURE_LOG_UNAVAILABLE") }
        }
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
        screenWaitTask?.cancel();screenWaitTask=nil
        screenshotDeadline?.cancel();screenshotDeadline=nil
        screenshotWait?.cancel();screenshotWait=nil
        pendingRegion=nil;regionUpdateID=nil
    }
    @MainActor func start(screen:NSScreen?,requestPermission:Bool=true,retryPreferredBackend:Bool=false) async {
        cancelPending();retryBudget.reset()
        awaitingScreen=false
        if screen != nil,retryPreferredBackend {
            screenshotAvailable=true;regionAvailable=true
            record("CAPTURE_PREFERRED_RETRY")
        }
        self.requestPermission=requestPermission
        requestedScreen=screen;requestSerial &+= 1
        requestedDisplayID=screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        requestedRect=screen?.frame ?? .zero
        await reconcile()
    }
    @MainActor func suspend(_ reason:Suspension = .sleep) async {
        let wasSuspended=suspended
        suspensions.insert(reason)
        awaitingScreen=false
        guard wantsCapture,!wasSuspended else{return}
        cancelPending();requestSerial &+= 1
        await reconcile()
    }
    @MainActor func resume(_ reason:Suspension = .sleep,screen:NSScreen?) async {
        guard suspensions.remove(reason) != nil,!suspended else{return}
        guard wantsCapture else{return}
        guard let screen else {
            awaitingScreen=true
            record("CAPTURE_WAITING_FOR_SCREEN")
            waitForScreen()
            return
        }
        await start(screen:screen,requestPermission:false)
    }
    @MainActor private func waitForScreen() {
        screenWaitTask?.cancel()
        let serial=requestSerial
        screenWaitTask=Task{@MainActor [weak self] in
            // Cover delayed wake enumeration without a permanent background poll.
            for _ in 0..<12 {
                do {try await Task.sleep(nanoseconds:1_000_000_000)} catch {return}
                guard let self,self.requestSerial==serial,self.awaitingScreen,
                      self.wantsCapture,!self.suspended else{return}
                if let screen=appDelegate?.pet.screen ?? NSScreen.main {
                    self.screenWaitTask=nil
                    await self.retarget(screen:screen)
                    return
                }
            }
            if let self,self.requestSerial==serial {self.screenWaitTask=nil}
            // A later screen-parameters notification can still consume awaitingScreen.
        }
    }
    @MainActor func retarget(screen:NSScreen) async {
        guard wantsCapture,!suspended else{return}
        if awaitingScreen {
            await start(screen:screen,requestPermission:false)
            return
        }
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
            await transition(to:suspended || awaitingScreen ? nil:requestedScreen,serial:serial)
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
            model.captureState=suspended || awaitingScreen ? "等待桌面恢复":"桌面透镜已暂停";model.error=""
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
            if RunMode.selfTest,selfTestStreamStartDelay>0 {
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
                    if RunMode.selfTest,self.selfTestScreenshotDelay>0 {
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
                    var unchanged = false
                    if adaptive, let previous = self.latestSnapshot() {
                        unchanged = await Self.samePixels(previous, next)
                    }
                    // The UI may move the pet, switch displays, hide it, or reconnect while comparing.
                    guard !Task.isCancelled, self.activeID == sourceID, self.requestSerial == serial else { return }
                    guard self.configurationUpdates == revision, self.desiredRegion == region else { continue }
                    if adaptive,!unchanged,RunMode.selfTest,
                       ProcessInfo.processInfo.environment["SINGULARITY_CAPTURE_DIAGNOSTICS"]=="1" {
                        log("CAPTURE_PIXELS_CHANGED uptime=\(ProcessInfo.processInfo.systemUptime) rect=\(region)")
                    }
                    if adaptive,RunMode.performance,self.comparisonMilliseconds.count<10_000 {
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
    private static let pixelQueue = DispatchQueue(label: "singularity.capture.compare", qos: .utility)

    static func samePixels(_ a: Snapshot, _ b: Snapshot) async -> Bool {
        await withCheckedContinuation { continuation in
            pixelQueue.async { continuation.resume(returning: compareLockedPixels(a, b)) }
        }
    }

    private static func compareLockedPixels(_ a: Snapshot, _ b: Snapshot) -> Bool {
        dispatchPrecondition(condition: .onQueue(pixelQueue))
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
        awaitingScreen=false
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
            model.error="请检查屏幕录制权限，然后点击「连接透镜」。(\(e.domain) \(e.code))"
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
        guard RunMode.selfTest,let sourceID,sourceID==activeID else{return}
        failed(error,serial:requestSerial)
    }
    @MainActor func supplyBenchmarkSnapshot(_ snapshot:Snapshot) {
        guard RunMode.performance else{return}
        acceptSnapshot(snapshot)
        if !model.capturing {model.capturing=true}
    }
}
