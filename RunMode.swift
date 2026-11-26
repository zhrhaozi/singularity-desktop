import Foundation

enum RunMode {
    private static let arguments = Set(CommandLine.arguments.dropFirst())
    #if SELF_TEST
    static let selfTest = arguments.contains("--self-test")
    static let performance = selfTest && arguments.contains("--self-test-performance")
    static let renderOnly = selfTest && arguments.contains("--self-test-render-only")
    #else
    static let selfTest = false
    static let performance = false
    static let renderOnly = false
    #endif
    static let capturePolicyTest = arguments.contains("--capture-policy-test")
    static let containsQAOptions = arguments.contains { $0.hasPrefix("--self-test") }
    static let petOnly = arguments.contains("--pet-only")
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
