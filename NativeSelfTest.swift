import Cocoa
import OpenGL.GL3

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
        Task{@MainActor in
            if CGPreflightScreenCaptureAccess(),let screen=app.pet.screen ?? NSScreen.main {
                await app.capture.start(screen:screen)
                require(model.capturing && app.capture.stream != nil,"capture started")
                let old=app.capture.stream
                await app.capture.start(screen:nil)
                require(!model.capturing && app.capture.stream==nil && app.capture.latest()==nil,"capture pause")
                let first=Task{@MainActor in await app.capture.start(screen:screen)}
                let hide=Task{@MainActor in await app.capture.start(screen:nil)}
                let last=Task{@MainActor in await app.capture.start(screen:screen)}
                await first.value;await hide.value;await last.value
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
                log("CAPTURE_TEST_PASS pause rapid-reconnect stale-callback real-frames")
            } else {
                log("CAPTURE_TEST_SKIPPED screen permission unavailable")
            }
            log("SELF_TEST_PASS release-checks window renderer animation capture")
            if !CommandLine.arguments.contains("--self-test-stay") {NSApp.terminate(nil)}
        }
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
                    let lit=stride(from:0,to:image.count,by:4).filter{max(image[$0],max(image[$0+1],image[$0+2]))>25}.count
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
