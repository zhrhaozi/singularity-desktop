import Cocoa
import OpenGL.GL3
import ScreenCaptureKit

enum NativeSelfTest {
    static func require(_ condition: @autoclosure () -> Bool, _ message:String) {
        guard condition() else {
            log("SELF_TEST_FAIL \(message)")
            exit(1)
        }
    }

    @MainActor static func run(_ app:AppDelegate) {
        if CommandLine.arguments.contains("--self-test-performance") {
            performanceRun(app)
            return
        }
        if CommandLine.arguments.contains("--self-test-fail") {
            require(false,"intentional failure validates the release test runner")
        }
        model.codexAuto=false;model.wander=false;model.bodyCount=1
        let oldSize=model.size,oldOrigin=app.pet.frame.origin
        for size in [280.0,440.0,700.0] {
            model.size=size
            require(abs(app.pet.frame.width-size)<1,"resize \(size)")
        }
        if let screen=app.pet.screen ?? NSScreen.main {
            model.size=280
            app.pet.setFrameOrigin(CGPoint(x:screen.visibleFrame.maxX-280,y:screen.visibleFrame.midY-140))
            model.bodyCount=3
            require(app.pet.frame.origin==PetPlacement.recoveredOrigin(for:app.pet.frame,screens:app.petScreens),
                    "switching to a larger system keeps the window on an available screen")
            model.bodyCount=1
        }
        model.size=oldSize
        app.pet.setFrameOrigin(NSPoint(x:oldOrigin.x+30,y:oldOrigin.y+20))
        require(abs(app.pet.frame.minX-oldOrigin.x-30)<1,"position")
        let moved=app.pet.frame
        app.screenParametersChanged()
        require(app.pet.frame==moved,"screen notification preserves valid position")
        app.pet.setFrameOrigin(oldOrigin)
        app.pet.orderOut(nil);require(!app.pet.isVisible,"hide")
        app.pet.orderFrontRegardless();require(app.pet.isVisible,"show")
        app.view.openGLContext?.makeCurrentContext()
        var linked:GLint=0
        glGetProgramiv(app.view.program,GLenum(GL_LINK_STATUS),&linked)
        require(linked==1,"GL link status")
        renderChecks(app.view)
        multiBodyRenderChecks(app.view)
        recoveryPolicyChecks()
        snapshotPixelChecks()
        if CommandLine.arguments.contains("--self-test-render-only") {
            log("SELF_TEST_PASS generated-texture renderer-only")
            NSApp.terminate(nil)
            return
        }
        Task{@MainActor in
            if CGPreflightScreenCaptureAccess(),let screen=app.pet.screen ?? NSScreen.main {
                let backdrop=launchBackdrop()
                defer {backdrop?.terminate()}
                try? await Task.sleep(nanoseconds:500_000_000)
                await app.capture.start(screen:screen)
                await waitForCapture(app,active:true)
                require(model.capturing && app.capture.activeID != nil,"capture started")
                let old=app.capture.activeID,oldStream=app.capture.stream
                await app.capture.start(screen:nil)
                require(!model.capturing && app.capture.activeID==nil && app.capture.latest()==nil,"capture pause")
                let first=Task{@MainActor in await app.capture.start(screen:screen)}
                let hide=Task{@MainActor in await app.capture.start(screen:nil)}
                let last=Task{@MainActor in await app.capture.start(screen:screen)}
                await first.value;await hide.value;await last.value
                await waitForCapture(app,active:true)
                require(model.capturing && app.capture.activeID != nil,"latest capture request wins")
                app.capture.interruptForSelfTest(NSError(domain:"stale-test",code:1),sourceID:old)
                if let oldStream {app.capture.stream(oldStream,didStopWithError:NSError(domain:"stale-test",code:1))}
                try? await Task.sleep(nanoseconds:100_000_000)
                require(model.capturing,"stale source callback ignored")
                for _ in 0..<50 {
                    if app.capture.latest() != nil {break}
                    try? await Task.sleep(nanoseconds:100_000_000)
                }
                require(app.capture.latest() != nil,"new stream delivers pixels")
                app.togglePet()
                require(!app.pet.isVisible,"hide entry point")
                await waitForCapture(app,active:false)
                require(app.view.timer==nil && app.view.uploaded==nil,"hidden view releases timer and desktop")
                app.togglePet()
                require(app.pet.isVisible,"show entry point")
                require(app.view.timer != nil,"shown view resumes timer")
                await waitForCapture(app,active:true)
                app.togglePet();app.togglePet();app.togglePet()
                await waitForCapture(app,active:false)
                app.togglePet()
                await waitForCapture(app,active:true)
                await recoveryChecks(app,screen:screen)
                await regionCaptureChecks(app,screen:screen)
                await multiBodyCaptureChecks(app,screen:screen)
                await streamStartRetargetChecks(app,screen:screen)
                if let backdrop {await adaptiveCaptureChecks(app,screen:screen,backdrop:backdrop)}
                await codexVisibilityChecks(app)
                await waitForCapture(app,active:true)
                await app.suspendActivity(.display)
                await app.suspendActivity(.session)
                let dormant=app.view.drawnFrames
                try? await Task.sleep(nanoseconds:400_000_000)
                require(app.view.timer==nil && app.view.drawnFrames==dormant,"suspended display has no redraws or timer")
                await app.resumeActivity(.display)
                require(app.view.timer==nil && !model.capturing,"overlapping suspension stays dormant")
                await app.resumeActivity(.session)
                await waitForCapture(app,active:true)
                require(app.view.timer != nil,"final resume restarts rendering")
                capturedRenderCheck(app.view)
                log("IDLE_RESOURCE_TEST_PASS hidden suspended overlap resume fresh-desktop")
                await app.capture.start(screen:nil)
                model.paused=true
                try? await Task.sleep(nanoseconds:300_000_000)
                let settled=app.view.drawnFrames
                try? await Task.sleep(nanoseconds:400_000_000)
                require(app.view.drawnFrames==settled,"paused unchanged view does not redraw")
                model.paused=false
                try? await Task.sleep(nanoseconds:200_000_000)
                require(app.view.drawnFrames>settled,"resume redraws")
                await app.capture.start(screen:screen,requestPermission:false)
                await waitForCapture(app,active:true)
                log("RENDER_SCHEDULING_TEST_PASS paused-static no-redraw resume-redraw")
                await snapshotLifecycleChecks(app,screen:screen)
                log("CAPTURE_TEST_PASS pause rapid-reconnect stale-callback real-frames")
            } else {
                log("CAPTURE_TEST_SKIPPED screen permission unavailable")
            }
            log("SELF_TEST_PASS release-checks window renderer animation capture")
            if !CommandLine.arguments.contains("--self-test-stay") {NSApp.terminate(nil)}
        }
    }

