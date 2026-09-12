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
    @Published var codexState: CodexActivityState = .idle
    @Published var codexSource = "等待 Codex 桌面状态"
    @Published var codexDetail = ""
    @Published var codexPulse: Double = 0
    var hasSpin:Bool {kind==1 || kind==3}
    var hasCharge:Bool {kind==2 || kind==3}
    var effectiveCharge:Double {hasCharge ? min(charge,sqrt(max(0,0.98*0.98-pow(hasSpin ? spin:0,2)))):0}
    @Published var paused = false
    @Published var visible = true
    @Published var captureState = "尚未开启桌面透镜"
    @Published var capturing = false
    @Published var error = ""
    func save() { let d=UserDefaults.standard; d.set(size,forKey:"size");d.set(lens,forKey:"lens");d.set(speed,forKey:"speed");d.set(brightness,forKey:"brightness");d.set(tilt,forKey:"tilt");d.set(roll,forKey:"roll");d.set(style,forKey:"style");d.set(kind,forKey:"kind");d.set(spin,forKey:"spin");d.set(charge,forKey:"charge");d.set(mass,forKey:"mass");d.set(wander,forKey:"wander");d.set(travelSpeed,forKey:"travelSpeed");d.set(customColor,forKey:"customColor");d.set(colorHex,forKey:"colorHex");d.set(codexAuto,forKey:"codexAuto") }
    func setCodexState(_ next:CodexActivityState,_ source:String,_ detail:String="") {
        let changed = codexState != next
        codexState = next
        codexSource = source
        codexDetail = detail
        if changed && (next == .complete || next == .error) { codexPulse = 1.0 }
    }
    func setCodexState(_ next:CodexActivityState, source:String, detail:String="") { setCodexState(next, source, detail) }
    func reset() { size=440;lens=13;speed=0.6;brightness=2.2;tilt=1.48;roll=0.18;style=0;kind=0;spin=0.7;charge=0.5;mass=1;wander=false;travelSpeed=35;customColor=false;colorHex="#FFAA55";codexAuto=true;setCodexState(.idle, source:"等待 Codex 桌面状态");appDelegate?.centerPet() }
}
let model=Model()
var appDelegate: AppDelegate?
func log(_ message:String) { NSLog("[Singularity] %@",message) }

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    let lock=NSLock()
    var frame: CVPixelBuffer?
    var screenRect=CGRect.zero
    var displayID: CGDirectDisplayID=0
    var busy=false
    @MainActor func start(screen:NSScreen) async {
        guard !busy else {return};busy=true;defer{busy=false}
        do {
            if !CGPreflightScreenCaptureAccess() {
                log("PERMISSION_REQUEST bundle=\(Bundle.main.bundleIdentifier ?? "unknown") path=\(Bundle.main.bundlePath)")
                guard CGRequestScreenCaptureAccess() else {
                    model.capturing=false
                    model.captureState="等待系统授权"
                    model.error="请在 macOS 弹窗中打开系统设置，并允许「奇点」。若列表里没有它，点击列表左下角 ＋，选择当前应用；授权后退出并重新打开奇点。"
                    return
                }
            }
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
            let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            guard let display=content.displays.first(where:{$0.displayID==id}) else {throw NSError(domain:"Display unavailable",code:1)}
            if let old=stream {try? await old.stopCapture()}; stream=nil
            let own=content.windows.filter{$0.windowID == CGWindowID(appDelegate?.pet.windowNumber ?? 0)}
            let filter=SCContentFilter(display:display,excludingWindows:own)
            let config=SCStreamConfiguration()
            config.width=display.width;config.height=display.height
            config.pixelFormat=kCVPixelFormatType_32BGRA
            config.minimumFrameInterval=CMTime(value:1,timescale:30)
            config.queueDepth=3;config.showsCursor=false;config.capturesAudio=false
            let next=SCStream(filter:filter,configuration:config,delegate:self)
            try next.addStreamOutput(self,type:.screen,sampleHandlerQueue:DispatchQueue(label:"singularity.capture"))
            lock.lock();frame=nil;lock.unlock()
            screenRect=screen.frame;displayID=id;stream=next
            try await next.startCapture()
            model.captureState="桌面透镜已连接";model.capturing=true;model.error=""
            log("CAPTURE_STARTED display=\(id) excluded=\(own.count)")
        } catch {
            model.capturing=false;model.captureState="需要屏幕录制权限"
            model.error="请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许「奇点」，然后点击重连。\n\(error.localizedDescription)"
            log("CAPTURE_ERROR \(error)")
        }
    }
    func stream(_ stream:SCStream,didOutputSampleBuffer buffer:CMSampleBuffer,of type:SCStreamOutputType) {
        guard type == .screen,buffer.isValid, let image=CMSampleBufferGetImageBuffer(buffer) else{return}
        guard let attachments=CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],let raw=attachments.first?[.status] as? Int,raw==SCFrameStatus.complete.rawValue else{return}
        lock.lock();frame=image;lock.unlock()
    }
    func stream(_ stream:SCStream,didStopWithError error:Error) { DispatchQueue.main.async {model.capturing=false;model.captureState="桌面连接已中断，请重连";log("STREAM_STOP \(error)")} }
    func latest()->CVPixelBuffer? {lock.lock();defer{lock.unlock()};return frame}
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
        let vertex=compile(GLenum(GL_VERTEX_SHADER),"#version 150\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.0-1.0,0,1);}")
        let fragment=compile(GLenum(GL_FRAGMENT_SHADER),try! String(contentsOf:Bundle.main.url(forResource:"blackhole",withExtension:"frag")!,encoding:.utf8))
        program=glCreateProgram();glAttachShader(program,vertex);glAttachShader(program,fragment);glLinkProgram(program)
        var ok:GLint=0;glGetProgramiv(program,GLenum(GL_LINK_STATUS),&ok);log("GL_LINK \(ok)")
        glDeleteShader(vertex);glDeleteShader(fragment);glGenVertexArrays(1,&vao);glBindVertexArray(vao)
        cacheUniformLocations()
        glGenTextures(1,&textureID);glBindTexture(GLenum(GL_TEXTURE_2D),textureID)
        glTexParameteri(GLenum(GL_TEXTURE_2D),GLenum(GL_TEXTURE_MIN_FILTER),GL_LINEAR);glTexParameteri(GLenum(GL_TEXTURE_2D),GLenum(GL_TEXTURE_MAG_FILTER),GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D),GLenum(GL_TEXTURE_WRAP_S),GL_CLAMP_TO_EDGE);glTexParameteri(GLenum(GL_TEXTURE_2D),GLenum(GL_TEXTURE_WRAP_T),GL_CLAMP_TO_EDGE)
        let pixels:[UInt8]=[0,0,0,255];pixels.withUnsafeBytes{glTexImage2D(GLenum(GL_TEXTURE_2D),0,GL_RGBA8,1,1,0,GLenum(GL_BGRA),GLenum(GL_UNSIGNED_BYTE),$0.baseAddress)}
        timer=Timer(timeInterval:1.0/30,repeats:true){[weak self] _ in self?.tick()};RunLoop.main.add(timer!,forMode:.common)
    }
    private func cacheUniformLocations() {
        uniforms.desktop=glGetUniformLocation(program,"desktop")
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
    }
    @inline(__always) private func set1f(_ location:GLint,_ value:Float) { if location >= 0 { glUniform1f(location,value) } }
    @inline(__always) private func set1i(_ location:GLint,_ value:GLint) { if location >= 0 { glUniform1i(location,value) } }
    @inline(__always) private func set2f(_ location:GLint,_ x:Float,_ y:Float) { if location >= 0 { glUniform2f(location,x,y) } }
    @inline(__always) private func set3f(_ location:GLint,_ x:Float,_ y:Float,_ z:Float) { if location >= 0 { glUniform3f(location,x,y,z) } }
    @inline(__always) private func set4f(_ location:GLint,_ x:Float,_ y:Float,_ z:Float,_ w:Float) { if location >= 0 { glUniform4f(location,x,y,z,w) } }
    private func advanceAnimation(dt:Double) {
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
        let pointer=w.convertPoint(fromScreen:NSEvent.mouseLocation)
        let hovering=hypot(pointer.x-bounds.midX,pointer.y-bounds.midY)<bounds.width*0.29
        if model.wander && !dragging && !hovering && !(appDelegate?.settings?.isVisible ?? false),let screen=w.screen {
            w.setFrameOrigin(wanderState.advance(origin:w.frame.origin,size:w.frame.size,screen:screen.visibleFrame,speed:model.travelSpeed,dt:dt))
            if now-lastSave>5 {appDelegate?.savePosition();lastSave=now}
        }
        if !dragging && !CommandLine.arguments.contains("--self-test") {let point=convert(w.convertPoint(fromScreen:NSEvent.mouseLocation),from:nil);let d=hypot(point.x-bounds.midX,point.y-bounds.midY);w.ignoresMouseEvents = d > bounds.width*0.27}
        needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect) {
        guard program != 0 else{return};openGLContext?.makeCurrentContext()
        let backing=convertToBacking(bounds)
        let width=GLsizei(max(1,Int(backing.width.rounded(.up)))),height=GLsizei(max(1,Int(backing.height.rounded(.up))))
        glViewport(0,0,width,height);glClearColor(0,0,0,0);glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        glUseProgram(program);glBindVertexArray(vao);glActiveTexture(GLenum(GL_TEXTURE0));glBindTexture(GLenum(GL_TEXTURE_2D),textureID)
        if let buffer=capture.latest(),uploaded !== buffer {
            let lockResult=CVPixelBufferLockBaseAddress(buffer,.readOnly)
            if lockResult == kCVReturnSuccess {
                var didUpload=false
                if let base=CVPixelBufferGetBaseAddress(buffer) {
                    let bufferWidth=GLsizei(CVPixelBufferGetWidth(buffer)),bufferHeight=GLsizei(CVPixelBufferGetHeight(buffer))
                    glPixelStorei(GLenum(GL_UNPACK_ROW_LENGTH),GLint(CVPixelBufferGetBytesPerRow(buffer)/4))
                    if textureWidth != bufferWidth || textureHeight != bufferHeight {
                        glTexImage2D(GLenum(GL_TEXTURE_2D),0,GL_RGBA8,bufferWidth,bufferHeight,0,GLenum(GL_BGRA),GLenum(GL_UNSIGNED_BYTE),nil)
                        textureWidth=bufferWidth;textureHeight=bufferHeight
                    }
                    glTexSubImage2D(GLenum(GL_TEXTURE_2D),0,0,0,bufferWidth,bufferHeight,GLenum(GL_BGRA),GLenum(GL_UNSIGNED_BYTE),base)
                    glPixelStorei(GLenum(GL_UNPACK_ROW_LENGTH),0)
                    didUpload=true
                }
                CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
                if didUpload { uploaded=buffer }
            }
        }
        set1i(uniforms.desktop,0);set2f(uniforms.iResolution,Float(width),Float(height))
        set1f(uniforms.iTime,clock);set1f(uniforms.lensDepth,Float(model.lens));set1f(uniforms.temperature,model.style == 1 ? 15000:5500);set1f(uniforms.inclination,Float(model.tilt));set1f(uniforms.rollAngle,Float(model.roll));set1f(uniforms.brightness,Float(model.brightness))
        set1f(uniforms.spin,Float(model.hasSpin ? model.spin:0));set1f(uniforms.charge,Float(model.effectiveCharge));set1f(uniforms.massScale,Float(model.mass))
        set1f(uniforms.codexEnergy,model.codexState.energy);set1f(uniforms.codexTrail,model.codexState.trail);set1f(uniforms.codexParticles,model.codexState.particleDensity);set1f(uniforms.codexPulse,Float(model.codexPulse));set1i(uniforms.codexState,GLint(model.codexState.rawValue))
        set1f(uniforms.codexEnergySmooth,codexEnergySmooth);set1f(uniforms.codexTrailSmooth,codexTrailSmooth);set1f(uniforms.codexParticlesSmooth,codexParticlesSmooth);set1f(uniforms.diskPhase,diskPhase);set1f(uniforms.dustPhase,dustPhase)
        let rgb=RGB(hex:model.colorHex) ?? RGB(hex:"#FFAA55")!
        set3f(uniforms.customRGB,Float(rgb.r),Float(rgb.g),Float(rgb.b))
        set1i(uniforms.useCustomColor,model.customColor ? 1:0)
        set1i(uniforms.style,GLint(model.style));set1i(uniforms.hasCapture,uploaded != nil && model.capturing ? 1:0)
        if let w=window,capture.screenRect.width>0 {let s=capture.screenRect;set4f(uniforms.captureRect,Float((w.frame.minX-s.minX)/s.width),Float((s.maxY-w.frame.maxY)/s.height),Float(w.frame.width/s.width),Float(w.frame.height/s.height))}
        glDrawArrays(GLenum(GL_TRIANGLES),0,3);openGLContext?.flushBuffer()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties();openGLContext?.update();needsDisplay=true
    }
    override func mouseDown(with event:NSEvent) {
        if event.clickCount==2 {appDelegate?.showSettings();return}
        log("DRAG_BEGIN");dragging=true;dragStart=NSEvent.mouseLocation;originStart=window!.frame.origin
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
            VStack(alignment:.leading,spacing:10){HStack{Circle().fill(state.capturing ? Color.green:accent).frame(width:6,height:6);Text(state.captureState).font(.system(size:12));Spacer();Button(state.capturing ? "重连":"开启桌面透镜"){appDelegate?.enableCapture()}.controlSize(.small)};if !state.error.isEmpty {Text(state.error).font(.system(size:11)).foregroundStyle(accent).fixedSize(horizontal:false,vertical:true)};if !state.capturing {HStack {
                    Button("打开屏幕录制设置"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)}
                    Button("在访达中显示当前应用"){NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])}
                }.font(.system(size:11))}}.padding(14).background(Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:10))
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
            HStack{Text("拖动黑洞移动 · 双击或右键打开设置").font(.system(size:11)).foregroundStyle(.secondary);Spacer();Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.3")").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)}
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
        codexBridge=CodexStateBridge(model:model)
        codexBridge?.start()
        if CGPreflightScreenCaptureAccess(){
            enableCapture()
        } else {
            model.captureState="需要屏幕录制权限"
            model.error="真实桌面扭曲需要屏幕录制权限。请点击「开启桌面透镜」，或在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许「奇点」。"
        }
        NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in self?.screenParametersChanged()}
        log("APP_READY")
        if CommandLine.arguments.contains("--self-test") {runSelfTest()}
    }
    func makeMenu()->NSMenu {let m=NSMenu();m.addItem(withTitle:"黑洞设置…",action:#selector(showSettings),keyEquivalent:",");m.addItem(withTitle:"显示 / 隐藏宠物",action:#selector(togglePet),keyEquivalent:"");m.addItem(withTitle:"将黑洞移回屏幕中央",action:#selector(centerPet),keyEquivalent:"");m.addItem(.separator());m.addItem(withTitle:"退出奇点",action:#selector(quit),keyEquivalent:"q");for i in m.items{i.target=self};return m}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {showSettings();return true}
    @objc func showSettings(){settings?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    @objc func about(){NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"奇点 · Singularity",.applicationVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.2.3",.credits:NSAttributedString(string:"引力透镜着色器基于 s0xDk/ghostty-blackhole（MIT）。")])}
    func applicationWillTerminate(_ notification:Notification){savePosition()}
    @objc func quit(){savePosition();NSApp.terminate(nil)}
    @objc func togglePet(){model.visible.toggle();if model.visible{pet.orderFrontRegardless();if capture.stream != nil {enableCapture()}}else{pet.orderOut(nil);if let stream=capture.stream {Task{try? await stream.stopCapture()}}}}
    @objc func centerPet(){guard pet != nil,let s=NSScreen.main else{return};pet.setFrameOrigin(NSPoint(x:s.visibleFrame.midX-pet.frame.width/2,y:s.visibleFrame.midY-pet.frame.height/2));savePosition()}
    func resizePet(){guard pet != nil else{return};let center=NSPoint(x:pet.frame.midX,y:pet.frame.midY);pet.setFrame(NSRect(x:center.x-model.size/2,y:center.y-model.size/2,width:model.size,height:model.size),display:true);savePosition()}
    func savePosition(){guard pet != nil else{return};UserDefaults.standard.set(pet.frame.minX,forKey:"x");UserDefaults.standard.set(pet.frame.minY,forKey:"y")}
    var petScreens:[PetScreen] {NSScreen.screens.map{PetScreen(frame:$0.frame,visibleFrame:$0.visibleFrame)}}
    func screenParametersChanged(){
        guard pet != nil else{return}
        if !view.dragging {
            let origin=PetPlacement.recoveredOrigin(for:pet.frame,screens:petScreens)
            if origin != pet.frame.origin {pet.setFrameOrigin(origin);savePosition()}
        }
        checkScreen()
    }
    func enableCapture(){guard let screen=pet.screen ?? NSScreen.main else{return};model.captureState="正在连接桌面…";Task{@MainActor in await capture.start(screen:screen)}}
    func restartCodexBridge(){codexBridge?.restartIfNeeded()}
    func checkScreen(){guard model.capturing,let s=pet.screen else{return};let id=(s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0;if id != capture.displayID || s.frame != capture.screenRect {enableCapture()}}
    func runSelfTest(){DispatchQueue.main.asyncAfter(deadline:.now()+2){
        let old=model.size;model.size=360;assert(abs(self.pet.frame.width-360)<1);model.size=old
        let origin=self.pet.frame.origin;self.pet.setFrameOrigin(NSPoint(x:origin.x+30,y:origin.y+20));assert(abs(self.pet.frame.minX-origin.x-30)<1);self.pet.setFrameOrigin(origin)
        self.pet.orderOut(nil);assert(!self.pet.isVisible);self.pet.orderFrontRegardless();assert(self.pet.isVisible)
        assert(self.view.program != 0);log("SELF_TEST_PASS resize position visibility renderer")
    }}
}
let app=NSApplication.shared
let delegate=AppDelegate();appDelegate=delegate
app.setActivationPolicy(.regular);app.delegate=delegate;app.run()
