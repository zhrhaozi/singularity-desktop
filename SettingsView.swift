import Cocoa
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case appearance = "外观", motion = "运动", codex = "Codex 联动", lens = "桌面透镜", about = "关于"
}

enum PetChoices {
    static let styles = ["炽金", "冷蓝", "星环", "纯透镜"]
    static let systems = ["单体", "双体", "三体"]
}

private enum SettingsPrompt: Int, Identifiable {
    case reset, desktop
    var id: Int { rawValue }
}

/// Draw just the horizontal rail: AppKit still owns the knob, tracking, focus ring and keyboard.
private final class ParameterSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let rail = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor(white: 1, alpha: 0.17).setFill()
        NSBezierPath(roundedRect: rail, xRadius: 2, yRadius: 2).fill()
        let middle = min(rail.maxX, max(rail.minX, knobRect(flipped: flipped).midX))
        let rtl = controlView?.userInterfaceLayoutDirection == .rightToLeft
        let filled = NSRect(x: rtl ? middle : rail.minX, y: rail.minY,
                            width: rtl ? rail.maxX - middle : middle - rail.minX, height: rail.height)
        NSColor(srgbRed: 0.96, green: 0.74, blue: 0.44, alpha: isEnabled ? 1 : 0.45).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}

/// Keep AppKit's keyboard, continuous tracking and VoiceOver semantics, and tint the native track.
private struct ParameterSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let display: String

    final class Coordinator: NSObject {
        var binding: Binding<Double>
        init(_ binding: Binding<Double>) { self.binding = binding }
        @objc func change(_ sender: NSSlider) { binding.wrappedValue = sender.doubleValue }
    }
    func makeCoordinator() -> Coordinator { Coordinator($value) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(frame: .zero)
        slider.cell = ParameterSliderCell()
        slider.target = context.coordinator; slider.action = #selector(Coordinator.change(_:))
        slider.isContinuous = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.binding = $value
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        if slider.doubleValue != value { slider.doubleValue = value }
        slider.setAccessibilityLabel(label); slider.setAccessibilityValueDescription(display)
    }
}

private struct TrailingFieldStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) { configuration.label; Spacer(minLength: 8); configuration.content }
    }
}

struct SettingsView: View {
    @ObservedObject var state: Model
    @State private var tab: SettingsTab
    @State private var prompt: SettingsPrompt?
    @State private var hexDraft: String?
    @FocusState private var editingHex: Bool
    private let accent = Color(red: 0.96, green: 0.74, blue: 0.44)
    private let muted = Color.white.opacity(0.70)
    private let backdrop = Color(red: 0.055, green: 0.06, blue: 0.075)
    private static let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    private let palette = [("炽金", "#FFAA55"), ("霓虹紫", "#8A5CFF"), ("青蓝", "#4FD1FF"), ("玫红", "#FF4D6D"),
                           ("极光绿", "#7CFFB2"), ("白色", "#FFFFFF"), ("淡金", "#FFD86B"), ("橙色", "#FF7A1A")]

