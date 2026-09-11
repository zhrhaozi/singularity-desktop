import Foundation

enum CodexActivityState: Int, CaseIterable, Codable {
    case idle = 0
    case thinking = 1
    case command = 2
    case longTask = 3
    case complete = 4
    case error = 5

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
}

struct CodexCDPTarget: Decodable {
    let title: String
    let type: String
    let url: String
    let webSocketDebuggerUrl: String
}

/// Reads the locally exposed ChatGPT/Codex renderer through Chrome DevTools
/// Protocol when the app is running with its local debug port. This is an
/// optional bridge: if the port or target is unavailable the pet remains idle.
final class CodexStateBridge: NSObject {
    weak var model: Model?
    private var timer: Timer?
    private var socket: URLSessionWebSocketTask?
    private var requestID = 0
    private var lastToken = ""
    private var lastPoll = Date.distantPast
    private var busySince: Date?
    private var settleWork: DispatchWorkItem?
    private let stateFileURL: URL

    init(model: Model) {
        self.model = model
        if let override = ProcessInfo.processInfo.environment["SINGULARITY_STATE_DIR"], !override.isEmpty {
            self.stateFileURL = URL(fileURLWithPath: override).appendingPathComponent("codex-state.json")
        } else {
            self.stateFileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Singularity/codex-state.json")
        }
        super.init()
    }

    func start() {
        stop()
        guard model?.codexAuto == true else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    func restartIfNeeded() {
        if model?.codexAuto == true {
            start()
        } else {
            stop()
            DispatchQueue.main.async { [weak self] in
                guard let self, let model = self.model else { return }
                model.setCodexState(model.codexState, source: "手动预览", detail: model.codexDetail)
            }
        }
    }

    func poll() {
        guard let model, model.codexAuto else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPoll) >= 0.35 else { return }
        lastPoll = now
        if readStateFile() { return }
        guard let url = URL(string: "http://127.0.0.1:9229/json/list") else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self, error == nil, let data,
                  let targets = try? JSONDecoder().decode([CodexCDPTarget].self, from: data),
                  let target = targets.first(where: { $0.type == "page" && $0.title == "ChatGPT" && $0.url.hasPrefix("app://-/index.html") })
            else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let model = self.model, model.codexAuto else { return }
                        model.codexSource = "等待 Codex 桌面状态"
                }
                return
            }
            self.evaluate(target: target)
        }.resume()
    }

    private func evaluate(target: CodexCDPTarget) {
        guard let url = URL(string: target.webSocketDebuggerUrl) else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        socket?.cancel(with: .goingAway, reason: nil)
        socket = task
        task.resume()

        requestID += 1
        let id = requestID
        let expression = """
        (() => {
          const stop = [...document.querySelectorAll('button,[role="button"]')].some(b => /^(停止|Stop|中止|Cancel)$/i.test((b.getAttribute('aria-label') || b.innerText || '').trim()));
          const busy = [...document.querySelectorAll('[aria-busy="true"],[data-loading="true"]')].length > 0;
          const leaves = [...document.querySelectorAll('span,div')]
            .filter(e => e.children.length === 0)
            .map(e => (e.innerText || '').trim())
            .filter(Boolean);
          const thinking = leaves.some(t => /^(正在思考|思考中|Thinking)$/i.test(t));
          const command = leaves.some(t => /^(正在运行|Running)(?:\\s|$)/i.test(t));
          const alerts = [...document.querySelectorAll('[role="alert"]')]
            .filter(e => e.getClientRects().length > 0)
            .map(e => (e.innerText || '').trim());
          const error = alerts.some(t => /失败|出错|错误|failed|error/i.test(t));
          const state = (stop || busy) ? (command ? 'command' : 'thinking') : (error ? 'error' : 'idle');
          const detail = state === 'command' ? '检测到正在运行的命令' : state === 'thinking' ? '检测到 Codex 正在思考' : state === 'error' ? '检测到当前错误提示' : 'Codex 当前空闲';
          return JSON.stringify({state, detail});
        })()
        """
        let payload: [String: Any] = [
            "id": id,
            "method": "Runtime.evaluate",
            "params": ["expression": expression, "returnByValue": true, "awaitPromise": true]
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload),
              let message = String(data: encoded, encoding: .utf8)
        else { return }
        task.send(.string(message)) { [weak self, weak task] error in
            guard error == nil, let self else { return }
            self.receive(on: task, requestID: id)
        }
    }

    private func receive(on task: URLSessionWebSocketTask?, requestID: Int) {
        guard let task else { return }
        task.receive { [weak self, weak task] result in
            guard let self else { return }
            switch result {
            case .failure:
                return
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let value): data = value.data(using: .utf8)
                case .data(let value): data = value
                @unknown default: data = nil
                }
                guard let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    self.receive(on: task, requestID: requestID)
                    return
                }
                if let responseID = object["id"] as? Int, responseID == requestID,
                   let result = object["result"] as? [String: Any],
                   let inner = result["result"] as? [String: Any],
                   let value = inner["value"] as? String,
                   let snapshotData = value.data(using: .utf8),
                   let snapshot = try? JSONDecoder().decode(CDPProbeSnapshot.self, from: snapshotData) {
                    DispatchQueue.main.async { [weak self] in self?.apply(snapshot, source: "Codex 桌面状态") }
                    task?.cancel(with: .goingAway, reason: nil)
                    return
                }
                self.receive(on: task, requestID: requestID)
            }
        }
    }

    private func readStateFile() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: stateFileURL.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 12,
              let data = try? Data(contentsOf: stateFileURL),
              let snapshot = try? JSONDecoder().decode(CodexStateSnapshot.self, from: data)
        else { return false }
        apply(CDPProbeSnapshot(state: snapshot.state, detail: snapshot.detail), source: "本地状态桥接")
        return true
    }

    private func apply(_ snapshot: CDPProbeSnapshot, source: String) {
        guard let model, model.codexAuto else { return }
        var next: CodexActivityState
        switch snapshot.state {
        case "thinking": next = .thinking
        case "command": next = .command
        case "error": next = .error
        default: next = .idle
        }
        let wasBusy = model.codexState == .thinking || model.codexState == .command || model.codexState == .longTask
        let isBusy = next == .thinking || next == .command
        if isBusy {
            if busySince == nil { busySince = Date() }
            if Date().timeIntervalSince(busySince ?? Date()) >= 30 { next = .longTask }
            settleWork?.cancel()
        } else if next == .idle, wasBusy {
            busySince = nil
            next = .complete
            let work = DispatchWorkItem { [weak self] in
                guard let self, let model = self.model, model.codexAuto,
                      model.codexState == .complete else { return }
                model.setCodexState(.idle, source: source, detail: "Codex 当前空闲")
                log("CODEX_STATE state=idle source=\(source)")
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
        } else if next == .error {
            busySince = nil
        }
        let token = next.token + "|" + (snapshot.detail ?? "")
        if token != lastToken {
            lastToken = token
            model.setCodexState(next, source: source, detail: snapshot.detail ?? "")
            log("CODEX_STATE state=\(next.token) source=\(source)")
        }
    }
}

private struct CDPProbeSnapshot: Decodable {
    let state: String
    let detail: String?
}
