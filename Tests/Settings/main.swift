import Cocoa
import SwiftUI

// A separate executable and bundle, with no AppDelegate launch, real state bridge,
// screen capture, preference writes, or onscreen windows.
precondition(RunMode.selfTest && CommandLine.arguments.count == 3)
let out = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let coordinator = AppDelegate()
let actualWindow = coordinator.makeSettingsWindow()
precondition(actualWindow.styleMask.contains(.resizable) && actualWindow.level == .normal)
precondition(actualWindow.contentMinSize == NSSize(width: 520, height: 540))
let menu = coordinator.makeMenu()
model.bodyCount = 2; model.style = 1; model.paused = true
coordinator.menuNeedsUpdate(menu)
precondition(menu.item(withTitle: "暂停流动")?.state == .on)
precondition(menu.item(withTitle: "黑洞系统")?.submenu?.item(withTitle: "双体")?.state == .on)
precondition(menu.item(withTitle: "吸积盘风格")?.submenu?.item(withTitle: "冷蓝")?.state == .on)
precondition(menu.item(withTitle: "Codex：" + model.codexState.label)?.isEnabled == false)

func snap(_ name: String, _ tab: SettingsTab, width: CGFloat = 560, height: CGFloat = 680, setup: (Model) -> Void = { _ in }) throws {
    let state = Model(defaults: nil); setup(state)
    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    let host = NSHostingView(rootView: SettingsView(state: state, initialTab: tab).environment(\.locale, Locale(identifier: "zh_CN")).frame(width: width, height: height))
    let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua); host.appearance = window.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.23)); host.layoutSubtreeIfNeeded()
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
try snap("codex-manual", .codex, width: 520, height: 540) {
    $0.codexMode = .manual; $0.setCodexState(.command, source: "手动预览")
}
try snap("lens", .lens) {
    $0.captureState = "需要屏幕录制权限"; $0.error = "请在系统设置中允许「奇点」，再点「连接透镜」。"
}
try snap("about", .about)
print("SETTINGS_QA_PASS 5 tabs, minimum window, file/manual states, menus and real SwiftUI captures")
