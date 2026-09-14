import Foundation
import CoreGraphics
import JavaScriptCore
func expect(_ condition:Bool,_ name:String){if !condition{fatalError(name)}}
expect(RGB(hex:"#8a5cff")!.hex=="#8A5CFF","six digit")
expect(RGB(hex:"abc")!.hex=="#AABBCC","short hex")
expect(RGB(hex:"#GG0011")==nil && RGB(hex:"12345")==nil,"reject invalid")
let screen=CGRect(x:-1600,y:50,width:1600,height:1000)
for angle in stride(from:0.0,to:6.28,by:0.4){
 var w=Wander(heading:angle,turnIn:100)
 var p=CGPoint(x:screen.maxX-440,y:screen.maxY-440)
 for _ in 0..<10000 {p=w.advance(origin:p,size:CGSize(width:440,height:440),screen:screen,speed:180,dt:1.0/30)
 expect(p.x>=screen.minX && p.x<=screen.maxX-440 && p.y>=screen.minY && p.y<=screen.maxY-440,"bounds")}
 expect(w.bounceCount>0,"bounce")
}
var w=Wander(heading:0,turnIn:100)
let p=w.advance(origin:CGPoint(x:0,y:0),size:CGSize(width:100,height:100),screen:CGRect(x:0,y:0,width:1000,height:1000),speed:60,dt:0.1)
expect(abs(p.x-6)<0.0001,"points per second")
var r=Wander(heading:0,turnIn:100)
_ = r.advance(origin:CGPoint(x:900,y:900),size:CGSize(width:100,height:100),screen:CGRect(x:0,y:0,width:1000,height:1000),speed:60,dt:0.1,random:{0.5})
expect(cos(r.heading)<0,"right edge folds inward")

let full = CGRect(x:0,y:0,width:1512,height:982)
let desktop = PetScreen(frame:full,visibleFrame:CGRect(x:0,y:76,width:1512,height:872))
let dockChanged = PetScreen(frame:full,visibleFrame:CGRect(x:80,y:24,width:1432,height:924))
let petSize = CGSize(width:280,height:280)
for center in [CGPoint(x:32,y:32),CGPoint(x:1480,y:32),CGPoint(x:32,y:950),CGPoint(x:1480,y:950),CGPoint(x:1511.5,y:981.5)] {
    let pet = CGRect(x:center.x-140,y:center.y-140,width:280,height:280)
    for area in [desktop,dockChanged] {
        expect(PetPlacement.recoveredOrigin(for:pet,screens:[area])==pet.origin,"edge position survives Dock/menu changes, including transparent overflow")
    }
}
let boundaryPet = CGRect(x:1372,y:842,width:280,height:280)
let boundaryRecovery = PetPlacement.recoveredOrigin(for:boundaryPet,screens:[desktop])
expect(boundaryRecovery != boundaryPet.origin,"half-open screen boundary is recovered inward")
expect(boundaryRecovery == CGPoint(x:1340,y:776),"boundary recovery leaves visible drag target")
let secondary = PetScreen(frame:CGRect(x:-1600,y:-100,width:1600,height:1000),visibleFrame:CGRect(x:-1600,y:-70,width:1600,height:940))
let leftPet = CGRect(x:-1500,y:100,width:280,height:280)
expect(PetPlacement.recoveredOrigin(for:leftPet,screens:[desktop,secondary])==leftPet.origin,"negative-coordinate display position preserved")
expect(PetPlacement.recoveredOrigin(for:leftPet,screens:[secondary,desktop])==leftPet.origin,"changing primary display order preserves position")
let recovered = PetPlacement.recoveredOrigin(for:leftPet,screens:[desktop])
expect(recovered==CGPoint(x:-108,y:100),"disconnected display recovers to nearest usable edge, not center")
expect(PetPlacement.recoveredOrigin(for:CGRect(origin:recovered,size:petSize),screens:[desktop])==recovered,"recovery is stable on repeated notifications")
let farLeft = CGRect(x:-3000,y:100,width:280,height:280)
expect(PetPlacement.recoveredOrigin(for:farLeft,screens:[desktop,secondary])==CGPoint(x:-1708,y:100),"recover to nearest screen regardless of array order")
let reduced = PetScreen(frame:CGRect(x:0,y:0,width:1000,height:700),visibleFrame:CGRect(x:0,y:60,width:1000,height:610))
let bottomRight = CGRect(x:1300,y:0,width:280,height:280)
expect(PetPlacement.recoveredOrigin(for:bottomRight,screens:[reduced])==CGPoint(x:828,y:0),"smaller resolution minimally corrects offscreen axis")
expect(PetPlacement.recoveredOrigin(for:bottomRight,screens:[])==bottomRight.origin,"temporary empty screen list preserves saved location")
print("PASS: colors, 160000 roaming steps, edge placement, Dock changes, screen removal/reorder/resizing")

