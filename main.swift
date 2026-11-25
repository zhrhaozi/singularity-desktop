import Cocoa

if CommandLine.arguments.contains("--capture-policy-test") {
    NativeSelfTest.recoveryPolicyChecks()
    exit(0)
}
let app=NSApplication.shared
let delegate=AppDelegate();appDelegate=delegate
app.setActivationPolicy(.regular);app.delegate=delegate;app.run()