    @MainActor static func performanceRun(_ app:AppDelegate) {
        model.codexAuto=false;model.wander=false;model.paused=false
        model.setCodexState(.longTask,source:"performance-test")
        app.pet.ignoresMouseEvents=true
        for menu in [app.status.menu,NSApp.mainMenu?.items.first?.submenu] {
            menu?.autoenablesItems=false
            for item in menu?.items ?? [] where item.action != #selector(AppDelegate.quit) {
                item.isEnabled=false
            }
        }
        let fixedAppearance=[model.size,model.mass,model.lens,model.brightness,model.speed,
                             model.spin,model.charge,model.tilt,model.roll]
        let experimental=ProcessInfo.processInfo.environment.keys.contains {
            $0.hasPrefix("SINGULARITY_BENCHMARK_") && !["SINGULARITY_BENCHMARK_SECONDS","SINGULARITY_BENCHMARK_BACKEND","SINGULARITY_BENCHMARK_MULTIBODY"].contains($0)
        }
        if experimental {app.capture.forceStream=true;app.capture.framesPerSecond=30}
        Task{@MainActor in
            await waitForCapture(app,active:true)
            try? await Task.sleep(nanoseconds:3_000_000_000)
            let start=ProcessInfo.processInfo.systemUptime
            let frames=app.view.drawnFrames,imports=app.view.importedFrames,copies=app.view.copiedFrames
            let duration=min(300,max(20,Double(ProcessInfo.processInfo.environment["SINGULARITY_BENCHMARK_SECONDS"] ?? "") ?? 75))
            log("PERFORMANCE_RUN_BEGIN pid=\(getpid()) size=\(model.size) mass=\(model.mass) cache=\(app.view.geometryCache?.rebuilds ?? 0)")
            if ProcessInfo.processInfo.environment["SINGULARITY_BENCHMARK_MULTIBODY"]=="1" {
                app.settings.orderOut(nil)
                for count in [0,1,2,3] {
                    if count==0 {
                        if model.visible {app.togglePet()}
                        await app.capture.start(screen:nil)
                    } else {
                        model.bodyCount=count
                        if !model.visible {app.togglePet()}
                        await app.capture.start(screen:app.pet.screen ?? NSScreen.main,requestPermission:false)
                        await waitForCapture(app,active:true)
                    }
                    try? await Task.sleep(nanoseconds:15_000_000_000)
                    let draws=app.view.drawnFrames,requests=app.capture.screenshotRequests
                    let rebuilds=app.view.multiLens.cacheRebuilds
                    let begin=ProcessInfo.processInfo.systemUptime
                    log("MULTIBODY_PERFORMANCE_BEGIN uptime=\(begin) count=\(count) window=\(app.pet.frame.size)")
                    try? await Task.sleep(nanoseconds:UInt64(duration*1_000_000_000))
                    let elapsed=ProcessInfo.processInfo.systemUptime-begin
                    require([model.size,model.mass,model.lens,model.brightness,model.speed,
                             model.spin,model.charge,model.tilt,model.roll]==fixedAppearance,
                            "benchmark appearance changed during sampling")
                    if count==0 {
                        require(!model.visible && !model.capturing && app.view.drawnFrames==draws &&
                                app.capture.screenshotRequests==requests,"hidden benchmark has no rendering or capture")
                    } else {
                        require(model.visible && model.bodyCount==count && model.capturing,"benchmark mode stays active")
                    }
                    log("MULTIBODY_PERFORMANCE_END uptime=\(ProcessInfo.processInfo.systemUptime) count=\(count) fps=\(Double(app.view.drawnFrames-draws)/elapsed) screenshots=\(app.capture.screenshotRequests-requests) cache-rebuilds=\(app.view.multiLens.cacheRebuilds-rebuilds)")
                }
            } else if ProcessInfo.processInfo.environment["SINGULARITY_BENCHMARK_ADAPTIVE"]=="1" {
                app.capture.forceStream=false;app.capture.framesPerSecond=10
                for mode in ["fixed","adaptive","fixed","adaptive"] {
                    app.capture.adaptiveSampling=mode=="adaptive"
                    await app.capture.start(screen:app.pet.screen ?? NSScreen.main,requestPermission:false)
                    await waitForCapture(app,active:true)
                    try? await Task.sleep(nanoseconds:3_000_000_000)
                    let before=app.capture.screenshotRequests,unchanged=app.capture.unchangedScreenshots,imports=app.view.importedFrames
                    let comparisons=app.capture.comparisonMilliseconds.count,draws=app.view.drawnFrames
                    log("ISOLATE_PERFORMANCE_PHASE uptime=\(ProcessInfo.processInfo.systemUptime) mode=\(mode)")
                    try? await Task.sleep(nanoseconds:30_000_000_000)
                    let times=Array(app.capture.comparisonMilliseconds.dropFirst(comparisons)).sorted()
                    if !times.isEmpty {
                        log("CAPTURE_COMPARISON_COST mode=\(mode) count=\(times.count) p50ms=\(times[times.count/2]) p95ms=\(times[min(times.count-1,Int(Double(times.count)*0.95))]) maxms=\(times.last!) draws=\(app.view.drawnFrames-draws)")
                    }
                    log("ISOLATE_PERFORMANCE_PHASE_END uptime=\(ProcessInfo.processInfo.systemUptime) mode=\(mode) requests=\(app.capture.screenshotRequests-before) unchanged=\(app.capture.unchangedScreenshots-unchanged) imports=\(app.view.importedFrames-imports) fps=\(app.capture.appliedFramesPerSecond)")
                }
            } else if ProcessInfo.processInfo.environment["SINGULARITY_BENCHMARK_FILTER"]=="1" {
                app.capture.forceStream=true;app.capture.framesPerSecond=10
                for mode in ["application","windows","nominal","windowNominal"] {
                    app.capture.benchmarkWindowFilter=mode=="windows" || mode=="windowNominal"
                    app.capture.benchmarkNominalResolution=mode=="nominal" || mode=="windowNominal"
                    await app.capture.start(screen:app.pet.screen ?? NSScreen.main,requestPermission:false)
                    await waitForCapture(app,active:true)
                    try? await Task.sleep(nanoseconds:3_000_000_000)
                    log("ISOLATE_PERFORMANCE_PHASE uptime=\(ProcessInfo.processInfo.systemUptime) mode=\(mode)")
                    try? await Task.sleep(nanoseconds:30_000_000_000)
                    log("ISOLATE_PERFORMANCE_PHASE_END uptime=\(ProcessInfo.processInfo.systemUptime) mode=\(mode)")
                }
            } else if ProcessInfo.processInfo.environment["SINGULARITY_BENCHMARK_BACKEND"]=="1" {
                for mode in ["stream","snapshot","stream","snapshot"] {
                    app.capture.forceStream=mode=="stream"
                    app.capture.framesPerSecond=mode=="stream" ? 30:10
                    await app.capture.start(screen:app.pet.screen ?? NSScreen.main,requestPermission:false)
                    await waitForCapture(app,active:true)
                    try? await Task.sleep(nanoseconds:3_000_000_000)
                    let before=app.view.importedFrames
                    log("ISOLATE_PERFORMANCE_PHASE uptime=\(ProcessInfo.processInfo.systemUptime) mode=\(mode)")
                    try? await Task.sleep(nanoseconds:30_000_000_000)
                    log("ISOLATE_PERFORMANCE_PHASE_END uptime=\(ProcessInfo.processInfo.systemUptime) mode=\(mode) imports=\(app.view.importedFrames-before)")
                }
            } else if ProcessInfo.processInfo.environment["SINGULARITY_BENCHMARK_SCREENSHOT"]=="1" {
                if #available(macOS 14.0, *) {
                    guard let screen=app.pet.screen ?? NSScreen.main else {require(false,"benchmark screen");return}
                    let content=try! await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
                    let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                    let display=content.displays.first{$0.displayID==id}!
                    let own=content.applications.filter{$0.processID==getpid()}
                    let filter=SCContentFilter(display:display,excludingApplications:own,exceptingWindows:[])
                    let region=CaptureRegion.region(for:app.pet.frame,on:screen.frame)
                    let config=SCStreamConfiguration()
                    config.sourceRect=CaptureRegion.sourceRect(region,on:screen.frame)
                    config.width=Int((region.width*CGFloat(filter.pointPixelScale)).rounded(.up))
                    config.height=Int((region.height*CGFloat(filter.pointPixelScale)).rounded(.up))
                    config.pixelFormat=kCVPixelFormatType_32BGRA;config.showsCursor=false;config.capturesAudio=false
                    let cadence=ProcessInfo.processInfo.environment["SINGULARITY_BENCHMARK_SCREENSHOT_CADENCE"]=="1"
                    for mode in cadence ? ["screenshot30","screenshot10","screenshot30","screenshot10"] : ["stream","screenshot","stream","screenshot"] {
                        var screenshots:Task<Void,Never>?
                        if mode=="stream" {
                            await app.capture.start(screen:screen,requestPermission:false)
                        } else {
                            await app.capture.start(screen:nil)
                            screenshots=Task{@MainActor in
                                var count=0
                                while !Task.isCancelled {
                                    let began=ProcessInfo.processInfo.systemUptime
                                    do {
                                        let sample=try await SCScreenshotManager.captureSampleBuffer(contentFilter:filter,configuration:config)
                                        guard !Task.isCancelled else{return}
                                        guard let image=CMSampleBufferGetImageBuffer(sample) else {require(false,"screenshot pixels");return}
                                        app.capture.supplyBenchmarkSnapshot(Capture.Snapshot(buffer:image,rect:region))
                                        count+=1
                                        if count==1 {log("SCREENSHOT_BENCHMARK_FRAME pixels=\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))")}
                                        let delay=max(0,1.0/(mode=="screenshot10" ? 10:30)-(ProcessInfo.processInfo.systemUptime-began))
                                        try await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))
                                    } catch {
                                        if Task.isCancelled {return}
                                        require(false,"screenshot benchmark \(error)")
                                    }
                                }
                            }
                        }
                        await waitForCapture(app,active:true)
                        try? await Task.sleep(nanoseconds:3_000_000_000)
                        let before=app.view.importedFrames
                        log("ISOLATE_PERFORMANCE_PHASE uptime=\(ProcessInfo.processInfo.systemUptime) mode=\(mode)")
                        try? await Task.sleep(nanoseconds:30_000_000_000)
                        log("ISOLATE_PERFORMANCE_PHASE_END uptime=\(ProcessInfo.processInfo.systemUptime) mode=\(mode) imports=\(app.view.importedFrames-before)")
                        screenshots?.cancel();await screenshots?.value
                    }
                } else {require(false,"screenshot benchmark requires macOS 14")}
            } else if ProcessInfo.processInfo.environment["SINGULARITY_BENCHMARK_ISOLATE"]=="1" {
                for mode in ["both","render","capture","neither","both","render","capture","neither"] {
                    let captures=mode=="both" || mode=="capture"
                    app.view.setRenderingActive(mode=="both" || mode=="render")
                    await app.capture.start(screen:captures ? (app.pet.screen ?? NSScreen.main):nil,requestPermission:false)
                    await waitForCapture(app,active:captures)
                    try? await Task.sleep(nanoseconds:3_000_000_000)
                    log("ISOLATE_PERFORMANCE_PHASE uptime=\(ProcessInfo.processInfo.systemUptime) mode=\(mode)")
                    try? await Task.sleep(nanoseconds:20_000_000_000)
                    log("ISOLATE_PERFORMANCE_PHASE_END uptime=\(ProcessInfo.processInfo.systemUptime) mode=\(mode)")
                }
                app.view.setRenderingActive(true)
                await app.capture.start(screen:app.pet.screen ?? NSScreen.main,requestPermission:false)
                await waitForCapture(app,active:true)
            } else if ProcessInfo.processInfo.environment["SINGULARITY_BENCHMARK_CADENCE"]=="1" {
                for fps in [30,10,30,10] {
                    app.capture.framesPerSecond=fps
                    await app.capture.start(screen:app.pet.screen ?? NSScreen.main,requestPermission:false)
                    await waitForCapture(app,active:true)
                    try? await Task.sleep(nanoseconds:3_000_000_000)
                    let snapshot=app.capture.latestSnapshot()!
                    log("CAPTURE_PERFORMANCE_PHASE uptime=\(ProcessInfo.processInfo.systemUptime) full=false fps=\(fps) pixels=\(CVPixelBufferGetWidth(snapshot.buffer))x\(CVPixelBufferGetHeight(snapshot.buffer))")
                    try? await Task.sleep(nanoseconds:30_000_000_000)
                    log("CAPTURE_PERFORMANCE_PHASE_END uptime=\(ProcessInfo.processInfo.systemUptime) full=false fps=\(fps)")
                }
            } else if ProcessInfo.processInfo.environment["SINGULARITY_BENCHMARK_CAPTURE"]=="1" {
                for fullDisplay in [true,false,true,false] {
                    app.capture.forceFullDisplay=fullDisplay
                    await app.capture.start(screen:app.pet.screen ?? NSScreen.main,requestPermission:false)
                    await waitForCapture(app,active:true)
                    try? await Task.sleep(nanoseconds:3_000_000_000)
                    let snapshot=app.capture.latestSnapshot()!
                    log("CAPTURE_PERFORMANCE_PHASE uptime=\(ProcessInfo.processInfo.systemUptime) full=\(fullDisplay) pixels=\(CVPixelBufferGetWidth(snapshot.buffer))x\(CVPixelBufferGetHeight(snapshot.buffer))")
                    try? await Task.sleep(nanoseconds:30_000_000_000)
                    log("CAPTURE_PERFORMANCE_PHASE_END uptime=\(ProcessInfo.processInfo.systemUptime) full=\(fullDisplay)")
                }
            } else if ProcessInfo.processInfo.environment["SINGULARITY_BENCHMARK_ALTERNATE"]=="1" {
                for phase in 0..<8 {
                    app.view.benchmarkDirectGeometry=phase%2==0
                    log("PERFORMANCE_PHASE uptime=\(ProcessInfo.processInfo.systemUptime) direct=\(app.view.benchmarkDirectGeometry)")
                    try? await Task.sleep(nanoseconds:20_000_000_000)
                }
            } else {
                try? await Task.sleep(nanoseconds:UInt64(duration*1_000_000_000))
            }
            let elapsed=ProcessInfo.processInfo.systemUptime-start
            require(model.capturing && app.capture.latest() != nil,"performance capture stays connected")
            log("PERFORMANCE_RUN_END fps=\(Double(app.view.drawnFrames-frames)/elapsed) imports=\(app.view.importedFrames-imports) copies=\(app.view.copiedFrames-copies) cache-rebuilds=\(app.view.geometryCache?.rebuilds ?? 0)")
            NSApp.terminate(nil)
        }
    }

    static func recoveryPolicyChecks() {
        var budget=CaptureRetryBudget()
        for (i,delay) in [1.0,2,4,8,16].enumerated() {
            budget.connected(at:Double(i))
            require(budget.nextDelay(at:Double(i)+0.5)==delay,"bounded exponential backoff")
        }
        require(budget.nextDelay(at:6)==nil,"retry budget exhausted")
        budget.connected(at:10)
        require(budget.nextDelay(at:40)==1,"stable connection resets retry budget")
        budget.reset()
        require(budget.nextDelay(at:41)==1,"explicit request resets retry budget")
        for code in [-3802,-3804,-3805,-3806,-3811,-3813,-3814,-3815] {
            require(Capture.isRecoverable(NSError(domain:SCStreamErrorDomain,code:code)),"transient code \(code)")
        }
        for code in [-3801,-3803,-3812,-3817,-3821,-9999] {
            require(!Capture.isRecoverable(NSError(domain:SCStreamErrorDomain,code:code)),"terminal code \(code)")
        }
        require(!Capture.isRecoverable(NSError(domain:"unknown",code:-3805)),"unknown error domain")
        log("CAPTURE_POLICY_TEST_PASS retry-budget stable-reset user-stop permission-stop system-stop unknown")
    }

    @MainActor static func recoveryChecks(_ app:AppDelegate,screen:NSScreen) async {
        let capture=app.capture
        func interrupt(_ code:Int) {
            require(capture.activeID != nil,"fault injection requires active source")
            capture.interruptForSelfTest(NSError(domain:SCStreamErrorDomain,code:code),sourceID:capture.activeID)
        }
        capturedRenderCheck(app.view)
        let before=capture.activeID,oldFrame=capture.latest()
        interrupt(-3805)
        try? await Task.sleep(nanoseconds:200_000_000)
        require(!model.capturing && capture.retryPending,"active interruption schedules recovery")
        await waitForCapture(app,active:true)
        require(capture.activeID != before && capture.latest() !== oldFrame,"recovery replaces source and frame")
        capturedRenderCheck(app.view)
        if ProcessInfo.processInfo.environment["SINGULARITY_CAPTURE_FIXTURE"] != nil {
            let wasPaused=model.paused
            model.paused=true
            var previousPixels=capturedRenderCheck(app.view)
            var previousBuffer=capture.latest().map{ObjectIdentifier($0)}
            var changedFrames=0,changedRenders=0
            // Observe beyond the capture pool size to catch pinned IOSurfaces
            // that render correctly initially but prevent subsequent frames.
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds:100_000_000)
                let buffer=capture.latest().map{ObjectIdentifier($0)}
                if buffer != previousBuffer {changedFrames+=1;previousBuffer=buffer}
                let pixels=capturedRenderCheck(app.view)
                if pixels != previousPixels {changedRenders+=1;previousPixels=pixels}
                if changedFrames>=6 && changedRenders>=3 {break}
            }
            model.paused=wasPaused
            log("CAPTURE_REFRESH_DIAGNOSTIC changed-frames=\(changedFrames) changed-renders=\(changedRenders)")
            require(changedFrames>=6 && changedRenders>=3,"recovered desktop texture continuously updates beyond capture pool size while paused")
            log("CAPTURE_REFRESH_TEST_PASS live-generated-backdrop after-recovery sustained-frames")
        }
        if let before {
            capture.interruptForSelfTest(NSError(domain:SCStreamErrorDomain,code:-3817),sourceID:before)
            try? await Task.sleep(nanoseconds:100_000_000)
            require(model.capturing,"late user-stop from old stream cannot stop replacement")
        }
        interrupt(-3805)
        try? await Task.sleep(nanoseconds:100_000_000)
        require(capture.retryPending,"second interruption schedules recovery")
        app.togglePet()
        await waitForCapture(app,active:false)
        try? await Task.sleep(nanoseconds:2_200_000_000)
        require(!capture.wantsCapture && !capture.retryPending && capture.activeID==nil,"hide cancels pending retry")
        app.togglePet()
        await waitForCapture(app,active:true)

        // Exercise the same entry points as workspace events without sleeping the user's Mac.
        await capture.suspend()
        require(!model.capturing && capture.activeID==nil && capture.wantsCapture,"workspace suspension")
        await capture.suspend(.display)
        await capture.resume(screen:screen)
        require(capture.activeID==nil,"overlapping suspension waits for all wake events")
        await capture.resume(.display,screen:screen)
        await waitForCapture(app,active:true)
        capturedRenderCheck(app.view)

        await capture.suspend(.display)
        await capture.resume(.display,screen:nil)
        require(capture.awaitingScreen && capture.activeID==nil,"nil-screen wake retains restore intent")
        await capture.resume(.display,screen:screen)
        require(capture.awaitingScreen,"duplicate wake does not consume pending screen recovery")
        await capture.retarget(screen:screen)
        await waitForCapture(app,active:true)
        let resumed=capture.activeID
        await capture.retarget(screen:screen)
        require(!capture.awaitingScreen && capture.activeID==resumed,"same screen restores once without replacing source")
        capturedRenderCheck(app.view)

        await capture.suspend(.display)
        await capture.resume(.display,screen:nil)
        await waitForCapture(app,active:true)
        require(!capture.awaitingScreen,"short wake check restores without another screen notification")
        await capture.suspend(.display)
        await capture.resume(.display,screen:nil)
        await capture.start(screen:nil,requestPermission:false)
        try? await Task.sleep(nanoseconds:1_200_000_000)
        await capture.retarget(screen:screen)
        require(!capture.awaitingScreen && !capture.wantsCapture && capture.activeID==nil,"hide cancels pending screen restoration")
        await capture.start(screen:screen,requestPermission:false)
        await waitForCapture(app,active:true)
        log("CAPTURE_WAKE_TEST_PASS nil-screen same-screen duplicate-wake timer-fallback cancelled-restore")
        for code in [-3817,-3801,-3821] {
            interrupt(code)
            try? await Task.sleep(nanoseconds:1_200_000_000)
            require(!capture.wantsCapture && !capture.retryPending && capture.activeID==nil,"terminal stop \(code)")
            await capture.suspend();await capture.resume(screen:screen)
            await capture.retarget(screen:screen)
            require(capture.activeID==nil && !capture.wantsCapture,"lifecycle respects terminal stop")
            await capture.start(screen:screen,requestPermission:false)
            await waitForCapture(app,active:true)
        }
        log("CAPTURE_RECOVERY_TEST_PASS active-interruption fresh-texture cancelled-retry lifecycle terminal-stops")
    }

    @MainActor static func codexVisibilityChecks(_ app:AppDelegate) async {
        final class Probe:CodexStateProbing {
            var polls=0
            func poll(completion:@escaping(Result<CodexStateSnapshot,Error>)->Void) {
                polls+=1;completion(.success(CodexStateSnapshot(state:"idle")))
            }
            func cancel() {}
        }
        let previous=app.codexBridge,oldAuto=model.codexAuto
        let probe=Probe()
        let file=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("singularity-no-state-\(UUID())")
        let bridge=CodexStateBridge(model:model,stateFileURL:file,probe:probe)
        defer {
            bridge.stop();app.codexBridge=previous;model.codexAuto=oldAuto
            app.settings.orderOut(nil);app.restartCodexBridge()
        }
        app.settings.orderOut(nil);model.codexAuto=true;app.codexBridge=bridge
        app.restartCodexBridge()
        require(bridge.isRunning && bridge.hasScheduledTimer,"visible pet starts bridge")
        app.togglePet()
        let hiddenPolls=probe.polls
        try? await Task.sleep(nanoseconds:2_200_000_000)
        require(!bridge.isRunning && !bridge.hasScheduledTimer && probe.polls==hiddenPolls,"hidden pet and closed settings have no polling")
        app.showSettings()
        require(bridge.isRunning && probe.polls>hiddenPolls,"settings keep state live while pet hidden")
        app.settings.miniaturize(nil)
        try? await Task.sleep(nanoseconds:300_000_000)
        require(!bridge.isRunning,"minimized settings with hidden pet suspend bridge")
        app.showSettings()
        require(bridge.isRunning,"restored settings resume bridge")
        app.settings.performClose(nil)
        require(!bridge.isRunning && !bridge.hasScheduledTimer,"settings close suspends hidden bridge")
        app.togglePet()
        require(bridge.isRunning && bridge.hasScheduledTimer,"shown pet resumes bridge")
        await app.suspendActivity(.display)
        model.codexAuto=false;model.codexAuto=true
        require(!bridge.isRunning,"auto toggle cannot restart bridge while display suspended")
        await app.resumeActivity(.display)
        require(bridge.isRunning,"display resume restores visible bridge")
        log("CODEX_VISIBILITY_TEST_PASS hidden-no-poll settings-live minimize close show suspend")
    }

    static func launchBackdrop()->Process? {
        guard let path=ProcessInfo.processInfo.environment["SINGULARITY_CAPTURE_FIXTURE"] else{return nil}
        let process=Process()
        process.executableURL=URL(fileURLWithPath:path)
        process.standardInput=Pipe()
        do {try process.run();return process}
        catch {require(false,"capture backdrop launch: \(error)");return nil}
    }

    static func snapshotPixelChecks() {
        func make(_ alignment:Int,_ padding:UInt8)->CVPixelBuffer {
            var buffer:CVPixelBuffer?
            require(CVPixelBufferCreate(kCFAllocatorDefault,7,5,kCVPixelFormatType_32BGRA,
                [kCVPixelBufferBytesPerRowAlignmentKey:alignment] as CFDictionary,&buffer)==kCVReturnSuccess,"comparison buffer")
            let result=buffer!
            require(CVPixelBufferLockBaseAddress(result,[])==kCVReturnSuccess,"comparison write lock")
            let base=CVPixelBufferGetBaseAddress(result)!,stride=CVPixelBufferGetBytesPerRow(result)
            memset(base,Int32(padding),stride*5)
            for row in 0..<5 {memset(base.advanced(by:row*stride),42,28)}
            CVPixelBufferUnlockBaseAddress(result,[])
            return result
        }
        let a=make(64,1),b=make(128,2),rect=CGRect(x:2,y:3,width:7,height:5)
        let first=Capture.Snapshot(buffer:a,rect:rect),second=Capture.Snapshot(buffer:b,rect:rect)
        require(Capture.samePixels(first,first),"identical immutable buffer")
        require(Capture.samePixels(first,second),"comparison ignores unequal row padding")
        require(!Capture.samePixels(first,Capture.Snapshot(buffer:a,rect:rect.offsetBy(dx:1,dy:0))),"same buffer at new coordinates is new content")
        require(CVPixelBufferLockBaseAddress(b,[])==kCVReturnSuccess,"comparison mutation lock")
        CVPixelBufferGetBaseAddress(b)!.storeBytes(of:UInt8(43),toByteOffset:4*CVPixelBufferGetBytesPerRow(b)+27,as:UInt8.self)
        CVPixelBufferUnlockBaseAddress(b,[])
        require(!Capture.samePixels(first,second),"comparison detects final pixel and alpha change")
        log("CAPTURE_PIXEL_TEST_PASS equal padding stride final-pixel coordinates")
    }

    @MainActor static func adaptiveCaptureChecks(_ app:AppDelegate,screen:NSScreen,backdrop:Process) async {
        guard #available(macOS 14.0, *),!app.capture.forceStream else{return}
        guard let input=backdrop.standardInput as? Pipe else{require(false,"backdrop input");return}
        func command(_ text:String) {input.fileHandleForWriting.write(Data(text.utf8))}
        let capture=app.capture,oldFPS=model.backgroundFPS,oldPaused=model.paused,origin=app.pet.frame.origin
        defer {
            command("r");model.backgroundFPS=oldFPS;model.paused=oldPaused
            app.pet.setFrameOrigin(origin);app.checkScreen()
        }
        model.backgroundFPS=10
        // Keep this deterministic fixture away from the Dock and menu-bar overlays.
        app.pet.setFrameOrigin(CGPoint(x:screen.frame.midX-app.pet.frame.width/2,y:screen.frame.midY-app.pet.frame.height/2))
        await capture.retarget(screen:screen)
        command("p")
        let beforeIdle=capture.screenshotRequests,beforeUnchanged=capture.unchangedScreenshots
        try? await Task.sleep(nanoseconds:2_000_000_000)
        for _ in 0..<15 {
            if capture.appliedFramesPerSecond==2 {break}
            try? await Task.sleep(nanoseconds:200_000_000)
        }
        log("CAPTURE_ADAPTIVE_DIAGNOSTIC requests=\(capture.screenshotRequests-beforeIdle) unchanged=\(capture.unchangedScreenshots-beforeUnchanged) fps=\(capture.appliedFramesPerSecond)")
        require(capture.appliedFramesPerSecond==2,"unchanged live backdrop enters idle cadence")
        let requests=capture.screenshotRequests,frame=capture.latest(),draws=app.view.drawnFrames
        try? await Task.sleep(nanoseconds:2_000_000_000)
        require((3...5).contains(capture.screenshotRequests-requests),"idle capture continues bounded polling")
        require(capture.latest() === frame,"unchanged screenshots retain the existing texture")
        require(app.view.drawnFrames>=draws+48,"animation remains near 30 FPS while capture idles")
        model.paused=true
        try? await Task.sleep(nanoseconds:300_000_000)
        let pausedDraws=app.view.drawnFrames
        try? await Task.sleep(nanoseconds:1_000_000_000)
        require(app.view.drawnFrames==pausedDraws,"identical screenshots do not redraw paused animation")
        let oldPixels=capturedRenderCheck(app.view)
        let before=ProcessInfo.processInfo.systemUptime
        command("s")
        for _ in 0..<60 {
            if capture.latest() !== frame {break}
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        require(capture.latest() !== frame && capture.appliedFramesPerSecond==10,"new real pixels restore responsive capture")
        require(ProcessInfo.processInfo.systemUptime-before<1.2,"live detection remains bounded after idle")
        for _ in 0..<30 {
            if app.view.drawnFrames>pausedDraws && app.view.uploaded === capture.latest() {break}
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        require(app.view.drawnFrames>pausedDraws && app.view.uploaded === capture.latest(),"normal paused draw path imports changed desktop")
        require(capturedRenderCheck(app.view) != oldPixels,"step changes the rendered background pixels")
        try? await Task.sleep(nanoseconds:1_500_000_000)
        for _ in 0..<20 {
            if capture.appliedFramesPerSecond==2 {break}
            try? await Task.sleep(nanoseconds:200_000_000)
        }
        require(capture.appliedFramesPerSecond==2,"capture returns to idle after change")
        app.view.dragging=true
        await capture.retarget(screen:screen)
        for _ in 0..<40 {
            if capture.appliedFramesPerSecond==30 {break}
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        require(capture.appliedFramesPerSecond==30,"drag wakes idle sampling")
        app.view.dragging=false
        await capture.retarget(screen:screen)
        log("CAPTURE_ADAPTIVE_TEST_PASS idle-live-poll no-upload animated paused-static change-detection drag-wake")
    }

    @MainActor static func streamStartRetargetChecks(_ app:AppDelegate,screen:NSScreen) async {
        let capture=app.capture,oldForce=capture.forceStream,oldFPS=model.backgroundFPS,origin=app.pet.frame.origin
        capture.forceStream=true;capture.selfTestStreamStartDelay=600_000_000
        model.backgroundFPS=10
        await capture.start(screen:nil)
        let starting=Task{@MainActor in await capture.start(screen:screen,requestPermission:false)}
        for _ in 0..<40 {
            if capture.stream != nil {break}
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        require(capture.stream != nil && capture.busy,"stream startup delay active")
        app.pet.setFrameOrigin(CGPoint(x:screen.frame.midX-app.pet.frame.width/2,y:screen.frame.midY-app.pet.frame.height/2))
        model.backgroundFPS=15
        await capture.retarget(screen:screen)
        await starting.value
        await waitForCapture(app,active:true)
        let expected:CGRect
        if #available(macOS 13.1, *) {expected=CaptureRegion.region(for:app.pet.frame,on:screen.frame)}
        else {expected=screen.frame}
        for _ in 0..<60 {
            if capture.latestSnapshot()?.rect==expected && capture.appliedFramesPerSecond==15 {break}
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        require(capture.latestSnapshot()?.rect==expected && capture.appliedFramesPerSecond==15,"startup movement and cadence actually applied")
        capture.selfTestStreamStartDelay=0;capture.forceStream=oldForce;model.backgroundFPS=oldFPS
        app.pet.setFrameOrigin(origin)
        await capture.start(screen:screen,requestPermission:false)
        await waitForCapture(app,active:true)
        log("CAPTURE_START_RETARGET_TEST_PASS delayed-start moved-crop updated-cadence")
    }

    @discardableResult @MainActor static func capturedRenderCheck(_ view:PetView,snapshot:Capture.Snapshot?=nil)->[UInt8] {
        require(model.capturing && view.capture.latest() != nil,"real background frame available")
        view.openGLContext?.makeCurrentContext()
        var previous:GLint=0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING),&previous)
        var fbo:GLuint=0,color:GLuint=0
        glGenFramebuffers(1,&fbo);glGenTextures(1,&color)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER),fbo)
        glBindTexture(GLenum(GL_TEXTURE_2D),color)
        glTexImage2D(GLenum(GL_TEXTURE_2D),0,GL_RGBA8,280,280,0,GLenum(GL_RGBA),GLenum(GL_UNSIGNED_BYTE),nil)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER),GLenum(GL_COLOR_ATTACHMENT0),GLenum(GL_TEXTURE_2D),color,0)
        glDrawBuffer(GLenum(GL_COLOR_ATTACHMENT0));glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
        defer {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER),GLuint(previous))
            glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&color)
        }
        require(glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))==GL_FRAMEBUFFER_COMPLETE,"capture framebuffer")
        let fixedFrame=snapshot ?? view.capture.latestSnapshot()
        func pixels(_ enabled:Bool,cpu:Bool=false)->[UInt8] {
            view.renderFrame(width:280,height:280,useCapture:enabled,captureBuffer:fixedFrame?.buffer,
                             captureSourceRect:fixedFrame?.rect,forceCPUUpload:cpu)
            var bytes=[UInt8](repeating:0,count:280*280*4)
            bytes.withUnsafeMutableBytes{glReadPixels(0,0,280,280,GLenum(GL_RGBA),GLenum(GL_UNSIGNED_BYTE),$0.baseAddress)}
            return bytes
        }
        let without=pixels(false)
        // Force an upload; the capture queue may deliver another frame during GPU readback.
        view.uploaded=nil
        let with=pixels(true)
        require(view.uploaded != nil,"real frame uploaded by renderer")
        let imported=view.usingDesktopSurface
        let reference=pixels(true,cpu:true)
        let maxDifference=zip(with,reference).map{abs(Int($0)-Int($1))}.max() ?? 0
        require(maxDifference<=2,"shared texture matches CPU upload including orientation and color: \(maxDifference)")
        if imported {log("TEXTURE_EQUIVALENCE_TEST_PASS zero-copy cpu-reference max-difference=\(maxDifference)")}
        else {log("TEXTURE_ZERO_COPY_SKIPPED import unavailable; CPU fallback verified")}
        view.uploaded=nil
        _=pixels(true)
        var changed=0
        for pixel in stride(from:0,to:with.count,by:4) {
            if abs(Int(with[pixel])-Int(without[pixel]))>10 ||
                abs(Int(with[pixel+1])-Int(without[pixel+1]))>10 ||
                abs(Int(with[pixel+2])-Int(without[pixel+2]))>10 {changed+=1}
        }
        require(changed>100,"captured desktop contributes visible color to rendered lens")
        require(glGetError()==GL_NO_ERROR,"captured texture GPU readback")
        // Actual desktop pixels are compared only in memory and are never exported.
        log("CAPTURE_RENDER_TEST_PASS real-frame texture-upload lens-contribution")
        return with
    }

    @MainActor static func multiBodyCaptureChecks(_ app:AppDelegate,screen:NSScreen) async {
        let oldCount=model.bodyCount,oldPaused=model.paused,origin=app.pet.frame.origin
        defer {
            model.bodyCount=oldCount;model.paused=oldPaused
            app.pet.setFrameOrigin(origin);app.checkScreen()
        }
        model.paused=true
        for count in [2,3] {
            model.bodyCount=count
            app.pet.setFrameOrigin(CGPoint(x:screen.visibleFrame.midX-app.pet.frame.width/2,
                                          y:screen.visibleFrame.midY-app.pet.frame.height/2))
            await app.capture.retarget(screen:screen)
            await waitForCapture(app,active:true)
            let bodies=app.view.orbitalBodies
            var previous=capturedRenderCheck(app.view),changes=0
            if ProcessInfo.processInfo.environment["SINGULARITY_CAPTURE_FIXTURE"] != nil {
                for _ in 0..<50 {
                    try? await Task.sleep(nanoseconds:100_000_000)
                    let current=capturedRenderCheck(app.view)
                    if current != previous {changes+=1;previous=current}
                    if changes>=4 {break}
                }
                require(changes>=4,"multi live desktop keeps refreshing while paused count=\(count)")
            }
            require(app.view.orbitalBodies==bodies,"paused multi-body positions stay fixed")
            app.togglePet()
            await waitForCapture(app,active:false)
            require(app.view.timer==nil && !app.view.multiLens.hasResources,"hidden multi releases rendering")
            app.togglePet()
            await waitForCapture(app,active:true)
            capturedRenderCheck(app.view)
            require(app.view.multiLens.hasResources,"multi restores live desktop after show")
            log("MULTIBODY_CAPTURE_TEST_PASS count=\(count) changed-renders=\(changes) paused-background hide-show")
        }
    }

    @MainActor static func regionCaptureChecks(_ app:AppDelegate,screen:NSScreen) async {
        guard #available(macOS 13.1, *) else{return}
        let capture=app.capture,origin=app.pet.frame.origin,oldPaused=model.paused
        model.paused=true
        capture.forceFullDisplay=true
        await capture.start(screen:screen,requestPermission:false)
        await waitForCapture(app,active:true)
        guard let full=capture.latestSnapshot() else {require(false,"full reference frame");return}
        let region=CaptureRegion.region(for:app.pet.frame,on:screen.frame)
        let scale=CGFloat(CVPixelBufferGetWidth(full.buffer))/full.rect.width
        let width=Int((region.width*scale).rounded()),height=Int((region.height*scale).rounded())
        let x=Int(((region.minX-full.rect.minX)*scale).rounded())
        let y=Int(((full.rect.maxY-region.maxY)*scale).rounded())
        var cropped:CVPixelBuffer?
        require(CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,
                                   [kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&cropped)==kCVReturnSuccess,"crop fixture allocation")
        guard let cropped else {require(false,"crop fixture buffer");return}
        require(CVPixelBufferLockBaseAddress(full.buffer,.readOnly)==kCVReturnSuccess,"full fixture lock")
        require(CVPixelBufferLockBaseAddress(cropped,[])==kCVReturnSuccess,"crop fixture lock")
        let source=CVPixelBufferGetBaseAddress(full.buffer)!,destination=CVPixelBufferGetBaseAddress(cropped)!
        for row in 0..<height {
            destination.advanced(by:row*CVPixelBufferGetBytesPerRow(cropped)).copyMemory(
                from:source.advanced(by:(row+y)*CVPixelBufferGetBytesPerRow(full.buffer)+x*4),byteCount:width*4)
        }
        CVPixelBufferUnlockBaseAddress(cropped,[])
        CVPixelBufferUnlockBaseAddress(full.buffer,.readOnly)
        let fullPixels=capturedRenderCheck(app.view,snapshot:full)
        let cropPixels=capturedRenderCheck(app.view,snapshot:Capture.Snapshot(buffer:cropped,rect:region))
        let difference=zip(fullPixels,cropPixels).map{abs(Int($0)-Int($1))}.max() ?? 0
        require(difference<=2,"full versus cropped background mapping: \(difference)")
        capture.forceFullDisplay=false
        await capture.start(screen:screen,requestPermission:false)
        await waitForCapture(app,active:true)
        let sourceID=capture.activeID,updates=capture.configurationUpdates
        func waitForRegion(_ expected:CGRect,target:NSScreen?=nil,full:Bool=false) async {
            let target=target ?? screen
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds:50_000_000)
                if let snapshot=capture.latestSnapshot(),snapshot.rect.contains(expected) {
                    if full && snapshot.rect != target.frame {continue}
                    if !full && snapshot.rect==target.frame {continue}
                    let resolution=CGFloat(CVPixelBufferGetWidth(snapshot.buffer))/snapshot.rect.width
                    require(abs(resolution-target.backingScaleFactor)<0.02,"native pixel density preserved")
                    return
                }
            }
            require(false,"fresh frame covers requested region \(expected)")
        }
        for point in [CGPoint(x:screen.frame.minX+40,y:screen.frame.minY+40),
                      CGPoint(x:screen.frame.midX-100,y:screen.frame.midY-100),
                      CGPoint(x:screen.frame.maxX-app.pet.frame.width+40,y:screen.frame.maxY-app.pet.frame.height+40)] {
            let previous=capture.latestSnapshot()
            let previousRect=previous?.rect
            app.pet.setFrameOrigin(point)
            await capture.retarget(screen:screen)
            await waitForRegion(app.pet.frame.intersection(screen.frame))
            require(capture.activeID==sourceID,"moving crop reuses capture source")
            require(previous?.rect==previousRect,"retained frame geometry is immutable")
            capturedRenderCheck(app.view)
        }
        app.view.dragging=true
        await capture.retarget(screen:screen)
        await waitForRegion(screen.frame,full:true)
        app.view.dragging=false
        await capture.retarget(screen:screen)
        await waitForRegion(app.pet.frame.intersection(screen.frame))
        require(capture.configurationUpdates>updates,"region updates applied")
        let oldFPS=model.backgroundFPS
        for fps in [30,15,10] {
            model.backgroundFPS=fps
            await capture.retarget(screen:screen)
            for _ in 0..<30 {
                if capture.appliedFramesPerSecond==fps {break}
                try? await Task.sleep(nanoseconds:50_000_000)
            }
            require(capture.appliedFramesPerSecond==fps && capture.activeID==sourceID,"cadence changes without replacing source")
        }
        model.backgroundFPS=oldFPS
        let moves=(0..<12).map {i in Task{@MainActor in
            app.pet.setFrameOrigin(CGPoint(x:screen.frame.minX+CGFloat(i)*24,y:screen.frame.minY+40))
            await capture.retarget(screen:screen)
        }}
        for move in moves {await move.value}
        await waitForRegion(app.pet.frame.intersection(screen.frame))
        let update=Task{@MainActor in
            app.pet.setFrameOrigin(CGPoint(x:screen.frame.midX,y:screen.frame.midY))
            await capture.retarget(screen:screen)
        }
        let pause=Task{@MainActor in await capture.start(screen:nil)}
        await update.value;await pause.value
        try? await Task.sleep(nanoseconds:300_000_000)
        require(!model.capturing && capture.activeID==nil && capture.latest()==nil,"in-flight region update cannot revive paused source")
        await capture.start(screen:screen,requestPermission:false)
        await waitForCapture(app,active:true)
        var displaysChecked=1
        for other in NSScreen.screens where other != screen {
            app.pet.setFrameOrigin(CGPoint(x:other.frame.midX-app.pet.frame.width/2,y:other.frame.midY-app.pet.frame.height/2))
            await capture.retarget(screen:other)
            await waitForCapture(app,active:true)
            await waitForRegion(app.pet.frame.intersection(other.frame),target:other)
            capturedRenderCheck(app.view)
            displaysChecked+=1
        }
        app.pet.setFrameOrigin(origin)
        await capture.retarget(screen:screen)
        await waitForCapture(app,active:true)
        await waitForRegion(app.pet.frame.intersection(screen.frame))
        model.paused=oldPaused
        log("CAPTURE_REGION_TEST_PASS pixel-equivalence=\(difference) displays=\(displaysChecked) native-scale moving-crop same-source dragging-full restore-crop immutable-frame cadence rapid-move pause-race")
    }

    @MainActor static func waitForCapture(_ app:AppDelegate,active:Bool) async {
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds:100_000_000)
            if !app.capture.busy && model.capturing==active {
                if active && app.capture.latest() != nil {return}
                if !active && app.capture.activeID==nil {return}
            }
        }
        require(false,"visibility/capture reconciliation active=\(active): \(model.error)")
    }

    @MainActor static func snapshotLifecycleChecks(_ app:AppDelegate,screen:NSScreen) async {
        guard #available(macOS 14.0, *),!app.capture.forceStream else{return}
        let capture=app.capture
        let requests=capture.screenshotRequests
        capture.selfTestScreenshotDelay=500_000_000
        for _ in 0..<30 {
            if capture.screenshotRequests>requests {break}
            try? await Task.sleep(nanoseconds:20_000_000)
        }
        require(capture.screenshotRequests>requests,"delayed snapshot request starts")
        await capture.start(screen:nil)
        try? await Task.sleep(nanoseconds:600_000_000)
        require(capture.activeID==nil && capture.latest()==nil && !model.capturing,"late snapshot cannot revive hidden capture")
        capture.selfTestScreenshotDelay=0
        await capture.start(screen:screen,requestPermission:false)
        await waitForCapture(app,active:true)
        capturedRenderCheck(app.view)
        capture.selfTestScreenshotDelay=4_000_000_000
        let previous=capture.activeID
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds:50_000_000)
            if model.capturing && capture.stream != nil && capture.activeID != previous {break}
        }
        capture.selfTestScreenshotDelay=0
        require(model.capturing && capture.stream != nil && capture.activeID != previous,"stalled snapshot falls back to a fresh stream")
        capturedRenderCheck(app.view)
        await capture.start(screen:screen,requestPermission:false)
        await waitForCapture(app,active:true)
        require(capture.stream != nil,"automatic reconnect retains safe backend fallback")
        let requestsBeforeRetry=capture.screenshotRequests
        await capture.start(screen:screen,requestPermission:false,retryPreferredBackend:true)
        await waitForCapture(app,active:true)
        require(capture.stream==nil && capture.screenshotRequests>requestsBeforeRetry,"explicit reconnect restores preferred screenshot backend")
        capturedRenderCheck(app.view)
        capture.selfTestScreenshotDelay=4_000_000_000
        for _ in 0..<120 {
            try? await Task.sleep(nanoseconds:50_000_000)
            if model.capturing && capture.stream != nil {break}
        }
        capture.selfTestScreenshotDelay=0
        require(model.capturing && capture.stream != nil,"persistent failure returns to bounded stream fallback")
        let settledRequests=capture.screenshotRequests
        try? await Task.sleep(nanoseconds:1_200_000_000)
        require(capture.screenshotRequests==settledRequests,"fallback never automatically oscillates back to screenshots")
        await capture.start(screen:screen,requestPermission:false,retryPreferredBackend:true)
        await waitForCapture(app,active:true)
        log("CAPTURE_BACKEND_RETRY_TEST_PASS explicit-restore normal-reconnect persistent-failure no-oscillation")
        log("CAPTURE_SNAPSHOT_TEST_PASS late-frame pause resume timeout stream-fallback real-background")
    }

    static func renderChecks(_ view:PetView) {
        var previous:GLint=0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING),&previous)
        var fbo:GLuint=0,color:GLuint=0
        glGenFramebuffers(1,&fbo);glGenTextures(1,&color)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER),fbo)
        defer {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER),GLuint(previous))
            glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&color)
        }
        func pixels(_ size:Int,buffer:CVPixelBuffer?=nil,cpu:Bool=false,uncached:Bool=false)->[UInt8] {
            glBindTexture(GLenum(GL_TEXTURE_2D),color)
            glTexImage2D(GLenum(GL_TEXTURE_2D),0,GL_RGBA8,GLsizei(size),GLsizei(size),0,GLenum(GL_RGBA),GLenum(GL_UNSIGNED_BYTE),nil)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER),GLenum(GL_COLOR_ATTACHMENT0),GLenum(GL_TEXTURE_2D),color,0)
            glDrawBuffer(GLenum(GL_COLOR_ATTACHMENT0));glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
            require(glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))==GL_FRAMEBUFFER_COMPLETE,"framebuffer")
            view.renderFrame(width:GLsizei(size),height:GLsizei(size),useCapture:buffer != nil,captureBuffer:buffer,forceCPUUpload:cpu,forceUncachedGeometry:uncached)
            var bytes=[UInt8](repeating:0,count:size*size*4)
            bytes.withUnsafeMutableBytes{glReadPixels(0,0,GLsizei(size),GLsizei(size),GLenum(GL_RGBA),GLenum(GL_UNSIGNED_BYTE),$0.baseAddress)}
            require(glGetError()==GL_NO_ERROR,"GPU render/readback")
            return bytes
        }
        model.mass=1;model.brightness=2.2;model.tilt=1.2;model.roll=0.18
        model.kind=1;model.spin=0.7;model.customColor=false;model.paused=false
        var cases=0
        for size in [280,560,1400] {
            for style in 0...3 {
                model.style=style
                for state in CodexActivityState.allCases {
                    model.setCodexState(state,source:"self-test")
                    model.codexPulse=(state == .complete || state == .error) ? 1:0
                    view.codexEnergySmooth=state.energy;view.codexTrailSmooth=state.trail
                    view.codexParticlesSmooth=state.particleDensity
                    view.clock=2;view.diskPhase=3;view.dustPhase=1
                    let image=pixels(size)
                    let reference=pixels(size,uncached:true)
                    let difference=zip(image,reference).map{abs(Int($0)-Int($1))}.max() ?? 0
                    require(difference<=2,"geometry cache equivalence \(size)/\(style)/\(state.token): \(difference)")
                    require(image[3]==0,"transparent corner")
                    let center=(size/2*size+size/2)*4
                    require(image[center+3]>240 && image[center]<16 && image[center+1]<16 && image[center+2]<16,"opaque black shadow")
                    var lit=0
                    for pixel in stride(from:0,to:image.count,by:4) {
                        if image[pixel]>25 || image[pixel+1]>25 || image[pixel+2]>25 {lit+=1}
                    }
                    // Pure-lens mode intentionally has no luminous disk without a desktop.
                    require(style==3 || lit>10,"nonblank state/style \(state.token)/\(style)")
                    cases+=1
                    if size==560 && (style==0 || state == .command) {
                        savePNG(image,size:size,name:"style-\(style)-\(state.token)")
                    }
                }
            }
        }
        model.style=0;model.setCodexState(.command,source:"self-test");model.codexPulse=0
        let before=pixels(280)
        view.advanceAnimation(dt:0.1)
        require(pixels(280) != before,"animation moves")
        model.paused=true
        let paused=pixels(280),phase=view.diskPhase
        view.advanceAnimation(dt:0.1)
        require(view.diskPhase==phase && pixels(280)==paused,"pause freezes animation")
        model.paused=false;view.advanceAnimation(dt:0.1)
        require(pixels(280) != paused,"resume moves")
        log("RENDER_TEST_PASS \(cases) state/style/scale frames shadow transparency movement pause-resume")
        require(view.geometryCache?.available==true,"geometry cache active")
        log("GEOMETRY_EQUIVALENCE_TEST_PASS \(cases) cached/reference frames")
        let wasCapturing=model.capturing,oldRect=view.capture.screenRect
        model.capturing=true
        view.capture.screenRect=view.window?.frame ?? NSRect(x:0,y:0,width:280,height:280)
        defer {model.capturing=wasCapturing;view.capture.screenRect=oldRect;view.uploaded=nil}
        for shared in [true,false] {
            var buffer:CVPixelBuffer?
            let attributes:[String:Any]=shared ? [kCVPixelBufferIOSurfacePropertiesKey as String:[:]]:[:]
            require(CVPixelBufferCreate(kCFAllocatorDefault,64,64,kCVPixelFormatType_32BGRA,attributes as CFDictionary,&buffer)==kCVReturnSuccess,"generated texture allocation")
            guard let buffer else {require(false,"generated texture");return}
            require(CVPixelBufferLockBaseAddress(buffer,[])==kCVReturnSuccess,"generated texture lock")
            let base=CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self)
            let row=CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 {
                for x in 0..<64 {
                    let offset=y*row+x*4
                    base[offset]=UInt8(x*4);base[offset+1]=UInt8(y*4)
                    base[offset+2]=UInt8((x/8+y/8)%2==0 ? 240:20);base[offset+3]=255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer,[])
            view.uploaded=nil
            let imported=pixels(280,buffer:buffer)
            require(view.usingDesktopSurface==shared,"IOSurface import or memory-buffer fallback")
            let reference=pixels(280,buffer:buffer,cpu:true)
            let maxDifference=zip(imported,reference).map{abs(Int($0)-Int($1))}.max() ?? 0
            require(maxDifference<=2,"generated texture color/orientation equivalence \(maxDifference)")
            for family in 0...3 {
                model.kind=family
                for mass in [0.65,1.0,1.45] {
                    model.mass=mass;model.spin = family % 2 == 0 ? 0.85 : -0.58
                    model.charge=0.6;model.lens=18.6;model.tilt=1.45;model.roll=0.13
                    let image=pixels(280,buffer:buffer)
                    let rebuilds=view.geometryCache!.rebuilds
                    let direct=pixels(280,buffer:buffer,uncached:true)
                    let difference=zip(image,direct).map{abs(Int($0)-Int($1))}.max() ?? 0
                    require(difference<=2,"lensed geometry cache family=\(family) mass=\(mass): \(difference)")
                    view.advanceAnimation(dt:0.03)
                    _=pixels(280,buffer:buffer)
                    require(view.geometryCache!.rebuilds==rebuilds,"animation and desktop retain geometry cache")
                }
            }
            log("TEXTURE_SYNTHETIC_TEST_PASS shared=\(shared) max-difference=\(maxDifference)")
        }
        model.mass=0.65;model.kind=3;model.spin = -0.58;model.charge=0.376
        model.style=1;model.setCodexState(.longTask,source:"self-test")
        _=pixels(584)
        var query:GLuint=0
        glGenQueries(1,&query)
        var cachedTimes=[Double](),directTimes=[Double]()
        for run in 0..<6 {
            let direct=run % 2 == 0
            glFinish()
            glBeginQuery(GLenum(GL_TIME_ELAPSED),query)
            for _ in 0..<60 {
                view.advanceAnimation(dt:1.0/30)
                view.renderFrame(width:584,height:584,useCapture:false,forceUncachedGeometry:direct)
            }
            glEndQuery(GLenum(GL_TIME_ELAPSED))
            var nanoseconds:GLuint64=0
            glGetQueryObjectui64v(query,GLenum(GL_QUERY_RESULT),&nanoseconds)
            if direct {directTimes.append(Double(nanoseconds)/60/1_000_000)}
            else {cachedTimes.append(Double(nanoseconds)/60/1_000_000)}
        }
        glDeleteQueries(1,&query)
        require(glGetError()==GL_NO_ERROR,"GPU timer query")
        log("GEOMETRY_GPU_BENCHMARK cached-ms=\(cachedTimes) direct-ms=\(directTimes)")
        let rebuilds=view.geometryCache!.rebuilds
        view.geometryCache?.release()
        _=pixels(584)
        require(view.geometryCache!.rebuilds==rebuilds+1,"released geometry is rebuilt")
        let mutations:[()->Void]=[
            {model.lens+=0.7},{model.tilt-=0.12},{model.roll+=0.2},
            {model.spin+=0.2},{model.charge-=0.1},{model.mass+=0.1},{model.style=2}]
        for mutate in mutations {
            let count=view.geometryCache!.rebuilds
            mutate()
            let cached=pixels(584),direct=pixels(584,uncached:true)
            require(view.geometryCache!.rebuilds==count+1,"geometry parameter invalidates cache")
            let delta=zip(cached,direct).map{abs(Int($0)-Int($1))}.max() ?? 0
            require(delta<=2,"updated geometry matches direct path \(delta)")
        }
        log("GEOMETRY_CACHE_TEST_PASS families desktop animation lifetime")
    }

    static func savePNG(_ pixels:[UInt8],size:Int,name:String) {
        guard let path=ProcessInfo.processInfo.environment["SINGULARITY_QA_OUTPUT"] else{return}
        let directory=URL(fileURLWithPath:path,isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            guard let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bitmapFormat:.alphaNonpremultiplied,bytesPerRow:size*4,bitsPerPixel:32),
                  let data=rep.bitmapData else {require(false,"PNG allocation");return}
            for row in 0..<size {
                let start=(size-1-row)*size*4
                pixels.withUnsafeBytes{source in
                    data.advanced(by:row*size*4).update(from:source.baseAddress!.advanced(by:start).assumingMemoryBound(to:UInt8.self),count:size*4)
                }
            }
            guard let png=rep.representation(using:.png,properties:[:]) else {require(false,"PNG encoding");return}
            try png.write(to:directory.appendingPathComponent(name+".png"),options:.atomic)
        } catch {require(false,"PNG output: \(error)")}
    }

    static func multiBodyRenderChecks(_ view:PetView) {
        let oldCount=model.bodyCount,oldSize=model.size,oldCapture=model.capturing
        let oldRect=view.capture.screenRect,oldOrigin=view.window?.frame.origin
        var previous:GLint=0,fbo:GLuint=0,color:GLuint=0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING),&previous)
        glGenFramebuffers(1,&fbo);glGenTextures(1,&color)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER),fbo)
        defer {
            model.bodyCount=oldCount;model.size=oldSize;model.capturing=oldCapture
            if let oldOrigin {view.window?.setFrameOrigin(oldOrigin)}
            view.capture.screenRect=oldRect
            view.uploaded=nil
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER),GLuint(previous))
            glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&color)
        }
        var buffer:CVPixelBuffer?
        require(CVPixelBufferCreate(kCFAllocatorDefault,128,128,kCVPixelFormatType_32BGRA,
                                   [kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&buffer)==kCVReturnSuccess,"multi texture")
        guard let buffer else {require(false,"multi texture exists");return}
        CVPixelBufferLockBaseAddress(buffer,[])
        let base=CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<128 {for x in 0..<128 {
            let offset=y*row+x*4
            base[offset]=UInt8(x*2);base[offset+1]=UInt8(y*2)
            base[offset+2]=UInt8((x/16+y/16)%2==0 ? 220:30);base[offset+3]=255
        }}
        CVPixelBufferUnlockBaseAddress(buffer,[])
        func pixels(_ size:Int,capture:Bool=true,cpu:Bool=false,uncached:Bool=false)->[UInt8] {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER),fbo)
            glActiveTexture(GLenum(GL_TEXTURE0));glBindTexture(GLenum(GL_TEXTURE_2D),color)
            glTexImage2D(GLenum(GL_TEXTURE_2D),0,GL_RGBA8,GLsizei(size),GLsizei(size),0,GLenum(GL_RGBA),GLenum(GL_UNSIGNED_BYTE),nil)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER),GLenum(GL_COLOR_ATTACHMENT0),GLenum(GL_TEXTURE_2D),color,0)
            glDrawBuffer(GLenum(GL_COLOR_ATTACHMENT0));glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
            model.capturing=capture
            view.renderFrame(width:GLsizei(size),height:GLsizei(size),useCapture:capture,captureBuffer:capture ? buffer:nil,
                             captureSourceRect:view.window?.frame,forceCPUUpload:cpu,forceUncachedGeometry:uncached)
            var data=[UInt8](repeating:0,count:size*size*4)
            data.withUnsafeMutableBytes {glReadPixels(0,0,GLsizei(size),GLsizei(size),GLenum(GL_RGBA),GLenum(GL_UNSIGNED_BYTE),$0.baseAddress)}
            require(glGetError()==GL_NO_ERROR,"multi framebuffer render/readback")
            return data
        }
        model.bodyCount=1;model.style=0;model.kind=0;model.mass=0.85;model.tilt=1.30;model.roll=0.12
        model.setCodexState(.idle,source:"multi-self-test");model.codexPulse=0
        let single=pixels(560)
        var cases=0
        for count in [2,3] {
            model.bodyCount=count
            require(view.orbitalBodies.count==count,"body count \(count)")
            for size in [280,560,1120] {
                for style in 0...3 {
                    model.style=style
                    let image=pixels(size)
                    require(view.multiLens.available && view.multiLens.hasResources,"multi renderer active")
                    require(image[3]==0 && image[(size*size-1)*4+3]==0,"multi transparent corners")
                    let alphaPixels=stride(from:3,to:image.count,by:4).filter{image[$0]>240}.count
                    require(alphaPixels>size*size/30 && alphaPixels<size*size*3/4,"multi bounded nonblank coverage")
                    let direct=pixels(size,uncached:true)
                    let delta=zip(image,direct).map{abs(Int($0)-Int($1))}.max() ?? 0
                    require(delta<=3,"multi cached/reference count=\(count) size=\(size) style=\(style) delta=\(delta)")
                    if size==560 && style==0 {savePNG(image,size:size,name:"multi-\(count)-desktop")}
                    cases+=1
                }
            }
            model.style=0
            let imported=pixels(560),cpu=pixels(560,cpu:true)
            require((zip(imported,cpu).map{abs(Int($0)-Int($1))}.max() ?? 0)<=3,"multi zero-copy orientation/color")
            view.multiLens.stacksLensing=false
            let independent=pixels(560)
            view.multiLens.stacksLensing=true
            let coupledDifference=zip(imported,independent).filter{abs(Int($0)-Int($1))>3}.count
            require(coupledDifference>100,"foreground lens samples the previous body, not just the desktop")
            let bare=pixels(560,capture:false)
            require(stride(from:0,to:bare.count,by:4).filter{bare[$0]>30 || bare[$0+1]>30}.count>30,"multi no-permission visible disks")
            savePNG(bare,size:560,name:"multi-\(count)-transparent")
            let still=pixels(560)
            let rebuilds=view.multiLens.cacheRebuilds,allocations=view.multiLens.allocations
            require(pixels(560)==still,"multi frozen state deterministic")
            let stationaryBodies=view.orbitalBodies
            for _ in 0..<30 {view.advanceAnimation(dt:1.0/30)}
            let flowing=pixels(560)
            require(view.orbitalBodies==stationaryBodies,"light flow does not move bodies")
            let flowChanges=zip(still,flowing).filter{abs(Int($0)-Int($1))>8}.count
            require(flowChanges>100,"multi light flow remains visible independently of orbit movement")
            savePNG(flowing,size:560,name:"multi-\(count)-flow")
            for _ in 0..<30 {view.orbits?.advance(dt:1.0/30,speed:0.65);view.advanceAnimation(dt:1.0/30)}
            require(pixels(560) != still,"multi animation and orbital movement")
            require(view.multiLens.cacheRebuilds==rebuilds,"orbital motion keeps ray geometry")
            require(view.multiLens.allocations==allocations,"orbital motion reuses scene buffers")
            for body in view.orbitalBodies {
                let r=MultiLensRenderer.rect(for:body)
                let point=CGPoint(x:r.midX*view.bounds.width,y:(1-r.midY)*view.bounds.height)
                require(view.hitsBody(point,margin:0.27),"multi drag hit target")
            }
            view.setRenderingActive(false)
            require(!view.multiLens.hasResources && view.timer==nil,"hidden multi releases buffers and timer")
            view.setRenderingActive(true)
            _=pixels(560)
            require(view.multiLens.hasResources,"multi resumes rendering")
            view.resetOrbits()
            for _ in 0..<14_400 {
                view.orbits?.advance(dt:1.0/120)
                if view.orbitalBodies.contains(where:{$0.impact>0.1}) {break}
            }
            require(view.orbitalBodies.contains(where:{$0.impact>0.1}),"multi contact produces a collision pulse")
            savePNG(pixels(560),size:560,name:"multi-\(count)-collision")
        }
        model.bodyCount=1;model.style=0
        // Animation has advanced, so compare the reference at the same phases instead.
        let restored=pixels(560),reference=pixels(560,uncached:true)
        require((zip(restored,reference).map{abs(Int($0)-Int($1))}.max() ?? 0)<=2,"single path remains valid after switching")
        require(single[3]==0,"single baseline transparency")
        log("MULTIBODY_RENDER_TEST_PASS \(cases) cached-reference zero-copy transparency coupled-lensing motion light-flow collision stable-cache lifecycle hits")
    }
}