let cropPet = CGRect(x:500,y:400,width:292,height:292)
let crop = CaptureRegion.region(for:cropPet,on:full)
expect(crop==CGRect(x:436,y:336,width:420,height:420),"crop includes moving guard band")
expect(CaptureRegion.region(for:cropPet.offsetBy(dx:10,dy:10),on:full,retaining:crop)==crop,"small motion reuses capture")
expect(CaptureRegion.region(for:cropPet.offsetBy(dx:80,dy:0),on:full,retaining:crop) != crop,"motion refreshes before leaving capture")
expect(CaptureRegion.region(for:cropPet,on:full,retaining:full)==crop,"oversized capture shrinks after dragging")
for s in [full,secondary.frame] {
    let displayBounds=CGRect(x:s.minX,y:full.maxY-s.maxY,width:s.width,height:s.height)
    for x in stride(from:s.minX-140,through:s.maxX-140,by:71) {
        for y in stride(from:s.minY-140,through:s.maxY-140,by:67) {
            let pet=CGRect(x:x,y:y,width:280,height:280)
            let region=CaptureRegion.region(for:pet,on:s)
            expect(s.contains(region),"region remains inside screen")
            let required=pet.intersection(s)
            expect(required.isEmpty || region.contains(required),"region covers visible sampling area")
            let source=CaptureRegion.sourceRect(region,on:s)
            let reported=source.offsetBy(dx:displayBounds.minX,dy:displayBounds.minY)
            expect(CaptureRegion.globalRect(reported,on:s,displayBounds:displayBounds)==region,"frame coordinates round trip across screens")
        }
    }
}
expect(CaptureRegion.globalRect(CGRect(x:0,y:0,width:0,height:10),on:full,displayBounds:full)==nil,"reject empty metadata")
expect(CaptureRegion.globalRect(CGRect(x:10000,y:0,width:10,height:10),on:full,displayBounds:full)==nil,"reject offscreen metadata")
print("PASS: capture regions, motion guard bands, shrink, edge overflow and multi-screen coordinates")
for fps in [10,15,30] {
    expect(CaptureCadence.rate(preferred:fps,dragging:false)==fps,"saved background cadence")
    expect(CaptureCadence.rate(preferred:fps,dragging:true)==30,"drag uses full background cadence")
}
for fps in [-1,0,1,60,Int.max] {
    expect(CaptureCadence.normalized(fps)==10,"invalid background cadence uses bounded default")
}
print("PASS: background cadence choices, invalid preferences and drag override")
var adaptive=AdaptiveCaptureCadence()
expect(adaptive.rate(preferred:10,dragging:false,changed:false,now:0)==10,"initial capture starts promptly")
expect(adaptive.rate(preferred:10,dragging:false,changed:false,now:0.74)==10,"brief stillness retains cadence")
expect(adaptive.rate(preferred:10,dragging:false,changed:false,now:0.75)==2,"stable background keeps bounded live detection")
expect(adaptive.rate(preferred:10,dragging:false,changed:true,now:1)==10,"new pixels immediately restore cadence")
expect(adaptive.rate(preferred:10,dragging:true,changed:false,now:10)==30,"drag bypasses idle cadence")
expect(adaptive.rate(preferred:10,dragging:false,changed:false,now:10.1)==10,"release retains responsive cadence")
for fps in [15,30] {
    expect(adaptive.rate(preferred:fps,dragging:false,changed:false,now:20)==fps,"explicit cadence never idles")
}
adaptive.reset()
expect(adaptive.rate(preferred:10,dragging:false,changed:false,now:30)==10,"retarget resets adaptive state")
print("PASS: adaptive idle, change, drag, fixed-rate and reset policies")

