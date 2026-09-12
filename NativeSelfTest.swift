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
        if CommandLine.arguments.contains("--self-test-fail") {
            require(false,"intentional failure validates the release test runner")
        }
        model.codexAuto=false;model.wander=false
        let oldSize=model.size,oldOrigin=app.pet.frame.origin
        for size in [280.0,440.0,700.0] {
            model.size=size
            require(abs(app.pet.frame.width-size)<1,"resize \(size)")
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
        recoveryPolicyChecks()
        Task{@MainActor in
            if CGPreflightScreenCaptureAccess(),let screen=app.pet.screen ?? NSScreen.main {
                let backdrop=launchBackdrop()
                defer {backdrop?.terminate()}
                try? await Task.sleep(nanoseconds:500_000_000)
                await app.capture.start(screen:screen)
                await waitForCapture(app,active:true)
                require(model.capturing && app.capture.stream != nil,"capture started")
                let old=app.capture.stream
                await app.capture.start(screen:nil)
                require(!model.capturing && app.capture.stream==nil && app.capture.latest()==nil,"capture pause")
                let first=Task{@MainActor in await app.capture.start(screen:screen)}
                let hide=Task{@MainActor in await app.capture.start(screen:nil)}
                let last=Task{@MainActor in await app.capture.start(screen:screen)}
                await first.value;await hide.value;await last.value
                await waitForCapture(app,active:true)
                require(model.capturing && app.capture.stream != nil,"latest capture request wins")
                if let old {
                    app.capture.stream(old,didStopWithError:NSError(domain:"stale-test",code:1))
                    try? await Task.sleep(nanoseconds:100_000_000)
                    require(model.capturing,"stale stream callback ignored")
                }
                for _ in 0..<50 {
                    if app.capture.latest() != nil {break}
                    try? await Task.sleep(nanoseconds:100_000_000)
                }
                require(app.capture.latest() != nil,"new stream delivers pixels")
                app.togglePet()
                require(!app.pet.isVisible,"hide entry point")
                await waitForCapture(app,active:false)
                app.togglePet()
                require(app.pet.isVisible,"show entry point")
                await waitForCapture(app,active:true)
                app.togglePet();app.togglePet();app.togglePet()
                await waitForCapture(app,active:false)
                app.togglePet()
                await waitForCapture(app,active:true)
                await recoveryChecks(app,screen:screen)
                log("CAPTURE_TEST_PASS pause rapid-reconnect stale-callback real-frames")
            } else {
                log("CAPTURE_TEST_SKIPPED screen permission unavailable")
            }
            log("SELF_TEST_PASS release-checks window renderer animation capture")
            if !CommandLine.arguments.contains("--self-test-stay") {NSApp.terminate(nil)}
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
            guard let active=capture.stream else {require(false,"fault injection requires active stream");return}
            capture.stream(active,didStopWithError:NSError(domain:SCStreamErrorDomain,code:code))
        }
        capturedRenderCheck(app.view)
        let before=capture.stream,oldFrame=capture.latest()
        interrupt(-3805)
        try? await Task.sleep(nanoseconds:200_000_000)
        require(!model.capturing && capture.retryPending,"active interruption schedules recovery")
        await waitForCapture(app,active:true)
        require(capture.stream !== before && capture.latest() !== oldFrame,"recovery replaces stream and frame")
        capturedRenderCheck(app.view)
        if ProcessInfo.processInfo.environment["SINGULARITY_CAPTURE_FIXTURE"] != nil {
            let wasPaused=model.paused
            model.paused=true
            let first=capturedRenderCheck(app.view)
            var refreshed=false
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds:100_000_000)
                if capturedRenderCheck(app.view) != first {refreshed=true;break}
            }
            model.paused=wasPaused
            require(refreshed,"recovered desktop texture continues updating while animation is paused")
            log("CAPTURE_REFRESH_TEST_PASS live-generated-backdrop after-recovery")
        }
        if let before {
            capture.stream(before,didStopWithError:NSError(domain:SCStreamErrorDomain,code:-3817))
            try? await Task.sleep(nanoseconds:100_000_000)
            require(model.capturing,"late user-stop from old stream cannot stop replacement")
        }
        interrupt(-3805)
        try? await Task.sleep(nanoseconds:100_000_000)
        require(capture.retryPending,"second interruption schedules recovery")
        app.togglePet()
        await waitForCapture(app,active:false)
        try? await Task.sleep(nanoseconds:2_200_000_000)
        require(!capture.wantsCapture && !capture.retryPending && capture.stream==nil,"hide cancels pending retry")
        app.togglePet()
        await waitForCapture(app,active:true)

        // Exercise the same entry points as workspace events without sleeping the user's Mac.
        await capture.suspend()
        require(!model.capturing && capture.stream==nil && capture.wantsCapture,"workspace suspension")
        await capture.suspend(.display)
        await capture.resume(screen:screen)
        require(capture.stream==nil,"overlapping suspension waits for all wake events")
        await capture.resume(.display,screen:screen)
        await waitForCapture(app,active:true)
        capturedRenderCheck(app.view)
        for code in [-3817,-3801,-3821] {
            interrupt(code)
            try? await Task.sleep(nanoseconds:1_200_000_000)
            require(!capture.wantsCapture && !capture.retryPending && capture.stream==nil,"terminal stop \(code)")
            await capture.suspend();await capture.resume(screen:screen)
            await capture.retarget(screen:screen)
            require(capture.stream==nil && !capture.wantsCapture,"lifecycle respects terminal stop")
            await capture.start(screen:screen,requestPermission:false)
            await waitForCapture(app,active:true)
        }
        log("CAPTURE_RECOVERY_TEST_PASS active-interruption fresh-texture cancelled-retry lifecycle terminal-stops")
    }

    static func launchBackdrop()->Process? {
        guard let path=ProcessInfo.processInfo.environment["SINGULARITY_CAPTURE_FIXTURE"] else{return nil}
        let process=Process()
        process.executableURL=URL(fileURLWithPath:path)
        do {try process.run();return process}
        catch {require(false,"capture backdrop launch: \(error)");return nil}
    }

    @discardableResult @MainActor static func capturedRenderCheck(_ view:PetView)->[UInt8] {
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
        func pixels(_ enabled:Bool)->[UInt8] {
            view.renderFrame(width:280,height:280,useCapture:enabled)
            var bytes=[UInt8](repeating:0,count:280*280*4)
            bytes.withUnsafeMutableBytes{glReadPixels(0,0,280,280,GLenum(GL_RGBA),GLenum(GL_UNSIGNED_BYTE),$0.baseAddress)}
            return bytes
        }
        let without=pixels(false)
        // Force an upload; the capture queue may deliver another frame during GPU readback.
        view.uploaded=nil
        let with=pixels(true)
        require(view.uploaded != nil,"real frame uploaded by renderer")
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

    @MainActor static func waitForCapture(_ app:AppDelegate,active:Bool) async {
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds:100_000_000)
            if !app.capture.busy && model.capturing==active {
                if active && app.capture.latest() != nil {return}
                if !active && app.capture.stream==nil {return}
            }
        }
        require(false,"visibility/capture reconciliation active=\(active): \(model.error)")
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
        func pixels(_ size:Int)->[UInt8] {
            glBindTexture(GLenum(GL_TEXTURE_2D),color)
            glTexImage2D(GLenum(GL_TEXTURE_2D),0,GL_RGBA8,GLsizei(size),GLsizei(size),0,GLenum(GL_RGBA),GLenum(GL_UNSIGNED_BYTE),nil)
            glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER),GLenum(GL_COLOR_ATTACHMENT0),GLenum(GL_TEXTURE_2D),color,0)
            glDrawBuffer(GLenum(GL_COLOR_ATTACHMENT0));glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
            require(glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))==GL_FRAMEBUFFER_COMPLETE,"framebuffer")
            view.renderFrame(width:GLsizei(size),height:GLsizei(size),useCapture:false)
            var bytes=[UInt8](repeating:0,count:size*size*4)
            bytes.withUnsafeMutableBytes{glReadPixels(0,0,GLsizei(size),GLsizei(size),GLenum(GL_RGBA),GLenum(GL_UNSIGNED_BYTE),$0.baseAddress)}
            require(glGetError()==GL_NO_ERROR,"GPU render/readback")
            return bytes
        }
        model.mass=1;model.brightness=2.2;model.tilt=1.2;model.roll=0.18
        model.kind=1;model.spin=0.7;model.customColor=false;model.paused=false
        var cases=0
        for size in [280,560] {
            for style in 0...3 {
                model.style=style
                for state in CodexActivityState.allCases {
                    model.setCodexState(state,source:"self-test")
                    model.codexPulse=(state == .complete || state == .error) ? 1:0
                    view.codexEnergySmooth=state.energy;view.codexTrailSmooth=state.trail
                    view.codexParticlesSmooth=state.particleDensity
                    view.clock=2;view.diskPhase=3;view.dustPhase=1
                    let image=pixels(size)
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
}
