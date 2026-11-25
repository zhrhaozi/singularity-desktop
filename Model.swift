import Foundation
import Combine

final class Model: ObservableObject, CodexStateModel {
    @Published var size: Double = UserDefaults.standard.object(forKey: "size") as? Double ?? 440 { didSet { save(); appDelegate?.resizePet() } }
    @Published var bodyCount = max(1, min(3, UserDefaults.standard.object(forKey:"bodyCount") as? Int ?? 1)) {
        didSet { save(); appDelegate?.view?.resetOrbits(); appDelegate?.resizePet() }
    }
    @Published var orbitSpeed: Double = UserDefaults.standard.object(forKey:"orbitSpeed") as? Double ?? 0.65 {
        didSet { if !orbitSpeed.isFinite || !(0.1...1.5).contains(orbitSpeed) { orbitSpeed=0.65 }; save() }
    }
    @Published var systemDrift = UserDefaults.standard.object(forKey:"systemDrift") as? Bool ?? true {
        didSet { appDelegate?.view?.orbits?.driftEnabled=systemDrift; save() }
    }
    var sceneSize: Double { size * (bodyCount == 1 ? 1 : (bodyCount == 2 ? 1.75 : 1.9)) }
    @Published var lens: Double = UserDefaults.standard.object(forKey: "lens") as? Double ?? 13 { didSet { save() } }
    @Published var speed: Double = UserDefaults.standard.object(forKey: "speed") as? Double ?? 0.6 { didSet { save() } }
    @Published var brightness: Double = UserDefaults.standard.object(forKey: "brightness") as? Double ?? 2.2 { didSet { save() } }
    @Published var tilt: Double = UserDefaults.standard.object(forKey: "tilt") as? Double ?? 1.48 { didSet { save() } }
    @Published var roll: Double = UserDefaults.standard.object(forKey: "roll") as? Double ?? 0.18 { didSet { save() } }
    @Published var style: Int = UserDefaults.standard.integer(forKey:"style") { didSet { save() } }
    @Published var kind = UserDefaults.standard.integer(forKey:"kind") {didSet{save()}}
    @Published var spin = UserDefaults.standard.object(forKey:"spin") as? Double ?? 0.7 {didSet{save()}}
    @Published var charge = UserDefaults.standard.object(forKey:"charge") as? Double ?? 0.5 {didSet{save()}}
    @Published var mass = UserDefaults.standard.object(forKey:"mass") as? Double ?? 1.0 {didSet{save()}}
    @Published var wander = UserDefaults.standard.bool(forKey:"wander") {didSet{save();appDelegate?.savePosition()}}
    @Published var travelSpeed = UserDefaults.standard.object(forKey:"travelSpeed") as? Double ?? 35 {didSet{save()}}
    @Published var customColor = UserDefaults.standard.bool(forKey:"customColor") {didSet{save()}}
    @Published var colorHex = UserDefaults.standard.string(forKey:"colorHex") ?? "#FFAA55" {didSet{save()}}
    @Published var codexAuto = UserDefaults.standard.object(forKey:"codexAuto") as? Bool ?? true { didSet { save(); appDelegate?.restartCodexBridge() } }
    @Published var backgroundFPS = CaptureCadence.normalized(UserDefaults.standard.integer(forKey:"backgroundFPS")) {
        didSet {
            guard !RunMode.selfTest else{return}
            UserDefaults.standard.set(backgroundFPS,forKey:"backgroundFPS")
            appDelegate?.checkScreen()
        }
    }
    @Published var codexState: CodexActivityState = .idle
    @Published var codexSource = "等待 Codex 桌面状态"
    @Published var codexDetail = ""
    @Published var codexPulse: Double = 0
    var hasSpin:Bool {kind==1 || kind==3}
    var hasCharge:Bool {kind==2 || kind==3}
    var effectiveCharge:Double {hasCharge ? min(charge,sqrt(max(0,0.98*0.98-pow(hasSpin ? spin:0,2)))):0}
    @Published var paused = false {didSet{appDelegate?.view?.needsDisplay=true}}
    @Published var visible = true
    @Published var captureState = "尚未开启桌面透镜"
    @Published var capturing = false
    @Published var error = ""
    func save() { guard !RunMode.selfTest else {return};appDelegate?.view?.needsDisplay=true;let d=UserDefaults.standard; d.set(size,forKey:"size");d.set(bodyCount,forKey:"bodyCount");d.set(orbitSpeed,forKey:"orbitSpeed");d.set(systemDrift,forKey:"systemDrift");d.set(lens,forKey:"lens");d.set(speed,forKey:"speed");d.set(brightness,forKey:"brightness");d.set(tilt,forKey:"tilt");d.set(roll,forKey:"roll");d.set(style,forKey:"style");d.set(kind,forKey:"kind");d.set(spin,forKey:"spin");d.set(charge,forKey:"charge");d.set(mass,forKey:"mass");d.set(wander,forKey:"wander");d.set(travelSpeed,forKey:"travelSpeed");d.set(customColor,forKey:"customColor");d.set(colorHex,forKey:"colorHex");d.set(codexAuto,forKey:"codexAuto") }
    func setCodexState(_ next:CodexActivityState,_ source:String,_ detail:String="") {
        let changed = codexState != next
        codexState = next
        codexSource = source
        codexDetail = detail
        if changed {appDelegate?.view?.needsDisplay=true}
        if changed && (next == .complete || next == .error) { codexPulse = 1.0 }
    }
    func setCodexState(_ next:CodexActivityState, source:String, detail:String="") { setCodexState(next, source, detail) }
    func reset() { bodyCount=1;orbitSpeed=0.65;systemDrift=true;size=440;lens=13;speed=0.6;brightness=2.2;tilt=1.48;roll=0.18;style=0;kind=0;spin=0.7;charge=0.5;mass=1;wander=false;travelSpeed=35;customColor=false;colorHex="#FFAA55";codexAuto=true;backgroundFPS=10;setCodexState(.idle, source:"等待 Codex 桌面状态");appDelegate?.centerPet() }
}