// Codex tests: injected clocks, local fixtures and a fake probe only.
// Never start the desktop app or access the user's state file / debug endpoint.
var codexChecks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    codexChecks += 1
    expect(condition(), "Codex: " + name)
}
func snapshot(_ state: String, _ id: String? = nil, _ detail: String? = nil) -> CodexStateSnapshot {
    CodexStateSnapshot(state: state, detail: detail, eventID: id)
}
for title in ["ChatGPT", "Codex", "Another task", ""] {
    for path in ["/index.html", "/detached-window.html"] {
        let target = CodexCDPTarget(title: title, type: "page", url: "app://-\(path)?window=2",
                                   webSocketDebuggerUrl: "ws://127.0.0.1:9229/devtools/page/fixture")
        check(target.isCodexWindow && target.socketURL != nil, "window discovery ignores title: \(title)/\(path)")
    }
}
for address in ["https://example.com/index.html", "app://other/index.html", "app://-/index.html.untrusted", "app://-/browser.html"] {
    check(!CodexCDPTarget(title: "ChatGPT", type: "page", url: address, webSocketDebuggerUrl: nil).isCodexWindow,
          "reject unrelated target \(address)")
}
check(!CodexCDPTarget(title: "ChatGPT", type: "webview", url: "app://-/index.html", webSocketDebuggerUrl: nil).isCodexWindow,
      "exclude embedded visualizations")
