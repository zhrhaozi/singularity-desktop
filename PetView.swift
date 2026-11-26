import Cocoa
import OpenGL.GL3
import CoreMedia

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
        var stackedMode:GLint = -1
        var stackedScene:GLint = -1
        var bodySceneRect:GLint = -1
        var viewportOrigin:GLint = -1
        var encounterStrength:GLint = -1
        var collisionStrength:GLint = -1
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
    let multiLens = MultiLensRenderer()
    private(set) var orbits:OrbitalSystem?
    var orbitalBodies:[OrbitalBody] { orbits?.bodies ?? [] }
    func resetOrbits() {
        orbits = model.bodyCount > 1 ? OrbitalSystem(count:model.bodyCount) : nil
        orbits?.driftEnabled=model.systemDrift
        if program != 0 {
            openGLContext?.makeCurrentContext()
            geometryCache?.release()
            multiLens.release()
        }
        needsDisplay=true
    }
    private(set) var renderingActive=true
    private let geometryCachingEnabled=ProcessInfo.processInfo.environment["SINGULARITY_DISABLE_GEOMETRY_CACHE"] != "1"
    #if SELF_TEST
    var benchmarkDirectGeometry = false
    #else
    private let benchmarkDirectGeometry = false
    #endif
    private var renderedWindowFrame=CGRect.zero
    private var requestedCaptureFrame=CGRect.zero
    private var renderedCapture=false
    private var uniforms=UniformLocations()
    var dragStart=NSPoint.zero, originStart=NSPoint.zero
    var dragging=false
    var wanderState=Wander()
    var lastTick=ProcessInfo.processInfo.systemUptime
    var lastSave=ProcessInfo.processInfo.systemUptime
    let capture: Capture
    private let model: Model
    private let preview: Bool
    init?(frame: NSRect, capture: Capture, state: Model, preview: Bool = false) {
        self.capture = capture; self.model = state; self.preview = preview
        let attrs:[NSOpenGLPixelFormatAttribute]=[UInt32(NSOpenGLPFAOpenGLProfile),UInt32(NSOpenGLProfileVersion3_2Core),UInt32(NSOpenGLPFAAccelerated),UInt32(NSOpenGLPFADoubleBuffer),UInt32(NSOpenGLPFAColorSize),24,UInt32(NSOpenGLPFAAlphaSize),8,0]
        guard let format = NSOpenGLPixelFormat(attributes: attrs) ?? NSOpenGLPixelFormat(attributes: attrs.filter { $0 != UInt32(NSOpenGLPFAAccelerated) }) else { return nil }
        super.init(frame: frame, pixelFormat: format)
        setAccessibilityLabel("奇点黑洞桌宠")
        wantsBestResolutionOpenGLSurface=true
    }
    required init?(coder:NSCoder) { return nil }
    override var isOpaque:Bool {false}
    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func prepareOpenGL() {
        super.prepareOpenGL();openGLContext?.makeCurrentContext()
        if program != 0 { return }
        if model.bodyCount > 1 {resetOrbits()}
        var opaque:GLint=0;openGLContext?.setValues(&opaque,for:.surfaceOpacity)
        var swap:GLint=1;openGLContext?.setValues(&swap,for:.swapInterval)
        do {
            let vertex = try GLProgram.source("blackhole", "vert")
            let source = try GLProgram.source("blackhole", "frag")
            program = try GLProgram.build(vertex: vertex, fragment: source)
            log("GL_LINK 1")
            do {
                let cached = source.replacingOccurrences(of: "#version 150", with: "#version 150\n#define GEOMETRY_PASS")
                let id = try GLProgram.build(vertex: vertex, fragment: cached,
                                             outputs: ["geometryBackground", "geometryCrossing0", "geometryCrossing1"])
                geometryCache = LensGeometryCache(program: id)
            } catch { log("GEOMETRY_CACHE_UNAVAILABLE \(error)") } // Direct rendering remains usable.
        } catch {
            program = 0
            timer?.invalidate(); timer = nil
            log("GL_INIT_FAILED \(error)")
            guard !preview else { return }
            model.rendererError = "图形渲染未能启动。请重新打开奇点；如果仍然失败，请使用完整的应用包重新安装。"
            Task { @MainActor in await capture.start(screen: nil) }
            return
        }
        glGenVertexArrays(1,&vao);glBindVertexArray(vao)
        cacheUniformLocations()
        if !preview,let context=openGLContext?.cglContextObj,let format=pixelFormat?.cglPixelFormatObj {
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
        if !preview { setRenderingActive(renderingActive) }
    }
    func disposePreview() {
        guard preview else { return }
        geometryCache?.release()
        if let id = geometryCache?.program, id != 0 { glDeleteProgram(id) }
        geometryCache = nil; multiLens.dispose()
        if program != 0 { glDeleteProgram(program); program = 0 }
        glDeleteTextures(1, &textureID); glDeleteTextures(1, &emptySurfaceTexture)
        glDeleteVertexArrays(1, &vao)
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
            multiLens.release()
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
        uniforms.stackedMode=glGetUniformLocation(program,"stackedMode")
        uniforms.stackedScene=glGetUniformLocation(program,"stackedScene")
        uniforms.bodySceneRect=glGetUniformLocation(program,"bodySceneRect")
        uniforms.viewportOrigin=glGetUniformLocation(program,"viewportOrigin")
        uniforms.encounterStrength=glGetUniformLocation(program,"encounterStrength")
        uniforms.collisionStrength=glGetUniformLocation(program,"collisionStrength")
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
        clock += Float(model.effectiveFlowSpeed*dt)
        let spinDirection=(model.hasSpin && model.spin < 0) ? -1.0 : 1.0
        // Keep the old visual rates (the shader's disk wind was 5 rad/s at 1x)
        // while integrating state-dependent terms here, where they cannot jump
        // by multiplying a long-lived clock with a newly observed state.
        diskPhase += Float(model.effectiveFlowSpeed*dt*5.0*(1.0+0.34*Double(codexEnergySmooth))*spinDirection)
        dustPhase += Float(model.effectiveFlowSpeed*dt*(0.18+0.88*Double(codexEnergySmooth)))
        if !preview && model.codexPulse > 0 { model.codexPulse=max(0,model.codexPulse-dt*2.2) }
    }
    func tick() {
        let now=ProcessInfo.processInfo.systemUptime
        let dt=min(0.1,max(0,now-lastTick));lastTick=now
        guard let w=window,w.isVisible else{return}
        advanceAnimation(dt:dt)
        let mouse=NSEvent.mouseLocation
        let pointer=w.convertPoint(fromScreen:mouse)
        let hovering = !RunMode.performance && hitsBody(pointer,margin:0.29)
        if model.bodyCount > 1 && !model.paused && !dragging && !hovering {
            orbits?.advance(dt:dt,speed:model.orbitSpeed)
        }
        if model.effectiveWander && !model.paused && !dragging && !hovering && !(appDelegate?.settings?.isVisible ?? false),let screen=w.screen {
            w.setFrameOrigin(wanderState.advance(origin:w.frame.origin,size:w.frame.size,screen:screen.visibleFrame,speed:model.travelSpeed,dt:dt))
            if now-lastSave>5 {appDelegate?.savePosition();lastSave=now}
        }
        if !dragging && !RunMode.selfTest {
            let point=convert(pointer,from:nil)
            let ignores = !hitsBody(point,margin:0.27)
            if w.ignoresMouseEvents != ignores { w.ignoresMouseEvents = ignores; w.invalidateCursorRects(for: self) }
        }
        if w.frame != requestedCaptureFrame {
            requestedCaptureFrame=w.frame
            appDelegate?.checkScreen()
        }
        if !model.paused || needsDisplay || capture.latest() !== uploaded ||
            w.frame != renderedWindowFrame || model.capturing != renderedCapture {needsDisplay=true}
    }
    func hitsBody(_ point:CGPoint,margin:Double)->Bool {
        guard model.bodyCount > 1 else {return hypot(point.x-bounds.midX,point.y-bounds.midY)<bounds.width*margin}
        return orbitalBodies.contains {
            let r=MultiLensRenderer.rect(for:$0)
            let center=CGPoint(x:r.midX*bounds.width,y:(1-r.midY)*bounds.height)
            return hypot(point.x-center.x,point.y-center.y)<r.width*bounds.width*margin
        }
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
    func renderFrame(width:GLsizei,height:GLsizei,useCapture:Bool,captureBuffer:CVPixelBuffer?=nil,captureSourceRect:CGRect?=nil,forceCPUUpload:Bool=false,forceUncachedGeometry:Bool=false,bodyPass:LensBodyPass?=nil) {
        glBindVertexArray(vao)
        let snapshot=useCapture && captureBuffer==nil ? capture.latestSnapshot():nil
        let sourceRect=captureSourceRect ?? snapshot?.rect ?? capture.screenRect
        let frame=captureBuffer ?? snapshot?.buffer
        if bodyPass==nil {
            if useCapture,let buffer=frame {bindDesktop(buffer,forceCPUUpload:forceCPUUpload)}
            else {
                uploaded=nil;desktopSurface=nil;usingDesktopSurface=false
                if let cache=desktopCache {CVOpenGLTextureCacheFlush(cache,0)}
            }
        }
        var normalizedRect=CGRect(x:0,y:0,width:1,height:1)
        if let w=window,sourceRect.width>0 {
            normalizedRect=CGRect(x:(w.frame.minX-sourceRect.minX)/sourceRect.width,
                                  y:(sourceRect.maxY-w.frame.maxY)/sourceRect.height,
                                  width:w.frame.width/sourceRect.width,height:w.frame.height/sourceRect.height)
        }
        if model.bodyCount > 1,bodyPass==nil,let geometry=geometryCache {
            if orbits==nil {orbits=OrbitalSystem(count:model.bodyCount);orbits?.driftEnabled=model.systemDrift}
            let desktop=LensDesktop(texture:textureID,surface:desktopSurface.map{CVOpenGLTextureGetName($0)} ?? emptySurfaceTexture,
                                    usesSurface:usingDesktopSurface,available:useCapture && uploaded != nil && model.capturing,rect:normalizedRect)
            if multiLens.render(width:width,height:height,geometryProgram:geometry.program,bodies:orbitalBodies,desktop:desktop,drawBody:{pass in
                self.renderFrame(width:GLsizei(pass.viewport.width),height:GLsizei(pass.viewport.height),useCapture:useCapture,
                                 captureBuffer:frame,captureSourceRect:sourceRect,forceCPUUpload:forceCPUUpload,
                                 forceUncachedGeometry:forceUncachedGeometry,bodyPass:pass)
            }) {return}
        }
        let roll = Float(model.roll) + (bodyPass.map{Float($0.index)*0.54-0.22} ?? 0)
        let inclination = Float(model.tilt)
        let mass = Float(model.mass) * (bodyPass.map{$0.index==1 ? Float(0.87):Float(1)} ?? 1)
        let values:[(String,Float)]=[
            ("LENS_DEPTH",Float(model.lens)),("inclination",inclination),
            ("rollAngle",roll),("spin",Float(model.hasSpin ? model.spin:0)),
            ("charge",Float(model.effectiveCharge)),("massScale",mass)]
        let cache = bodyPass?.geometry ?? geometryCache
        glDisable(GLenum(GL_BLEND))
        let cached = geometryCachingEnabled && !forceUncachedGeometry && !benchmarkDirectGeometry && (cache?.prepare(width:width,height:height,signature:values.map(\.1)+[Float(model.style)]) {p in
            for (name,value) in values {self.set1f(glGetUniformLocation(p,name),value)}
            self.set2f(glGetUniformLocation(p,"iResolution"),Float(width),Float(height))
            self.set2f(glGetUniformLocation(p,"viewportOrigin"),0,0)
            self.set1i(glGetUniformLocation(p,"style"),GLint(model.style))
        } ?? false)
        cache?.bind()
        if let pass=bodyPass {
            glViewport(GLint(pass.viewport.minX),GLint(pass.viewport.minY),width,height)
            glEnable(GLenum(GL_BLEND));glBlendFunc(GLenum(GL_ONE),GLenum(GL_ONE_MINUS_SRC_ALPHA))
        } else {glViewport(0,0,width,height);glClearColor(0,0,0,0);glClear(GLbitfield(GL_COLOR_BUFFER_BIT))}
        glUseProgram(program);glBindVertexArray(vao);glActiveTexture(GLenum(GL_TEXTURE0));glBindTexture(GLenum(GL_TEXTURE_2D),textureID)
        set1i(uniforms.useGeometryCache,cached ? 1:0)
        set1i(uniforms.stackedMode,bodyPass==nil ? 0:(multiLens.stacksLensing ? 1:2))
        set1i(uniforms.stackedScene,5)
        set2f(uniforms.viewportOrigin,Float(bodyPass?.viewport.minX ?? 0),Float(bodyPass?.viewport.minY ?? 0))
        let rect=bodyPass?.sceneRect ?? CGRect(x:0,y:0,width:1,height:1)
        set4f(uniforms.bodySceneRect,Float(rect.minX),Float(rect.minY),Float(rect.width),Float(rect.height))
        set1f(uniforms.encounterStrength,bodyPass?.encounter ?? 0)
        set1f(uniforms.collisionStrength,bodyPass?.impact ?? 0)
        glActiveTexture(GLenum(GL_TEXTURE5));glBindTexture(GLenum(GL_TEXTURE_2D),bodyPass?.sceneTexture ?? textureID)
        glActiveTexture(GLenum(GL_TEXTURE0));glBindTexture(GLenum(GL_TEXTURE_2D),textureID)
        glActiveTexture(GLenum(GL_TEXTURE1))
        glBindTexture(GLenum(GL_TEXTURE_RECTANGLE),desktopSurface.map{CVOpenGLTextureGetName($0)} ?? emptySurfaceTexture)
        glActiveTexture(GLenum(GL_TEXTURE0))
        set1i(uniforms.desktopSurface,1);set1i(uniforms.useDesktopSurface,usingDesktopSurface ? 1:0)
        set1i(uniforms.desktop,0);set2f(uniforms.iResolution,Float(width),Float(height))
        set1f(uniforms.iTime,clock);set1f(uniforms.lensDepth,Float(model.lens));set1f(uniforms.temperature,model.style == 1 ? 15000:5500);set1f(uniforms.inclination,inclination);set1f(uniforms.rollAngle,roll);set1f(uniforms.brightness,Float(model.brightness))
        set1f(uniforms.spin,Float(model.hasSpin ? model.spin:0));set1f(uniforms.charge,Float(model.effectiveCharge));set1f(uniforms.massScale,mass)
        set1f(uniforms.codexEnergy,model.codexState.energy);set1f(uniforms.codexTrail,model.codexState.trail);set1f(uniforms.codexParticles,model.codexState.particleDensity);set1f(uniforms.codexPulse,Float(model.codexPulse));set1i(uniforms.codexState,GLint(model.codexState.rawValue))
        let bodyPhase=bodyPass.map{diskPhase*($0.index==1 ? -0.85:1.0)+Float($0.index)*2.1} ?? diskPhase
        set1f(uniforms.codexEnergySmooth,codexEnergySmooth);set1f(uniforms.codexTrailSmooth,codexTrailSmooth);set1f(uniforms.codexParticlesSmooth,codexParticlesSmooth);set1f(uniforms.diskPhase,bodyPhase);set1f(uniforms.dustPhase,dustPhase)
        let rgb = model.customRGB
        set3f(uniforms.customRGB,Float(rgb.r),Float(rgb.g),Float(rgb.b))
        set1i(uniforms.useCustomColor,model.customColor ? 1:0)
        set1i(uniforms.style,GLint(model.style));set1i(uniforms.hasCapture,useCapture && uploaded != nil && model.capturing ? 1:0)
        if let w=window,sourceRect.width>0 {let s=sourceRect;set4f(uniforms.captureRect,Float((w.frame.minX-s.minX)/s.width),Float((s.maxY-w.frame.maxY)/s.height),Float(w.frame.width/s.width),Float(w.frame.height/s.height))}
        glDrawArrays(GLenum(GL_TRIANGLES),0,3)
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties();openGLContext?.update();needsDisplay=true
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard window?.ignoresMouseEvents == false else { return }
        addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { appDelegate?.showSettings(); return }
        guard let window else { return }
        dragging = true; dragStart = NSEvent.mouseLocation; originStart = window.frame.origin
        NSCursor.closedHand.set(); window.invalidateCursorRects(for: self)
        appDelegate?.checkScreen()
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let p = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(x: originStart.x + p.x - dragStart.x, y: originStart.y + p.y - dragStart.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        if hitsBody(convert(event.locationInWindow, from: nil), margin: 0.27) { NSCursor.openHand.set() }
        window?.invalidateCursorRects(for: self)
        appDelegate?.savePosition(); appDelegate?.screenParametersChanged()
    }
    override func rightMouseDown(with event:NSEvent) {if let menu=appDelegate?.makeMenu(){NSMenu.popUpContextMenu(menu,with:event,for:self)}}
}
