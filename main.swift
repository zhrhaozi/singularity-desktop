import Cocoa

if RunMode.capturePolicyTest {
    CapturePolicyDiagnostic.run()
    exit(0)
}
#if SELF_TEST
guard RunMode.selfTest else {
    fputs("This QA application requires --self-test.\n", stderr)
    exit(64)
}
#else
if RunMode.containsQAOptions {
    fputs("原生自测只在独立的 QA 构建中提供。\n", stderr)
    exit(64)
}
#endif
let app = NSApplication.shared
let delegate = AppDelegate()
appDelegate = delegate
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
