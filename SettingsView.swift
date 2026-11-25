import Cocoa
import SwiftUI

struct SettingsView:View {
    @ObservedObject var state:Model
    @State private var hexInput=""
    @State private var colorError=""
    @State private var confirmDesktop = false
    var chosenColor:Binding<Color> {Binding(get:{let c=state.customRGB;return Color(.sRGB,red:c.r,green:c.g,blue:c.b)},set:{c in
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
            VStack(alignment:.leading,spacing:10){HStack{Circle().fill(state.capturing ? Color.green:accent).frame(width:6,height:6);Text(state.captureState).font(.system(size:12));Spacer();Button(state.capturing ? "重连":"开启桌面透镜"){appDelegate?.enableCapture(retryPreferredBackend:true)}.controlSize(.small).disabled(!state.visible)};if !state.error.isEmpty {Text(state.error).font(.system(size:11)).foregroundStyle(accent).fixedSize(horizontal:false,vertical:true)};if !state.capturing && state.visible {HStack {
                    Button("打开屏幕录制设置"){NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)}
                    Button("在访达中显示当前应用"){NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])}
                }.font(.system(size:11))}}.padding(14).background(Color.white.opacity(0.045),in:RoundedRectangle(cornerRadius:10))
            Picker("桌面背景刷新",selection:$state.backgroundFPS) {
                Text("自动 · 2–10 FPS").tag(10)
                Text("均衡 · 15 FPS").tag(15)
                Text("流畅 · 30 FPS").tag(30)
            }.pickerStyle(.segmented)
            VStack(alignment:.leading,spacing:12) {
                Picker("黑洞系统",selection:$state.bodyCount) {
                    Text("单体").tag(1);Text("双体").tag(2);Text("三体").tag(3)
                }.pickerStyle(.segmented)
                if state.bodyCount > 1 {
                    HStack {
                        Text("近掠轨道").font(.headline)
                        Spacer()
                        Button {appDelegate?.view.resetOrbits()} label: {Image(systemName:"arrow.counterclockwise")}
                            .help("重置轨道")
                    }
                    dial("公转速度",$state.orbitSpeed,0.1...1.5,String(format:"%.2f×",state.orbitSpeed))
                    Toggle("系统漂移",isOn:$state.systemDrift).tint(accent)
                }
            }
            VStack(alignment:.leading,spacing:11){
                HStack{Text("Codex 状态联动").font(.headline);Spacer();Text(state.codexState.label).font(.system(size:11,design:.monospaced)).foregroundStyle(accent)}
                Picker("状态来源", selection: Binding(get: { state.codexMode }, set: { mode in
                    if mode == .desktop { confirmDesktop = true } else { state.codexMode = mode }
                })) {
                    Text("文件桥接（推荐）").tag(CodexLinkMode.file)
                    Text("手动预览").tag(CodexLinkMode.manual)
                    Text("桌面调试（实验）").tag(CodexLinkMode.desktop)
                }.alert("启用实验性桌面联动？", isPresented: $confirmDesktop) {
                    Button("取消", role: .cancel) {}
                    Button("启用") { state.codexMode = .desktop }
                } message: { Text("调试端口可能允许其他本机进程访问 Codex。文件桥接不需要端口。奇点不会为你打开端口。") }
                if state.codexMode == .manual {
                    Picker("预览状态",selection:Binding(get:{state.codexState.rawValue},set:{raw in if let next=CodexActivityState(rawValue:raw){state.setCodexState(next,source:"手动预览",detail:"")}})) {
                        ForEach(CodexActivityState.allCases,id:\.rawValue){item in Text(item.label).tag(item.rawValue)}
                    }
                }
                Text("来源：\(state.codexSource)").font(.system(size:11)).foregroundStyle(.secondary)
                if !state.codexDetail.isEmpty {Text(state.codexDetail).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).lineLimit(2)}
                Text(state.codexMode == .desktop ? "仅在没有新鲜状态文件时尝试已启用的本机调试端点。" : (state.codexMode == .file ? "只读取本地状态文件，不连接调试端口。" : "手动选择状态，不读取外部状态。")).font(.system(size:11)).foregroundStyle(.secondary)
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
            HStack{Button(state.paused ? "继续流动":"暂停流动"){state.paused.toggle()};Button(state.visible ? "隐藏宠物":"显示宠物"){appDelegate?.togglePet()};Spacer();Button("恢复默认"){state.reset();appDelegate?.centerPet()}}
            HStack{Text("拖动黑洞移动 · 双击或右键打开设置").font(.system(size:11)).foregroundStyle(.secondary);Spacer();Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0")").font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)}
        }.padding(26)}.frame(width:520,height:790).background(Color(red:0.055,green:0.06,blue:0.075)).preferredColorScheme(.dark)
    }
}