let optionalTarget = try JSONDecoder().decode(CodexCDPTarget.self, from: Data(#"{"type":"page","url":"app://-/index.html"}"#.utf8))
check(optionalTarget.isCodexWindow && optionalTarget.socketURL == nil, "missing debug socket does not reject whole discovery response")
for address in ["ws://example.com:9229/page", "ws://127.0.0.1:9230/page", "https://127.0.0.1:9229/page", "ws://user@localhost:9229/page"] {
    check(CodexCDPTarget(title: nil, type: "page", url: "app://-/index.html", webSocketDebuggerUrl: address).socketURL == nil,
          "reject nonlocal or invalid socket \(address)")
}
for values in [["idle", "thinking"], ["thinking", "idle"], ["idle", "error", "command"], ["error", "thinking"]] {
    let combined = CodexDesktopObservation.combine(values.map { snapshot($0) }, incomplete: false)
    check(combined?.state == (values.contains("command") ? "command" : "thinking"), "busy window wins independent of discovery order")
}
check(CodexDesktopObservation.combine([snapshot("idle"), snapshot("idle")], incomplete: false)?.state == "idle", "all windows idle")
check(CodexDesktopObservation.combine([snapshot("idle")], incomplete: true) == nil, "incomplete coverage cannot claim all windows idle")
check(CodexDesktopObservation.combine([snapshot("thinking")], incomplete: true)?.state == "thinking", "unresponsive window cannot hide known work")
check(CodexDesktopObservation.combine([], incomplete: true) == nil, "all probes unavailable")
check(CodexDesktopObservation.combine([snapshot("complete")], incomplete: false) == nil, "DOM does not manufacture completion")

func desktopState(_ controls: [[String: Any]], busy: [[String: Any]] = []) throws -> String? {
    let context = JSContext()!
    let fixtures: [String: Any] = ["controls": controls, "busy": busy]
    let json = String(data: try JSONSerialization.data(withJSONObject: fixtures), encoding: .utf8)!
    context.evaluateScript("""
    const fixtures = \(json);
    const element = f => ({
      innerText: f.text || '',
      hidden: f.hidden || false,
      getAttribute: n => n === 'aria-label' ? (f.label || '') : null,
      getClientRects: () => f.detached ? [] : [1]
    });
    const document = {querySelectorAll: s => (s.startsWith('[aria-busy') ? fixtures.busy : fixtures.controls).map(element)};
    const getComputedStyle = e => ({visibility: e.hidden ? 'hidden' : 'visible', display: 'block'});
    """)
    let result = context.evaluateScript(CodexDesktopObservation.expression)?.toString()
    check(context.exception == nil, "DOM adapter executes with fixture elements")
    guard let result else { return nil }
    return try JSONDecoder().decode(CodexStateSnapshot.self, from: Data(result.utf8)).state
}
for label in ["停止", "Stop", "Stop responding", "Stop generating", "停止生成", "中止任务"] {
    check((try? desktopState([["label": label, "text": label]])) == "thinking", "localized and duplicate stop labels: \(label)")
}
check((try? desktopState([["label": "停止", "hidden": true]])) == "idle", "hidden controls do not imply work")
check((try? desktopState([], busy: [["hidden": true]])) == "idle", "hidden busy marker is ignored")
check((try? desktopState([], busy: [[:]])) == "thinking", "visible busy marker")
check((try? desktopState([["label": "Stop"], ["text": "Running command"]])) == "command", "running command while busy")

for state in CodexActivityState.allCases {
    var machine = CodexStateMachine()
    check(CodexActivityState(token: state.token) == state, "six-state token round trip \(state.token)")
    check(machine.accept(snapshot(state.token), source: .file, now: 0), "accept \(state.token)")
    check(machine.state == state, "map \(state.token) from idle")
}
check(CodexActivityState(token: "unknown") == nil, "reject unknown state")
var machine = CodexStateMachine()
machine.accept(snapshot("command"), source: .file, now: 0)
check(!machine.accept(snapshot("invalid"), source: .file, now: 0.1), "unknown observation is rejected")
check(machine.state == .command && machine.resultSerial == 0, "unknown does not invent idle/success")
machine.accept(snapshot("long"), source: .file, now: 0.2)
check(machine.state == .longTask && machine.resultSerial == 0, "command to explicit long is not completion")
check(machine.baseActivity == .command, "explicit long preserves prior command type")
machine.accept(snapshot("idle"), source: .file, now: 0.3)
check(machine.state == .idle && machine.resultSerial == 0, "busy to idle/cancel is not proof of success")

machine = CodexStateMachine()
for second in 0...30 { machine.accept(snapshot("command"), source: .desktop, now: Double(second)) }
check(machine.state == .longTask && machine.baseActivity == .command, "30-second long task keeps command metadata")
machine.unavailable()
check(machine.state == .idle && machine.resultSerial == 0, "disconnect neutralizes activity without success")
machine.accept(snapshot("command"), source: .desktop, now: 31)
check(machine.state == .command, "reconnection restarts the busy duration")
machine.advance(now: 34)
check(machine.state == .idle, "silent observation timeout")

machine = CodexStateMachine()
machine.accept(snapshot("complete", "done-1"), source: .file, now: 0)
check(machine.state == .complete && machine.resultSerial == 1, "explicit completion works from idle")
machine.accept(snapshot("idle"), source: .desktop, now: 1)
check(machine.state == .complete, "idle poll does not truncate completion")
machine.accept(snapshot("complete", "done-1", "changed detail"), source: .file, now: 1.3)
check(machine.completionDeadline == 1.4 && machine.resultSerial == 1, "duplicate does not extend or retrigger")
machine.advance(now: 1.4)
check(machine.state == .idle, "completion ends at its deadline")
machine.accept(snapshot("complete", "done-1"), source: .file, now: 2)
check(machine.state == .idle && machine.resultSerial == 1, "held result file does not replay after settling")
machine.accept(snapshot("complete", "done-2"), source: .file, now: 2.1)
check(machine.state == .complete && machine.resultSerial == 2, "new result ID is a new event")
machine.accept(snapshot("command"), source: .file, now: 2.2)
check(machine.state == .command && machine.completionDeadline == nil, "new task can interrupt old completion")
machine.accept(snapshot("error", "error-1"), source: .file, now: 2.3)
check(machine.state == .error && machine.resultSerial == 3, "error is explicit result")
machine.accept(snapshot("error", "error-1", "new words"), source: .file, now: 2.4)
check(machine.resultSerial == 3, "same error ID does not replay on detail change")
machine.accept(snapshot("error", "error-2"), source: .file, now: 2.5)
check(machine.resultSerial == 4, "distinct error ID works even in same state")
machine.unavailable()
machine.accept(snapshot("error", "error-2"), source: .file, now: 2.6)
check(machine.state == .idle && machine.resultSerial == 4, "disconnect cannot replay a consumed error")
machine = CodexStateMachine()
machine.accept(snapshot("error", nil, "first"), source: .desktop, now: 0)
machine.accept(snapshot("error", nil, "changed"), source: .desktop, now: 1)
check(machine.resultSerial == 1, "legacy/DOM result deduplicates by edge, not words")
machine.accept(snapshot("idle"), source: .desktop, now: 1.1)
machine.accept(snapshot("error"), source: .desktop, now: 1.2)
check(machine.resultSerial == 2, "new legacy error edge is accepted")
machine.unavailable()
machine.accept(snapshot("error"), source: .desktop, now: 1.3)
check(machine.resultSerial == 3, "legacy error after reconnect is a new edge")

check(CommandLine.arguments.count == 3, "test runner supplies fixture directory and CLI path")
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let cliPath = CommandLine.arguments[2]
try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
final class TestClock {
    var time: TimeInterval = 0
    let epoch = Date()
    var date: Date { epoch.addingTimeInterval(time) }
}
func writeFixture(_ url: URL, _ value: CodexStateSnapshot, modified: Date) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
}
let clock = TestClock()
let file = fixtures.appendingPathComponent("file-read/codex-state.json")
try writeFixture(file, snapshot("complete"), modified: clock.date)
let legacy = CodexStateFile.read(file, now: clock.date)
check(legacy?.state == "complete" && legacy?.eventID != nil, "legacy file gains stable event identity")
check(CodexStateFile.read(file, now: clock.date)?.eventID == legacy?.eventID, "same file yields same ID")
check(CodexStateFile.read(file, now: clock.date.addingTimeInterval(11.9)) != nil, "file fresh before TTL")
check(CodexStateFile.read(file, now: clock.date.addingTimeInterval(12)) == nil, "file expired at TTL")
check(CodexStateFile.read(file, now: clock.date.addingTimeInterval(-1)) == nil, "future mtime rejected")
try writeFixture(file, snapshot("invalid"), modified: clock.date)
check(CodexStateFile.read(file, now: clock.date) == nil, "unknown file token releases priority")
try Data("{broken".utf8).write(to: file, options: .atomic)
check(CodexStateFile.read(file, now: Date()) == nil, "corrupt file rejected")
try writeFixture(file, snapshot("command", nil, String(repeating: "x", count: 70000)), modified: clock.date)
check(CodexStateFile.read(file, now: clock.date) == nil, "oversized file rejected")
let oldFormat = Data("{\"state\":\"thinking\"}".utf8)
check((try? JSONDecoder().decode(CodexStateSnapshot.self, from: oldFormat))?.state == "thinking", "optional new fields preserve old format")

final class TestModel: CodexStateModel {
    var codexAuto = true
    var codexState: CodexActivityState = .idle
    var codexSource = ""
    var codexDetail = ""
    var codexPulse: Double = 0
    func setCodexState(_ next: CodexActivityState, source: String, detail: String) {
        if codexState != next && (next == .complete || next == .error) { codexPulse = 1 }
        codexState = next; codexSource = source; codexDetail = detail
    }
}
enum TestFailure: Error { case disconnected }
final class TestProbe: CodexStateProbing {
    var callbacks: [(Result<CodexStateSnapshot, Error>) -> Void] = []
    var cancellations = 0
    func poll(completion: @escaping (Result<CodexStateSnapshot, Error>) -> Void) { callbacks.append(completion) }
    func cancel() { cancellations += 1 }
    func succeed(_ index: Int, _ value: CodexStateSnapshot) { callbacks[index](.success(value)) }
    func fail(_ index: Int) { callbacks[index](.failure(TestFailure.disconnected)) }
}
func makeBridge(_ model: TestModel, _ probe: TestProbe, _ clock: TestClock, _ file: URL) -> CodexStateBridge {
    CodexStateBridge(model: model, stateFileURL: file, probe: probe, now: { clock.time }, wallNow: { clock.date })
}
// Fresh file priority, explicit complete, hold, expiration, and no replay across stop/start.
do {
    let c = TestClock(), m = TestModel(), probe = TestProbe()
    let f = fixtures.appendingPathComponent("bridge-file/codex-state.json")
    try writeFixture(f, snapshot("long"), modified: c.date)
    let bridge = makeBridge(m, probe, c, f)
    bridge.start(scheduleTimer: false)
    check(m.codexState == .longTask && m.codexPulse == 0, "bridge delivers long directly")
    check(probe.callbacks.isEmpty, "fresh file avoids network probing")
    c.time = 1
    try writeFixture(f, snapshot("complete", "result"), modified: c.date)
    bridge.poll()
    check(m.codexState == .complete && m.codexPulse == 1, "bridge delivers explicit completion")
    m.codexPulse = 0
    c.time = 2
    try writeFixture(f, snapshot("idle"), modified: c.date)
    bridge.poll()
    check(m.codexState == .complete, "bridge idle respects hold")
    c.time = 2.5; bridge.poll()
    check(m.codexState == .idle, "bridge hold settles")
    c.time = 3
    try writeFixture(f, snapshot("complete", "result"), modified: c.date)
    bridge.poll()
    check(m.codexState == .idle && m.codexPulse == 0, "result file not replayed")
    bridge.stop(); bridge.start(scheduleTimer: false)
    check(m.codexState == .idle && m.codexPulse == 0, "restart preserves result deduplication")
    c.time = 4
    try writeFixture(f, snapshot("complete", "new-result"), modified: c.date)
    bridge.poll()
    check(m.codexState == .complete && m.codexPulse == 1, "new result after restart works")
    m.codexPulse = 0
    c.time = 5
    try writeFixture(f, snapshot("complete", "another-result"), modified: c.date)
    bridge.poll()
    check(m.codexPulse == 1, "new explicit result retriggers existing signal in same state")
    bridge.stop()
}
// Expiry relinquishes busy state immediately; CDP failure never creates success.
do {
    let c = TestClock(), m = TestModel(), probe = TestProbe()
    let f = fixtures.appendingPathComponent("bridge-expiry/codex-state.json")
    try writeFixture(f, snapshot("command"), modified: c.date)
    let bridge = makeBridge(m, probe, c, f)
    bridge.start(scheduleTimer: false)
    for second in 1...11 { c.time = Double(second); bridge.poll() }
    check(m.codexState == .command, "fresh file maintains activity")
    c.time = 12; bridge.poll()
    check(m.codexState == .idle && probe.callbacks.count == 1, "expired file falls back neutrally")
    probe.fail(0)
    check(m.codexState == .idle && m.codexPulse == 0, "failed fallback cannot signal completion")
    c.time = 13; bridge.poll(); probe.succeed(1, snapshot("thinking"))
    check(m.codexState == .thinking && m.codexSource == CodexStateSource.desktop.rawValue, "fallback can recover")
    c.time = 14; bridge.poll(); probe.fail(2)
    check(m.codexState == .idle && m.codexPulse == 0, "CDP disconnect clears previous busy state")
    bridge.stop()
}
// Recheck a new file at callback time, including a response received before next poll.
do {
    let c = TestClock(), m = TestModel(), probe = TestProbe()
    let f = fixtures.appendingPathComponent("bridge-race/codex-state.json")
    let bridge = makeBridge(m, probe, c, f)
    bridge.start(scheduleTimer: false)
    c.time = 1; bridge.poll()
    check(probe.callbacks.count == 1, "only one probe in flight")
    try writeFixture(f, snapshot("command"), modified: c.date)
    probe.succeed(0, snapshot("complete", "stale-response"))
    check(m.codexState == .command && m.codexSource == CodexStateSource.file.rawValue && m.codexPulse == 0, "file appearing during probe wins")
    probe.fail(0)
    check(m.codexState == .command, "late failure cannot erase accepted file")
    bridge.stop()
}
// stop/restart and disabling auto invalidate every old callback.
do {
    let c = TestClock(), m = TestModel(), probe = TestProbe()
    let f = fixtures.appendingPathComponent("bridge-cancel/codex-state.json")
    let bridge = makeBridge(m, probe, c, f)
    bridge.start(scheduleTimer: false)
    bridge.stop()
    m.codexState = .command
    probe.succeed(0, snapshot("complete", "old"))
    check(m.codexState == .command && m.codexPulse == 0, "stop invalidates old response")
    bridge.start(scheduleTimer: false)
    probe.succeed(0, snapshot("error", "old-error"))
    check(m.codexState == .idle && m.codexPulse == 0, "restart generation rejects old response")
    probe.succeed(1, snapshot("thinking"))
    check(m.codexState == .thinking, "current response accepted")
    c.time = 1; bridge.poll()
    m.codexAuto = false; m.codexState = .command
    probe.succeed(2, snapshot("complete", "auto-off"))
    check(m.codexState == .command && m.codexPulse == 0, "auto off rejects pending result")
    bridge.stop()
}
// A hung fake simulates no callback at all; observation TTL still clears busy state.
do {
    let c = TestClock(), m = TestModel(), probe = TestProbe()
    let bridge = makeBridge(m, probe, c, fixtures.appendingPathComponent("bridge-timeout/codex-state.json"))
    bridge.start(scheduleTimer: false); probe.succeed(0, snapshot("command"))
    for second in 1...3 { c.time = Double(second); bridge.poll() }
    check(m.codexState == .idle && m.codexPulse == 0, "silent probe cannot leave activity stuck")
    probe.succeed(1, snapshot("not-a-state"))
    check(m.codexState == .idle && m.codexPulse == 0, "invalid CDP state is neutral, not complete")
    bridge.stop()
}

// Deliberate invisibility preserves task age and event identity, but cancels all work.
do {
    let c = TestClock(), m = TestModel(), probe = TestProbe()
    let bridge = makeBridge(m, probe, c, fixtures.appendingPathComponent("bridge-hidden/codex-state.json"))
    bridge.start(scheduleTimer: false)
    probe.succeed(0, snapshot("thinking"))
    c.time = 1; bridge.poll()
    bridge.pause()
    check(!bridge.isRunning && !bridge.hasScheduledTimer, "hidden bridge stops scheduling")
    c.time = 40; bridge.poll(); bridge.refresh()
    probe.succeed(1, snapshot("complete", "cancelled-hidden"))
    check(probe.callbacks.count == 2 && m.codexPulse == 0, "hidden bridge rejects callbacks and refresh")
    bridge.resume(scheduleTimer: false)
    let cancels = probe.cancellations
    bridge.restartIfNeeded(active: true)
    check(probe.cancellations == cancels && probe.callbacks.count == 3, "visible consumers do not restart an active probe")
    probe.succeed(2, snapshot("command"))
    check(m.codexState == .longTask, "show preserves task age across intentional pause")
    c.time = 41; bridge.poll(); probe.succeed(3, snapshot("error"))
    check(m.codexPulse == 1, "new visible error pulses")
    m.codexPulse = 0; bridge.pause()
    c.time = 80; bridge.resume(scheduleTimer: false)
    probe.succeed(4, snapshot("error"))
    check(m.codexPulse == 0, "same DOM error does not replay after hide/show")
    bridge.pause()
    c.time = 100; bridge.resume(scheduleTimer: false)
    c.time = 103; bridge.poll()
    check(m.codexState == .idle && m.codexPulse == 0, "show gives stale observations only bounded grace")
    bridge.stop()
}
do {
    let c = TestClock(), m = TestModel(), probe = TestProbe()
    let file = fixtures.appendingPathComponent("bridge-hidden-result/codex-state.json")
    try writeFixture(file, snapshot("complete", "hidden-result"), modified: c.date)
    let bridge = makeBridge(m, probe, c, file)
    bridge.start(scheduleTimer: false)
    m.codexPulse = 0; bridge.pause()
    c.time = 5; bridge.resume(scheduleTimer: false)
    check(m.codexState == .idle && m.codexPulse == 0, "expired completion settles without replay on show")
    bridge.stop()
}

// Endpoint failures back off, while the state file and explicit wake remain responsive.
do {
    let c = TestClock(), m = TestModel(), probe = TestProbe()
    let file = fixtures.appendingPathComponent("bridge-backoff/codex-state.json")
    let bridge = makeBridge(m, probe, c, file)
    bridge.start(scheduleTimer: false)
    for (index, delay) in [1.0, 2, 4, 8, 16, 30, 30].enumerated() {
        probe.fail(index)
        let deadline = c.time + delay
        c.time = deadline - 0.5; bridge.poll()
        check(probe.callbacks.count == index + 1, "failure backoff suppresses early batch \(index)")
        c.time = deadline; bridge.poll()
        check(probe.callbacks.count == index + 2, "failure backoff resumes bounded batch \(index)")
    }
    probe.fail(7)
    c.time += 1; bridge.refresh()
    check(probe.callbacks.count == 9, "process launch refresh bypasses failure backoff")
    probe.succeed(8, snapshot("thinking"))
    c.time += 1; bridge.poll()
    check(probe.callbacks.count == 10, "success restores normal cadence")
    probe.fail(9)
    c.time += 1; bridge.poll(); probe.fail(10)
    c.time += 0.5
    try writeFixture(file, snapshot("command"), modified: c.date)
    bridge.poll()
    check(m.codexState == .command && probe.callbacks.count == 11, "fresh file bypasses desktop backoff")
    bridge.stop()
}

// Exercise the real completion deadline and cancelled deadline on the main run loop.
// Unlike the deterministic reducer tests, neither bridge is polled to force settling.
do {
    let m = TestModel(), stopped = TestModel()
    let probe = TestProbe(), stoppedProbe = TestProbe()
    let f = fixtures.appendingPathComponent("real-deadline/codex-state.json")
    let stoppedFile = fixtures.appendingPathComponent("cancelled-deadline/codex-state.json")
    try writeFixture(f, snapshot("complete", "real-timer"), modified: Date())
    try writeFixture(stoppedFile, snapshot("complete", "cancelled-timer"), modified: Date())
    let bridge = CodexStateBridge(model: m, stateFileURL: f, probe: probe)
    let cancelled = CodexStateBridge(model: stopped, stateFileURL: stoppedFile, probe: stoppedProbe)
    bridge.start(scheduleTimer: false)
    cancelled.start(scheduleTimer: false)
    check(m.codexState == .complete && stopped.codexState == .complete, "real deadlines begin with completion")
    cancelled.stop()
    stopped.codexAuto = false
    stopped.setCodexState(.command, source: "手动预览", detail: "keep manual state")
    stopped.codexPulse = 0
    let end = Date().addingTimeInterval(CodexStateMachine.completionHold + 0.3)
    RunLoop.main.run(until: end)
    check(m.codexState == .idle, "scheduled deadline settles without another poll")
    check(stopped.codexState == .command && stopped.codexSource == "手动预览" && stopped.codexPulse == 0, "cancelled deadline cannot overwrite manual state")
    check(probe.callbacks.isEmpty && stoppedProbe.callbacks.isEmpty, "timer tests do not contact desktop endpoint")
    bridge.stop()
}

// CLI integration: exercise the real writer only in this run's isolated directory.
func runCLI(_ state: String, _ detail: String, directory: URL) throws -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [cliPath, state, detail]
    var env = ProcessInfo.processInfo.environment
    env["SINGULARITY_STATE_DIR"] = directory.path
    process.environment = env
    let out = Pipe(), err = Pipe()
    process.standardOutput = out; process.standardError = err
    try process.run()
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let errors = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output + errors, as: UTF8.self))
}
let cliDirectory = fixtures.appendingPathComponent("cli space 中文", isDirectory: true)
let cliFile = cliDirectory.appendingPathComponent("codex-state.json")
let specialDetail = "中文 \"quoted\" \\path\nnew line\rreturn\ttab\u{0008}backspace\u{0001}control"
var eventIDs = Set<String>()
for state in CodexActivityState.allCases {
    let result = try runCLI(state.token, specialDetail, directory: cliDirectory)
    check(result.0 == 0, "CLI accepts \(state.token): \(result.1)")
    let data = try Data(contentsOf: cliFile)
    let value = try JSONDecoder().decode(CodexStateSnapshot.self, from: data)
    check(value.state == state.token && value.detail == specialDetail, "CLI JSON control characters round trip")
    check(value.updatedAt != nil && value.eventID?.isEmpty == false, "CLI includes timestamp and event ID")
    check(eventIDs.insert(value.eventID!).inserted, "each CLI invocation has distinct ID")
    check(CodexStateFile.read(cliFile, now: Date()) != nil, "CLI output is consumable by bridge")
}
let beforeInvalid = try Data(contentsOf: cliFile)
let invalidResult = try runCLI("unknown", "", directory: cliDirectory)
check(invalidResult.0 == 2, "CLI rejects unknown state")
let afterInvalid = try Data(contentsOf: cliFile)
check(afterInvalid == beforeInvalid, "invalid CLI input preserves prior state")
let permissions = (try FileManager.default.attributesOfItem(atPath: cliFile.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
check(permissions & 0o077 == 0, "state file is private to current user")
print("PASS: \(codexChecks) Codex assertions (state machine, deadlines, replay, expiry, cancellation, source priority, JSON CLI)")
print("Fixtures: \(fixtures.path)")
