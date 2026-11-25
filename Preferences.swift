import Foundation
import CoreFoundation

/// The controls and the preferences reader share the same units, limits and defaults.
struct NumericSetting<T: Comparable> {
    let key: String
    let range: ClosedRange<T>
    let initial: T
    init(_ key: String, _ range: ClosedRange<T>, _ initial: T) {
        self.key = key; self.range = range; self.initial = initial
    }
}

enum SettingsSpec {
    static let size = NumericSetting<Double>("size", 280...700, 440)
    static let lens = NumericSetting<Double>("lens", 3...24, 13)
    static let speed = NumericSetting<Double>("speed", 0.1...1.8, 0.6)
    static let brightness = NumericSetting<Double>("brightness", 0.3...3.5, 2.2)
    static let tilt = NumericSetting<Double>("tilt", 0.2...1.56, 1.48)
    static let roll = NumericSetting<Double>("roll", -0.8...0.8, 0.18)
    static let spin = NumericSetting<Double>("spin", -0.95...0.95, 0.7)
    static let charge = NumericSetting<Double>("charge", 0...0.95, 0.5)
    static let mass = NumericSetting<Double>("mass", 0.65...1.35, 1.0)
    static let travelSpeed = NumericSetting<Double>("travelSpeed", 5...180, 35)
    static let orbitSpeed = NumericSetting<Double>("orbitSpeed", 0.1...1.5, 0.65)
    static let bodyCount = NumericSetting<Int>("bodyCount", 1...3, 1)
    static let style = NumericSetting<Int>("style", 0...3, 0)
    static let kind = NumericSetting<Int>("kind", 0...3, 0)
}

struct PreferenceReader {
    let defaults: UserDefaults?

    func finite(_ key: String) -> Double? {
        guard let n = defaults?.object(forKey: key) as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    func value(_ spec: NumericSetting<Double>) -> Double {
        guard let v = finite(spec.key), spec.range.contains(v) else { return spec.initial }
        return v
    }
    func value(_ spec: NumericSetting<Int>) -> Int {
        guard let n = finite(spec.key), let v = Int(exactly: n), spec.range.contains(v) else { return spec.initial }
        return v
    }
    func flag(_ key: String, fallback: Bool = false) -> Bool {
        guard let n = defaults?.object(forKey: key) as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return fallback }
        return n.boolValue
    }
    func coordinate(_ key: String) -> Double? {
        guard let n = finite(key), abs(n) < 10_000_000 else { return nil }
        return n // Negative values are valid on secondary displays.
    }
}
