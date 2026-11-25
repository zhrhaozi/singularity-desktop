import Foundation
import Combine

/// Publishes values after a validated load. UI/renderer side effects belong to the coordinator.
final class Model: ObservableObject, CodexStateModel {
    enum Change { case redraw, size, bodyCount, drift, position, cadence, codexMode }
    var onChange: ((Change) -> Void)?
    private let defaults: UserDefaults?
    private var pending: [String: Any] = [:]
    private var saveWork: DispatchWorkItem?

    @Published var size = SettingsSpec.size.initial {
        didSet { changed("size", size, from: oldValue, .size) }
    }
    @Published var bodyCount = SettingsSpec.bodyCount.initial {
        didSet { changed("bodyCount", bodyCount, from: oldValue, .bodyCount) }
    }
    @Published var orbitSpeed = SettingsSpec.orbitSpeed.initial {
        didSet { changed("orbitSpeed", orbitSpeed, from: oldValue, .redraw) }
    }
    @Published var lens = SettingsSpec.lens.initial {
        didSet { changed("lens", lens, from: oldValue, .redraw) }
    }
    @Published var speed = SettingsSpec.speed.initial {
        didSet { changed("speed", speed, from: oldValue, .redraw) }
    }
    @Published var brightness = SettingsSpec.brightness.initial {
        didSet { changed("brightness", brightness, from: oldValue, .redraw) }
    }
    @Published var tilt = SettingsSpec.tilt.initial {
        didSet { changed("tilt", tilt, from: oldValue, .redraw) }
    }
    @Published var roll = SettingsSpec.roll.initial {
        didSet { changed("roll", roll, from: oldValue, .redraw) }
    }
    @Published var style = SettingsSpec.style.initial {
        didSet { changed("style", style, from: oldValue, .redraw) }
    }
    @Published var kind = SettingsSpec.kind.initial {
        didSet { changed("kind", kind, from: oldValue, .redraw) }
    }
    @Published var spin = SettingsSpec.spin.initial {
        didSet { changed("spin", spin, from: oldValue, .redraw) }
    }
    @Published var charge = SettingsSpec.charge.initial {
        didSet { changed("charge", charge, from: oldValue, .redraw) }
    }
    @Published var mass = SettingsSpec.mass.initial {
        didSet { changed("mass", mass, from: oldValue, .redraw) }
    }
    @Published var travelSpeed = SettingsSpec.travelSpeed.initial {
        didSet { changed("travelSpeed", travelSpeed, from: oldValue, .redraw) }
    }
    @Published var systemDrift = true {
        didSet { changed("systemDrift", systemDrift, from: oldValue, .drift) }
    }
    @Published var wander = false {
        didSet { changed("wander", wander, from: oldValue, .position) }
    }
    @Published var customColor = false {
        didSet { changed("customColor", customColor, from: oldValue, .redraw) }
    }
    @Published var backgroundFPS = 10 {
        didSet { changed("backgroundFPS", backgroundFPS, from: oldValue, .cadence) }
    }
    @Published var codexMode = CodexLinkMode.file {
        didSet { changed("codexLinkMode", codexMode.rawValue, from: oldValue.rawValue, .codexMode) }
    }
    @Published private(set) var customRGB = RGB.amber
    var colorHex: String {
        get { customRGB.hex }
        set {
            guard let color = RGB(hex: newValue), color != customRGB else { return }
            let oldHex = customRGB.hex
            customRGB = color
            changed("colorHex", color.hex, from: oldHex, .redraw)
        }
    }
    @Published var codexState: CodexActivityState = .idle
    @Published var codexSource = CodexLinkMode.file.waitingLabel
    @Published var codexDetail = ""
    @Published var codexPulse: Double = 0
    @Published var paused = false { didSet { onChange?(.redraw) } }
    @Published var visible = true
    @Published var captureState = "尚未开启桌面透镜"
    @Published var capturing = false
    @Published var error = "" // Screen-capture lifecycle only.
    @Published var rendererError = "" // Must survive capture-state updates.

