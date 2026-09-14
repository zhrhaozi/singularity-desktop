import Foundation

enum CodexActivityState: Int, CaseIterable, Codable {
    case idle = 0, thinking = 1, command = 2, longTask = 3, complete = 4, error = 5

    init?(token: String) {
        switch token {
        case "idle": self = .idle
        case "thinking": self = .thinking
        case "command": self = .command
        case "long": self = .longTask
        case "complete": self = .complete
        case "error": self = .error
        default: return nil
        }
    }

    var token: String {
        switch self {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .command: return "command"
        case .longTask: return "long"
        case .complete: return "complete"
        case .error: return "error"
        }
    }
    var label: String {
        switch self {
        case .idle: return "空闲 · Idle"
        case .thinking: return "思考中 · Thinking"
        case .command: return "运行命令 · Command"
        case .longTask: return "长任务 · Long task"
        case .complete: return "已完成 · Complete"
        case .error: return "出错 · Error"
        }
    }
    var energy: Float {
        switch self {
        case .idle: return 0.14
        case .thinking: return 0.45
        case .command: return 0.82
        case .longTask: return 0.94
        case .complete: return 0.36
        case .error: return 0.68
        }
    }
    var trail: Float {
        switch self {
        case .idle: return 0.06
        case .thinking: return 0.14
        case .command: return 0.22
        case .longTask: return 0.82
        case .complete: return 0.10
        case .error: return 0.18
        }
    }
    var particleDensity: Float {
        switch self {
        case .idle: return 0.10
        case .thinking: return 0.42
        case .command: return 0.92
        case .longTask: return 0.70
        case .complete: return 0.30
        case .error: return 0.52
        }
    }
}

struct CodexStateSnapshot: Codable {
    let state: String
    let detail: String?
    let updatedAt: TimeInterval?
    let eventID: String?

    init(state: String, detail: String? = nil, updatedAt: TimeInterval? = nil, eventID: String? = nil) {
        self.state = state
        self.detail = detail
        self.updatedAt = updatedAt
        self.eventID = eventID
    }
}

enum CodexStateSource: String {
    case file = "本地状态桥接"
    case desktop = "Codex 桌面状态"
}

/// Pure state logic. All deadlines use an injected monotonic clock, never wall time.
struct CodexStateMachine {
    static let completionHold: TimeInterval = 1.4
    static let observationTimeout: TimeInterval = 3
    private(set) var state: CodexActivityState = .idle
    private(set) var source = "等待 Codex 桌面状态"
    private(set) var detail = ""
    private(set) var observationSource: CodexStateSource?
    private(set) var baseActivity: CodexActivityState?
    private(set) var completionDeadline: TimeInterval?
    private(set) var resultSerial: UInt64 = 0
    private var lastObservation: TimeInterval?
    private var busySince: TimeInterval?
    private var lastInputs: [CodexStateSource: CodexActivityState] = [:]
    private var seenEvents: Set<String> = []
    private var eventOrder: [String] = []

    @discardableResult
    mutating func accept(_ snapshot: CodexStateSnapshot, source incomingSource: CodexStateSource, now: TimeInterval) -> Bool {
        guard let next = CodexActivityState(token: snapshot.state) else { return false }
        advance(now: now)
        let previousInput = lastInputs[incomingSource]
        lastInputs[incomingSource] = next
        lastObservation = now
        observationSource = incomingSource

        if next == .complete || next == .error {
            if let id = snapshot.eventID {
                let key = incomingSource.rawValue + "|" + next.token + "|" + id
                guard !seenEvents.contains(key) else { return true }
                seenEvents.insert(key)
                eventOrder.append(key)
                // Bounded replay cache; an input file itself is valid for only 12 seconds.
                if eventOrder.count > 128 { seenEvents.remove(eventOrder.removeFirst()) }
            } else if previousInput == next {
                // Legacy/DOM observations without IDs are edge-triggered, not detail-triggered.
                return true
            }
            busySince = nil
            baseActivity = nil
            state = next
            source = incomingSource.rawValue
            detail = snapshot.detail ?? ""
            completionDeadline = next == .complete ? now + Self.completionHold : nil
            resultSerial &+= 1
            return true
        }

        if next == .idle {
            busySince = nil
            baseActivity = nil
            // Repeated idle observations cannot truncate an explicit completion event.
            if state == .complete, let deadline = completionDeadline, now < deadline { return true }
            completionDeadline = nil
            state = .idle
        } else {
            completionDeadline = nil
            if busySince == nil { busySince = now }
            if next != .longTask { baseActivity = next }
            state = next == .longTask || now - (busySince ?? now) >= 30 ? .longTask : next
        }
        source = incomingSource.rawValue
        detail = snapshot.detail ?? ""
        return true
    }