    init(state: Model, initialTab: SettingsTab = .appearance) {
        self.state = state
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 24).padding(.top, 19)
            Picker("设置分类", selection: $tab) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("设置分类")
                .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            if !state.rendererError.isEmpty { warning(state.rendererError).padding(.horizontal, 24).padding(.top, 10) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .appearance: appearance
                    case .motion: motion
                    case .codex: codex
                    case .lens: lens
                    case .about: about
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 16)
            }.id(tab) // A new section always opens at its top.
        }
        .frame(minWidth: 520, minHeight: 540).background(backdrop)
        .labeledContentStyle(TrailingFieldStyle()).preferredColorScheme(.dark).accentColor(accent).tint(accent).toggleStyle(.switch)
        .alert(item: $prompt) { which in
            switch which {
            case .desktop:
                return Alert(title: Text("启用实验性桌面联动？"),
                             message: Text("开放调试端口后，其他本机进程也可能访问已登录的 Codex。文件桥接不需要端口，奇点也不会替你开启端口。"),
                             primaryButton: .default(Text("启用桌面联动")) { state.codexMode = .desktop },
                             secondaryButton: .cancel(Text("取消")))
            case .reset:
                return Alert(title: Text("恢复全部默认设置？"),
                             message: Text("外观、运动、桌面刷新和联动来源会恢复默认，桌宠将回到屏幕中央。此操作不能撤销。"),
                             primaryButton: .destructive(Text("恢复默认")) {
                                 hexDraft = nil; state.reset(); appDelegate?.centerPet()
                             }, secondaryButton: .cancel(Text("取消")))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let icon = Self.icon { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 54, height: 54).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("奇点").font(.system(size: 26, weight: .medium, design: .serif))
                    Text("Singularity").font(.system(size: 12)).foregroundStyle(muted)
                }
                Spacer()
                Button { state.paused.toggle() } label: { Label(state.paused ? "继续流动" : "暂停流动", systemImage: state.paused ? "play.fill" : "pause.fill") }
                Button { appDelegate?.togglePet() } label: { Label(state.visible ? "隐藏" : "显示", systemImage: state.visible ? "eye.slash" : "eye") }
                    .help(state.visible ? "隐藏桌宠并暂停桌面采样" : "重新显示桌宠")
            }
            HStack(spacing: 16) {
                statusLink(state.capturing ? "透镜已连接" : "透镜未连接", symbol: state.capturing ? "checkmark.circle.fill" : "circle.dashed", color: state.capturing ? .green : muted, target: .lens)
                statusLink("Codex · " + (state.codexState.label.components(separatedBy: " · ").first ?? state.codexState.token), symbol: "circle.hexagongrid", color: state.codexState == .error ? .orange : accent, target: .codex)
            }
        }
    }

    private func statusLink(_ text: String, symbol: String, color: Color, target: SettingsTab) -> some View {
        Button { tab = target } label: {
            Label { Text(text).foregroundStyle(muted) } icon: { Image(systemName: symbol).foregroundStyle(color) }
        }.buttonStyle(.plain).font(.system(size: 12)).help("前往" + target.rawValue)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            content()
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
    }
    private func warning(_ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .font(.system(size: 12)).foregroundStyle(Color.orange)
    }
    private func dial(_ name: String, _ value: Binding<Double>, _ spec: NumericSetting<Double>, _ display: String) -> some View {
        HStack(spacing: 12) {
            Text(name).frame(width: 85, alignment: .leading)
            ParameterSlider(value: value, range: spec.range, label: name, display: display).frame(height: 18)
            Text(display).font(.system(size: 12, design: .monospaced)).foregroundStyle(accent).frame(width: 63, alignment: .trailing)
        }
    }

    private func switchRow(_ name: String, _ value: Binding<Bool>) -> some View {
        LabeledContent(name) { Toggle(name, isOn: value).labelsHidden().accessibilityLabel(name).fixedSize() }
    }

    @ViewBuilder private var appearance: some View {
        section("外观参数") {
            LabeledContent("吸积盘风格") {
                Picker("吸积盘风格", selection: $state.style) {
                    ForEach(PetChoices.styles.indices, id: \.self) { Text(PetChoices.styles[$0]).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 280)
            }
            dial("黑洞大小", $state.size, SettingsSpec.size, "\(Int(state.size)) pt")
            dial("引力透镜", $state.lens, SettingsSpec.lens, String(format: "%.1f", state.lens))
            dial("吸积盘亮度", $state.brightness, SettingsSpec.brightness, String(format: "%.1f", state.brightness))
            dial("轨道倾角", $state.tilt, SettingsSpec.tilt, String(format: "%.0f°", state.tilt * 180 / .pi))
            dial("画面旋转", $state.roll, SettingsSpec.roll, String(format: "%.0f°", state.roll * 180 / .pi))
        }
        section("吸积盘颜色") {
            switchRow("自定义盘色", $state.customColor)
            if state.customColor { colors }
            if state.style == 3 { note("纯透镜不显示吸积盘；切换到其他风格即可看到盘色。") }
        }
        section("黑洞分型") {
            LabeledContent("黑洞类型") {
                Picker("黑洞类型", selection: $state.kind) {
                    Text("史瓦西 · Schwarzschild").tag(0); Text("旋转 · Kerr").tag(1)
                    Text("带电 · Reissner–Nordström").tag(2); Text("旋转带电 · Kerr–Newman").tag(3)
                }.labelsHidden().fixedSize()
            }
            dial("质量尺度", $state.mass, SettingsSpec.mass, String(format: "%.2f×", state.mass))
            if state.hasSpin { dial("自旋", $state.spin, SettingsSpec.spin, String(format: "%+.2f", state.spin)) }
            if state.hasCharge { dial("电荷", $state.charge, SettingsSpec.charge, String(format: "%.2f", state.effectiveCharge)) }
            if state.kind == 3 { note("这里显示有效电荷；自旋越强，可用电荷上限越低。") }
        }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(palette.indices, id: \.self) { index in
                    let (name, hex) = palette[index]
                    let rgb = RGB(hex: hex) ?? .amber
                    Button { hexDraft = nil; state.colorHex = hex } label: {
                        ZStack {
                            Circle().fill(Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b)).frame(width: 19, height: 19)
                            if state.colorHex == hex { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black) }
                        }.frame(width: 23, height: 23)
                    }.buttonStyle(.plain).help(name).accessibilityLabel(name).accessibilityValue(state.colorHex == hex ? "已选中" : "未选中")
                }
                Spacer()
            }
            HStack {
                ColorPicker("选取颜色", selection: Binding(get: {
                    let c = state.customRGB; return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
                }, set: { color in
                    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                    let channels = [c.redComponent, c.greenComponent, c.blueComponent].map { Int((min(1, max(0, $0)) * 255).rounded()) }
                    hexDraft = nil; state.colorHex = String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
                }), supportsOpacity: false)
                Spacer(); Text("HEX").font(.system(size: 12)).foregroundStyle(muted)
                TextField("#RRGGBB", text: Binding(get: { hexDraft ?? state.colorHex }, set: { text in
                    hexDraft = text
                    if let rgb = RGB(hex: text) { state.colorHex = rgb.hex }
                })).textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced)).frame(width: 98)
                    .focused($editingHex).onChange(of: editingHex) { if !$0 { hexDraft = nil } }
                    .accessibilityLabel("十六进制颜色")
            }
            if let draft = hexDraft, RGB(hex: draft) == nil { warning("请输入 3 位或 6 位十六进制颜色；当前颜色未改变。") }
        }
    }

    @ViewBuilder private var motion: some View {
        section("黑洞系统") {
            LabeledContent("天体数量") {
                Picker("天体数量", selection: $state.bodyCount) {
                    ForEach(PetChoices.systems.indices, id: \.self) { Text(PetChoices.systems[$0]).tag($0 + 1) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            if state.bodyCount > 1 {
                dial("公转速度", $state.orbitSpeed, SettingsSpec.orbitSpeed, String(format: "%.2f×", state.orbitSpeed))
                switchRow("系统漂移", $state.systemDrift)
                Button("重置轨道") { appDelegate?.view?.resetOrbits() }.help("只重置天体的位置和速度，保留外观设置")
            } else { note("切换到双体或三体，即可调整公转和系统漂移。") }
        }
        section("流动与漫游") {
            dial("流动速度", $state.speed, SettingsSpec.speed, String(format: "%.1f×", state.speed))
            switchRow("桌面随机漫游", $state.wander)
            if state.wander { dial("移动速度", $state.travelSpeed, SettingsSpec.travelSpeed, "\(Int(state.travelSpeed)) pt/s") }
            note("漫游限于当前屏幕。鼠标靠近、拖动或打开设置时暂停；关闭设置后继续。")
        }
    }

    @ViewBuilder private var codex: some View {
        section("状态来源") {
            Picker("状态来源", selection: Binding(get: { state.codexMode }, set: { mode in
                if mode == .desktop && state.codexMode != .desktop { prompt = .desktop } else { state.codexMode = mode }
            })) {
                Text("文件桥接（推荐）").tag(CodexLinkMode.file); Text("手动预览").tag(CodexLinkMode.manual)
                Text("桌面调试（实验）").tag(CodexLinkMode.desktop)
            }.labelsHidden().fixedSize()
            switch state.codexMode {
            case .file: note("只读取本机状态文件。不连接调试端口；12 秒没有新事件时回到空闲。")
            case .manual: note("只预览所选状态，不读取文件，也不连接 Codex。")
            case .desktop: warning("实验模式：状态文件优先。没有新鲜文件时才尝试本机调试端点。")
            }
        }
        section("当前状态") {
            if state.codexMode == .manual {
                Picker("预览状态", selection: Binding(get: { state.codexState }, set: { state.setCodexState($0, source: "手动预览") })) {
                    ForEach(CodexActivityState.allCases, id: \.rawValue) { Text($0.label).tag($0) }
                }
            } else { LabeledContent("状态", value: state.codexState.label) }
            LabeledContent("来源", value: state.codexSource)
            if !state.codexDetail.isEmpty { note(state.codexDetail) }
        }
        if state.codexMode != .manual {
            section("发送一个完成事件") {
                HStack { Text("singularity-codex-state complete").font(.system(size: 12, design: .monospaced)).textSelection(.enabled); Spacer()
                    Button("复制命令") {
                        guard let path = Bundle.main.url(forResource: "singularity-codex-state", withExtension: nil)?.path else { return }
                        let command = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' complete"
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
                    }
                }
                note("复制的是本应用内桥接工具的完整路径。只有明确的完成事件才会触发完成闪光。")
            }
        }
    }

    @ViewBuilder private var lens: some View {
        section("桌面透镜") {
            Label(state.captureState, systemImage: state.capturing ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(state.capturing ? Color.green : Color.primary)
            if !state.capturing && !state.error.isEmpty { warning(state.error) }
            HStack {
                if !state.capturing && state.visible {
                    Button("打开屏幕录制设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                    }
                }
                Button(state.capturing ? "重新连接" : "连接透镜") { appDelegate?.enableCapture(retryPreferredBackend: true) }
                    .disabled(!state.visible || !state.rendererError.isEmpty)
                Spacer()
                Menu { Button("在访达中显示当前应用") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) } }
                    label: { Image(systemName: "ellipsis.circle") }
                    .fixedSize().accessibilityLabel("更多桌面透镜选项")
            }
            if !state.visible { note("先显示桌宠，再连接桌面透镜。") }
        }
        section("背景刷新") {
            Picker("背景刷新频率", selection: $state.backgroundFPS) {
                Text("自动 · 2–10 FPS").tag(10); Text("均衡 · 15 FPS").tag(15); Text("流畅 · 30 FPS").tag(30)
            }.labelsHidden().pickerStyle(.segmented)
            note("只改变桌面背景的刷新频率，不改变黑洞动画速度。屏幕画面仅在本机内存中用于渲染，不录制、不上传。")
        }
    }

    @ViewBuilder private var about: some View {
        section("奇点 · Singularity") {
            LabeledContent("版本", value: RunMode.version)
            note("让一小片时空，停留在桌面。黑洞分型与多体碰撞是视觉近似，不用于科学计算。")
        }
        section("使用方法") {
            LabeledContent("移动桌宠", value: "拖动黑洞")
            LabeledContent("打开设置", value: "双击黑洞，或在应用内按 ⌘ ,")
            LabeledContent("快捷操作", value: "右键黑洞或点按菜单栏图标")
            note("暂停会停止流动、公转和漫游；隐藏还会暂停桌面采样。")
        }
        section("默认设置") { Button("恢复全部默认设置…") { prompt = .reset } }
        note("着色器基于 s0xDk/ghostty-blackhole；多体运动使用 Chipmunk2D（MIT）。")
    }
}