    var sceneSize: Double { size * (bodyCount == 1 ? 1 : (bodyCount == 2 ? 1.75 : 1.9)) }
    var hasSpin: Bool { kind == 1 || kind == 3 }
    var hasCharge: Bool { kind == 2 || kind == 3 }
    var effectiveCharge: Double {
        hasCharge ? min(charge, sqrt(max(0, 0.98 * 0.98 - pow(hasSpin ? spin : 0, 2)))) : 0
    }

    /// Passing nil constructs a completely isolated, non-persisting model for self-tests.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let reader = PreferenceReader(defaults: defaults)
        size = reader.value(SettingsSpec.size)
        bodyCount = reader.value(SettingsSpec.bodyCount)
        orbitSpeed = reader.value(SettingsSpec.orbitSpeed)
        lens = reader.value(SettingsSpec.lens)
        speed = reader.value(SettingsSpec.speed)
        brightness = reader.value(SettingsSpec.brightness)
        tilt = reader.value(SettingsSpec.tilt)
        roll = reader.value(SettingsSpec.roll)
        style = reader.value(SettingsSpec.style)
        kind = reader.value(SettingsSpec.kind)
        spin = reader.value(SettingsSpec.spin)
        charge = reader.value(SettingsSpec.charge)
        mass = reader.value(SettingsSpec.mass)
        travelSpeed = reader.value(SettingsSpec.travelSpeed)
        systemDrift = reader.flag("systemDrift", fallback: true)
        wander = reader.flag("wander")
        customColor = reader.flag("customColor")
        backgroundFPS = CaptureCadence.normalized(reader.finite("backgroundFPS").flatMap(Int.init(exactly:)) ?? 10)
        codexMode = defaults.map(CodexLinkMode.restored(from:)) ?? .file
        codexSource = codexMode.waitingLabel
        customRGB = defaults?.string(forKey: "colorHex").flatMap(RGB.init(hex:)) ?? .amber
    }

    private func changed<T: Equatable>(_ key: String, _ value: T, from oldValue: T, _ effect: Change) {
        guard value != oldValue else { return }
        if defaults != nil {
            pending[key] = value
            saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.flushPreferences() }
            saveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
        }
        onChange?(effect)
    }

    func flushPreferences() {
        saveWork?.cancel(); saveWork = nil
        for (key, value) in pending { defaults?.set(value, forKey: key) }
        pending.removeAll(keepingCapacity: true)
    }

    func setCodexState(_ next: CodexActivityState, source: String, detail: String = "") {
        let changed = codexState != next
        codexState = next; codexSource = source; codexDetail = detail
        if changed {
            onChange?(.redraw)
            if next == .complete || next == .error { codexPulse = 1 }
        }
    }

    func reset() {
        size = SettingsSpec.size.initial
        bodyCount = SettingsSpec.bodyCount.initial
        orbitSpeed = SettingsSpec.orbitSpeed.initial
        lens = SettingsSpec.lens.initial
        speed = SettingsSpec.speed.initial
        brightness = SettingsSpec.brightness.initial
        tilt = SettingsSpec.tilt.initial
        roll = SettingsSpec.roll.initial
        style = SettingsSpec.style.initial
        kind = SettingsSpec.kind.initial
        spin = SettingsSpec.spin.initial
        charge = SettingsSpec.charge.initial
        mass = SettingsSpec.mass.initial
        travelSpeed = SettingsSpec.travelSpeed.initial
        systemDrift = true; wander = false; customColor = false; colorHex = RGB.amber.hex
        backgroundFPS = 10; paused = false; codexPulse = 0
        codexMode = .file
        setCodexState(.idle, source: codexMode.waitingLabel)
        // A deliberate reset also clears invalid stored values that already displayed their fallback.
        saveWork?.cancel(); saveWork = nil; pending.removeAll()
        for key in ["size", "lens", "speed", "brightness", "tilt", "roll", "spin", "charge", "mass", "travelSpeed",
                    "orbitSpeed", "bodyCount", "kind", "style", "systemDrift", "wander", "customColor", "colorHex",
                    "backgroundFPS", "codexAuto", "codexLinkMode"] { defaults?.removeObject(forKey: key) }
    }
}