    mutating func advance(now: TimeInterval) {
        if let observed = lastObservation, now - observed >= Self.observationTimeout {
            unavailable()
            return
        }
        if let deadline = completionDeadline, now >= deadline {
            completionDeadline = nil
            state = .idle
            detail = "Codex 当前空闲"
        }
    }

    mutating func pauseObservation(now: TimeInterval) {
        advance(now: now)
        lastObservation = nil
    }

    mutating func resumeObservation(now: TimeInterval) {
        // Retain busy/event continuity across deliberate invisibility, but bound
        // the grace period until a fresh observation arrives.
        advance(now: now)
        if observationSource != nil { lastObservation = now }
    }

    mutating func unavailable() {
        state = .idle
        source = "等待 Codex 桌面状态"
        detail = "状态来源不可用，已回退空闲（不代表任务完成）"
        observationSource = nil
        lastObservation = nil
        busySince = nil
        baseActivity = nil
        completionDeadline = nil
        // A legacy DOM snapshot has no event ID, so its edge identity is the
        // last observed token. Drop that identity on disconnect; a same-token
        // observation after reconnect is a new visible edge and may pulse.
        lastInputs.removeAll()
        // Keep event history across failures/restarts to avoid replaying the same result.
    }
}

/// Optional eventID keeps old state files compatible. Freshness intentionally uses mtime.
struct CodexStateFile {
    static let lifetime: TimeInterval = 12
    static func read(_ url: URL, now: Date) -> CodexStateSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber, size.intValue <= 65536,
              now.timeIntervalSince(modified) >= 0,
              now.timeIntervalSince(modified) < lifetime,
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(CodexStateSnapshot.self, from: data),
              CodexActivityState(token: value.state) != nil else { return nil }
        // Old writers lack eventID: a stable mtime/state identity prevents per-poll replay.
        let id = value.eventID ?? "legacy:\(modified.timeIntervalSince1970):\(value.state)"
        return CodexStateSnapshot(state: value.state, detail: value.detail, updatedAt: value.updatedAt, eventID: id)
    }
}

protocol CodexStateModel: AnyObject {
    var codexAuto: Bool { get }
    var codexState: CodexActivityState { get }
    var codexSource: String { get }
    var codexDetail: String { get }
    var codexPulse: Double { get set }
    func setCodexState(_ next: CodexActivityState, source: String, detail: String)
}

/// Completion callbacks are delivered on the main thread. Tests inject a local fake.
protocol CodexStateProbing: AnyObject {
    func poll(completion: @escaping (Result<CodexStateSnapshot, Error>) -> Void)
    func cancel()
}

struct CodexCDPTarget: Decodable {
    let title: String?
    let type: String
    let url: String
    let webSocketDebuggerUrl: String?

    var isCodexWindow: Bool {
        guard type == "page", let address = URL(string: url) else { return false }
        return address.scheme == "app" && address.host == "-" &&
            ["/index.html", "/detached-window.html"].contains(address.path)
    }

    var socketURL: URL? {
        guard let text = webSocketDebuggerUrl, let address = URL(string: text),
              ["ws", "wss"].contains(address.scheme ?? ""),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(address.host ?? ""),
              address.port == 9229, address.user == nil, address.password == nil else { return nil }
        return address
    }
}

enum CodexDesktopObservation {
    static let states = ["idle", "error", "thinking", "command"]

