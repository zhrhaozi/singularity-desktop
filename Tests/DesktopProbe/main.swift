import Foundation

// Explicitly invoked live diagnostic. Only state tokens and fixed descriptions leave the renderer.
guard CommandLine.arguments.contains("--live") else {
    fputs("Use --live to inspect the local Codex debug endpoint without changing its state.\n", stderr)
    exit(64)
}
let probe = CodexDesktopProbe()
if CommandLine.arguments.contains("--cancel-check") {
    probe.poll { _ in
        fputs("FAIL: cancelled callback was delivered\n", stderr)
        exit(1)
    }
    probe.cancel()
}
probe.poll { result in
    switch result {
    case .success(let snapshot):
        let data = try! JSONEncoder().encode(snapshot)
        print(String(data: data, encoding: .utf8)!)
        exit(0)
    case .failure:
        fputs("Codex desktop state unavailable\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
