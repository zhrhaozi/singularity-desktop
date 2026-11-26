import Foundation
import ScreenCaptureKit

/// The only diagnostic shipped to users. No AppKit window, pixels, defaults or permission prompt.
enum CapturePolicyDiagnostic {
    private static func require(_ condition: Bool, _ name: String) {
        guard condition else { log("CAPTURE_POLICY_TEST_FAIL \(name)"); exit(1) }
    }
    static func run() {
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

}