    static func combine(_ snapshots: [CodexStateSnapshot], incomplete: Bool) -> CodexStateSnapshot? {
        let valid = snapshots.filter { states.contains($0.state) }
        guard let selected = valid.max(by: {
            states.firstIndex(of: $0.state)! < states.firstIndex(of: $1.state)!
        }), selected.state != "idle" || !incomplete else { return nil }
        let descriptions = [
            "idle": "Codex 工作窗口当前空闲",
            "thinking": "检测到 Codex 工作窗口正在思考",
            "command": "检测到 Codex 工作窗口正在运行命令",
            "error": "检测到 Codex 工作窗口的错误提示"
        ]
        let coverage = incomplete ? "部分窗口暂不可用" : "已检查 \(valid.count) 个窗口"
        return CodexStateSnapshot(state: selected.state, detail: "\(descriptions[selected.state]!)（\(coverage)）")
    }

    static let expression = """
    (() => {
      const visible = e => e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden' && getComputedStyle(e).display !== 'none';
      const controls = [...document.querySelectorAll('button,[role="button"],[role="status"],[role="alert"],[aria-live]')]
        .filter(visible)
        .flatMap(e => [e.getAttribute('aria-label') || '', e.innerText || ''])
        .map(t => t.trim()).filter(Boolean);
      const stop = controls.some(t => /^(停止|中止)(生成|回复|响应|任务|运行)?$|^(Stop|Cancel)( (generating|generation|responding|response|task|turn|thread))?$/i.test(t));
      const busy = [...document.querySelectorAll('[aria-busy="true"],[data-loading="true"]')].some(visible);
      const command = controls.some(t => /^(正在运行|Running)(?:\\s|$)/i.test(t));
      const error = controls.some(t => /失败|出错|错误|failed|error/i.test(t));
      const state = (stop || busy) ? (command ? 'command' : 'thinking') : (error ? 'error' : 'idle');
      return JSON.stringify({state});
    })()
    """
}

private enum CodexProbeError: Error { case unavailable, timeout, invalidResponse }

