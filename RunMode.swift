import Foundation

enum RunMode {
    private static let arguments = Set(CommandLine.arguments.dropFirst())
    static let selfTest = arguments.contains("--self-test")
    static let performance = selfTest && arguments.contains("--self-test-performance")
    static let renderOnly = selfTest && arguments.contains("--self-test-render-only")
    static let petOnly = arguments.contains("--pet-only")
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}