/// One bounded batch checks all Codex windows. No callback survives cancellation.
final class CodexDesktopProbe: CodexStateProbing {
    private let session: URLSession
    private var dataTask: URLSessionDataTask?
    private var sockets: [URLSessionWebSocketTask] = []
    private var observations: [CodexStateSnapshot] = []
    private var outstanding = 0
    private var failures = 0
    private var deadline: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var completion: ((Result<CodexStateSnapshot, Error>) -> Void)?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        session = URLSession(configuration: config)
    }

    func cancel() {
        generation &+= 1
        deadline?.cancel(); deadline = nil
        dataTask?.cancel(); dataTask = nil
        sockets.forEach { $0.cancel(with: .goingAway, reason: nil) }; sockets.removeAll()
        observations.removeAll(); outstanding = 0; failures = 0
        completion = nil
    }

    func poll(completion: @escaping (Result<CodexStateSnapshot, Error>) -> Void) {
        precondition(Thread.isMainThread)
        cancel()
        self.completion = completion
        let token = generation
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishObservations(token: token)
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        let url = URL(string: "http://127.0.0.1:9229/json/list")!
        dataTask = session.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(token) else { return }
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, let targets = try? JSONDecoder().decode([CodexCDPTarget].self, from: data) else {
                    self.finish(.failure(CodexProbeError.unavailable), token: token)
                    return
                }
                let windows = targets.filter(\.isCodexWindow)
                // Do not silently ignore windows or trust unrelated browser/webview targets.
                guard !windows.isEmpty, windows.count <= 16 else {
                    self.finish(.failure(CodexProbeError.unavailable), token: token)
                    return
                }
                self.outstanding = windows.count
                windows.forEach { self.evaluate($0, token: token) }
            }
        }
        dataTask?.resume()
    }

    private func isCurrent(_ token: UInt64) -> Bool { token == generation && completion != nil }

    private func finish(_ result: Result<CodexStateSnapshot, Error>, token: UInt64) {
        guard isCurrent(token), let callback = completion else { return }
        cancel()
        callback(result)
    }

    private func finishObservations(token: UInt64) {
        guard isCurrent(token) else { return }
        if let snapshot = CodexDesktopObservation.combine(observations, incomplete: outstanding > 0 || failures > 0) {
            finish(.success(snapshot), token: token)
        } else {
            finish(.failure(CodexProbeError.unavailable), token: token)
        }
    }

    private func record(_ result: Result<CodexStateSnapshot, Error>, token: UInt64) {
        guard isCurrent(token) else { return }
        switch result {
        case .success(let snapshot): observations.append(snapshot)
        case .failure: failures += 1
        }
        outstanding -= 1
        if outstanding == 0 { finishObservations(token: token) }
    }

    private func evaluate(_ target: CodexCDPTarget, token: UInt64) {
        guard let url = target.socketURL else {
            record(.failure(CodexProbeError.invalidResponse), token: token)
            return
        }
        let task = session.webSocketTask(with: url)
        sockets.append(task)
        task.resume()
        let payload: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": ["expression": CodexDesktopObservation.expression, "returnByValue": true, "awaitPromise": true]]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let message = String(data: encoded, encoding: .utf8) else {
            record(.failure(CodexProbeError.invalidResponse), token: token)
            return
        }
        task.send(.string(message)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(token) else { return }
                if let error { self.record(.failure(error), token: token) }
                else { self.receive(task, token: token) }
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, token: UInt64) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.isCurrent(token) else { return }
                switch result {
                case .failure(let error): self.record(.failure(error), token: token)
                case .success(let message):
                    let data: Data?
                    switch message {
                    case .string(let text): data = text.data(using: .utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: data = nil
                    }
                    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        self.record(.failure(CodexProbeError.invalidResponse), token: token)
                        return
                    }
                    guard object["id"] as? Int == 1 else {
                        self.receive(task, token: token) // Ignore protocol events within the same deadline.
                        return
                    }
                    guard let outer = object["result"] as? [String: Any],
                          let inner = outer["result"] as? [String: Any],
                          let value = inner["value"] as? String,
                          let bytes = value.data(using: .utf8),
                          let snapshot = try? JSONDecoder().decode(CodexStateSnapshot.self, from: bytes),
                          CodexDesktopObservation.states.contains(snapshot.state) else {
                        self.record(.failure(CodexProbeError.invalidResponse), token: token)
                        return
                    }
                    self.record(.success(snapshot), token: token)
                }
            }
        }
    }

    deinit { session.invalidateAndCancel() }
}

/// Main-thread coordinator. A fresh file always wins, even if it appears during a probe.
final class CodexStateBridge {
    private weak var model: CodexStateModel?
    private let probe: CodexStateProbing
    private let stateFileURL: URL
    private let now: () -> TimeInterval
    private let wallNow: () -> Date
    private var machine = CodexStateMachine()
    private var timer: Timer?
    private var settleWork: DispatchWorkItem?
    private var scheduledDeadline: TimeInterval?
    private var lastDeliveredResult: UInt64 = 0
    private var lastPoll = -TimeInterval.infinity
    private var generation: UInt64 = 0
    private var inFlight: UInt64?
    private var running = false
    private var observationPaused = false
    private var probeFailures = 0
    private var nextProbeAt = -TimeInterval.infinity
    var isRunning: Bool { running }
    var hasScheduledTimer: Bool { timer != nil }

    init(model: CodexStateModel, stateFileURL: URL? = nil,
         probe: CodexStateProbing = CodexDesktopProbe(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallNow: @escaping () -> Date = { Date() }) {
        self.model = model
        self.probe = probe
        self.now = now
        self.wallNow = wallNow
        if let stateFileURL { self.stateFileURL = stateFileURL }
        else if let override = ProcessInfo.processInfo.environment["SINGULARITY_STATE_DIR"], !override.isEmpty {
            self.stateFileURL = URL(fileURLWithPath: override).appendingPathComponent("codex-state.json")
        } else {
            self.stateFileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Singularity/codex-state.json")
        }
    }

    func start(scheduleTimer: Bool = true) {
        precondition(Thread.isMainThread)
        stop()
        resume(scheduleTimer: scheduleTimer)
    }

    func resume(scheduleTimer: Bool = true) {
        precondition(Thread.isMainThread)
        guard !running else { return }
        guard model?.codexAuto == true else { return }
        if observationPaused { machine.resumeObservation(now: now()) }
        observationPaused = false
        running = true
        lastPoll = -.infinity
        probeFailures = 0; nextProbeAt = -.infinity
        if scheduleTimer {
            let next = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
            next.tolerance = 0.1
            timer = next
            RunLoop.main.add(next, forMode: .common)
        }
        poll()
    }

    func stop() {
        precondition(Thread.isMainThread)
        pause()
        observationPaused = false
        machine.unavailable()
    }

    func pause() {
        precondition(Thread.isMainThread)
        if running {
            machine.pauseObservation(now: now())
            observationPaused = true
        }
        running = false
        timer?.invalidate(); timer = nil
        settleWork?.cancel(); settleWork = nil; scheduledDeadline = nil
        cancelProbe()
    }

    func restartIfNeeded(active: Bool = true) {
        if model?.codexAuto == true {
            if active { resume() } else { pause() }
        }
        else {
            stop()
            if let model { model.setCodexState(model.codexState, source: "手动预览", detail: model.codexDetail) }
        }
    }

    func refresh() {
        precondition(Thread.isMainThread)
        guard running else { return }
        cancelProbe()
        probeFailures = 0; nextProbeAt = -.infinity; lastPoll = -.infinity
        poll()
    }

    func poll() {
        precondition(Thread.isMainThread)
        guard running, model?.codexAuto == true else { return }
        let time = now()
        guard time - lastPoll >= 0.35 else { return }
        lastPoll = time
        machine.advance(now: time)
        if acceptFreshFile() { return }
        // Expired file ownership is released immediately, without fabricating success.
        if machine.observationSource == .file { machine.unavailable() }
        publish()
        guard inFlight == nil, time >= nextProbeAt else { return }
        generation &+= 1
        let token = generation
        inFlight = token
        probe.poll { [weak self] result in
            self?.handle(result, token: token)
        }
    }

    private func cancelProbe() {
        generation &+= 1
        inFlight = nil
        probe.cancel()
    }

    private func acceptFreshFile() -> Bool {
        guard let snapshot = CodexStateFile.read(stateFileURL, now: wallNow()) else { return false }
        cancelProbe()
        probeFailures = 0; nextProbeAt = -.infinity
        machine.accept(snapshot, source: .file, now: now())
        publish()
        return true
    }

    private func handle(_ result: Result<CodexStateSnapshot, Error>, token: UInt64) {
        precondition(Thread.isMainThread)
        guard running, model?.codexAuto == true, inFlight == token, generation == token else { return }
        // Recheck priority now, not just when the HTTP request began.
        if acceptFreshFile() { return }
        inFlight = nil
        let accepted: Bool
        switch result {
        case .success(let snapshot):
            accepted = machine.accept(snapshot, source: .desktop, now: now())
        case .failure: accepted = false
        }
        if accepted {
            probeFailures = 0; nextProbeAt = -.infinity
        } else {
            machine.unavailable()
            probeFailures = min(6, probeFailures + 1)
            nextProbeAt = now() + min(30, pow(2, Double(probeFailures - 1)))
        }
        publish()
    }

    private func publish() {
        guard running, let model, model.codexAuto else { return }
        if model.codexState != machine.state || model.codexSource != machine.source || model.codexDetail != machine.detail {
            model.setCodexState(machine.state, source: machine.source, detail: machine.detail)
        }
        if machine.resultSerial != lastDeliveredResult {
            lastDeliveredResult = machine.resultSerial
            model.codexPulse = 1 // Reuse the existing result signal; rendering is unchanged.
        }
        guard scheduledDeadline != machine.completionDeadline else { return }
        settleWork?.cancel(); settleWork = nil
        scheduledDeadline = machine.completionDeadline
        if let end = machine.completionDeadline {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.running, self.model?.codexAuto == true else { return }
                self.scheduledDeadline = nil
                self.machine.advance(now: self.now())
                self.publish()
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, end - now()), execute: work)
        }
    }

    deinit {
        timer?.invalidate()
        settleWork?.cancel()
        probe.cancel()
    }
}
