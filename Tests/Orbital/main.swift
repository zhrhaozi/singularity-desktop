import Foundation
import CoreGraphics
// Run with scripts/test-orbital.sh. No GPU, preferences or app process required.

var checks = 0
func expect(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { fputs("FAIL: " + name + "\n",stderr); exit(1) }
}

func allFinite(_ bodies: [OrbitalBody]) -> Bool {
    bodies.allSatisfy {
        $0.position.x.isFinite && $0.position.y.isFinite
            && $0.depth.isFinite && $0.encounter.isFinite && $0.impact.isFinite
    }
}

func maxRadius(_ bodies: [OrbitalBody]) -> Double {
    bodies.map { hypot($0.position.x, $0.position.y) }.max() ?? 0
}

func minSeparation(_ bodies: [OrbitalBody]) -> Double {
    var best = Double.greatestFiniteMagnitude
    for i in 0..<bodies.count {
        for j in (i + 1)..<bodies.count {
            let d = hypot(bodies[i].position.x - bodies[j].position.x,
                          bodies[i].position.y - bodies[j].position.y)
            best = min(best, d)
        }
    }
    return best
}

print("engine: Chipmunk2D \(String(cString:sg_orbit_engine()))")

// MARK: API shape and defaults

let defaultSystem = OrbitalSystem()
expect(defaultSystem.bodies.count == 2, "default init has two bodies")
expect(defaultSystem.bodies.map(\.id) == [0, 1], "ids are stable and 0-based")
expect(defaultSystem.bodies.allSatisfy { $0.radius == 0.42 }, "two-body quad scale is 0.42")

let threeSystem = OrbitalSystem(count: 3)
expect(threeSystem.bodies.count == 3, "count three yields three bodies")
expect(threeSystem.bodies.allSatisfy { $0.radius == 0.34 }, "three-body quad scale is 0.34")

for bad in [-5, 0, 1, 4, 7, Int.max] {
    expect(OrbitalSystem(count: bad).bodies.count == 2, "invalid count \(bad) falls back to two bodies")
}

// MARK: Initial state is bounded, finite and inside the scene box

for system in [OrbitalSystem(count: 2), OrbitalSystem(count: 3)] {
    expect(allFinite(system.bodies), "initial bodies are finite")
    expect(maxRadius(system.bodies) <= 0.45, "initial bodies are inside +/-0.45")
    expect(system.bodies.allSatisfy { $0.depth >= 0 && $0.depth <= 1 }, "initial depth in 0...1")
    expect(system.bodies.allSatisfy { $0.encounter >= 0 && $0.encounter <= 1 }, "initial encounter in 0...1")
    expect(minSeparation(system.bodies) > 0.0, "initial bodies do not coincide")
}

// MARK: dt zero and invalid inputs are strict no-ops

for system in [OrbitalSystem(count: 2), OrbitalSystem(count: 3)] {
    let before = system.bodies
    system.advance(dt: 0)
    expect(system.bodies == before, "dt zero changes nothing")
    system.advance(dt: -1)
    expect(system.bodies == before, "negative dt changes nothing")
    system.advance(dt: .nan)
    expect(system.bodies == before, "NaN dt changes nothing")
    system.advance(dt: .infinity)
    expect(system.bodies == before, "infinite dt changes nothing")
    system.advance(dt: 0, speed: 4)
    expect(system.bodies == before, "dt zero with speed changes nothing")
}

// MARK: Movement

func movedDistance(_ system: OrbitalSystem, frames: Int, dt: Double) -> Double {
    let start = system.bodies.map(\.position)
    for _ in 0..<frames { system.advance(dt: dt) }
    var moved = 0.0
    for (i, body) in system.bodies.enumerated() {
        moved += hypot(body.position.x - start[i].x, body.position.y - start[i].y)
    }
    return moved
}
expect(movedDistance(OrbitalSystem(count: 2), frames: 120, dt: 1.0 / 30) > 0.05, "two bodies move")
expect(movedDistance(OrbitalSystem(count: 3), frames: 120, dt: 1.0 / 30) > 0.05, "three bodies move")

// Every body moves (not just one).
do {
    let system = OrbitalSystem(count: 3)
    let start = system.bodies.map(\.position)
    var previous=start,path=[Double](repeating:0,count:3),excursion=path
    for _ in 0..<300 {
        system.advance(dt: 1.0 / 30)
        for (i,body) in system.bodies.enumerated() {
            path[i] += hypot(body.position.x-previous[i].x,body.position.y-previous[i].y)
            excursion[i]=max(excursion[i],hypot(body.position.x-start[i].x,body.position.y-start[i].y))
            previous[i]=body.position
        }
    }
    for i in 0..<3 {
        expect(path[i]>0.2 && excursion[i]>0.03,"body \(i) of three travels, even when an orbit returns near its start")
    }
}

// MARK: Speed control

do {
    func pathLength(count: Int, frames: Int, speed: Double) -> Double {
        let system = OrbitalSystem(count: count)
        var previous = system.bodies.map(\.position)
        var total = 0.0
        for _ in 0..<frames {
            system.advance(dt: 1.0 / 30, speed: speed)
            for (i, body) in system.bodies.enumerated() {
                total += hypot(body.position.x - previous[i].x, body.position.y - previous[i].y)
            }
            previous = system.bodies.map(\.position)
        }
        return total
    }
    let slowMoved = pathLength(count: 3, frames: 600, speed: 1)
    let fastMoved = pathLength(count: 3, frames: 600, speed: 2)
    expect(fastMoved > slowMoved, "double speed travels farther in the same wall time")

    // speed 2 for 600 frames should match speed 1 for 1200 frames (same sim time).
    let a = OrbitalSystem(count: 2)
    let b = OrbitalSystem(count: 2)
    for _ in 0..<600 { a.advance(dt: 1.0 / 30, speed: 2) }
    for _ in 0..<1200 { b.advance(dt: 1.0 / 30, speed: 1) }
    for (x, y) in zip(a.bodies, b.bodies) {
        expect(hypot(x.position.x - y.position.x, x.position.y - y.position.y) < 1e-9,
               "speed scales simulated time deterministically")
    }

    // zero speed freezes; non-finite speed behaves like 1.
    let frozen = OrbitalSystem(count: 3)
    let frozenBefore = frozen.bodies
    for _ in 0..<60 { frozen.advance(dt: 1.0 / 30, speed: 0) }
    expect(frozen.bodies == frozenBefore, "zero speed freezes the system")
    let nanSpeed = OrbitalSystem(count: 3)
    let speedOne = OrbitalSystem(count: 3)
    for _ in 0..<120 {
        nanSpeed.advance(dt: 1.0 / 30, speed: .nan)
        speedOne.advance(dt: 1.0 / 30, speed: 1)
    }
    expect(nanSpeed.bodies == speedOne.bodies, "non-finite speed falls back to 1")
}

// MARK: Determinism and reset

do {
    let moving = OrbitalSystem(count: 3), fixed = OrbitalSystem(count: 3)
    fixed.driftEnabled = false
    for _ in 0..<180 { moving.advance(dt: 1.0/30); fixed.advance(dt: 1.0/30) }
    expect(hypot(moving.driftOffset.x,moving.driftOffset.y)>0.01,"system drift is visible")
    for (a,b) in zip(moving.bodies,fixed.bodies) {
        expect(abs(a.position.x-b.position.x-moving.driftOffset.x)<1e-9,"shared x drift preserves relative dynamics")
        expect(abs(a.position.y-b.position.y-moving.driftOffset.y)<1e-9,"shared y drift preserves relative dynamics")
    }
    moving.driftEnabled = false
    expect(moving.bodies==fixed.bodies,"disabling drift restores physical positions without resetting")
}

func advance(_ system: OrbitalSystem, _ sequence: [Double]) {
    for dt in sequence { system.advance(dt: dt) }
}
let dtSequence: [Double] = [1.0 / 30, 1.0 / 60, 0.05, 1.0 / 15, 1.0 / 30, 0.02, 1.0 / 120]
for count in [2, 3] {
    let a = OrbitalSystem(count: count)
    let b = OrbitalSystem(count: count)
    for _ in 0..<50 { advance(a, dtSequence); advance(b, dtSequence) }
    expect(a.bodies == b.bodies, "two instances with identical \(count)-body call sequences match")
    for _ in 0..<50 { b.advance(dt: 0.2) }
    b.reset(count: count)
    expect(b.bodies == OrbitalSystem(count: count).bodies, "reset(\(count)) reproduces the seeded state")
}

do {
    let system = OrbitalSystem(count: 3)
    for _ in 0..<200 { system.advance(dt: 1.0 / 30) }
    system.reset(count: 2)
    expect(system.bodies.count == 2, "reset can change the body count")
    expect(system.bodies == OrbitalSystem(count: 2).bodies, "reset to two bodies is deterministic")
    system.reset(count: 3)
    expect(system.bodies == OrbitalSystem(count: 3).bodies, "reset back to three bodies is deterministic")
}

// MARK: Long-run boundedness, finiteness, no overlap, close approaches

func longRun(count: Int, frames: Int, dt: Double, label: String) -> (Double, Double, Double) {
    let system = OrbitalSystem(count: count)
    var minSep = Double.greatestFiniteMagnitude
    var maxSep = 0.0
    var maxEnc = 0.0
    var minEnc = 1.0
    let limit = OrbitalTuning.centreLimit(for: count)
    for frame in 0..<frames {
        // Include dt zero and a wake-sized dt to exercise clamping.
        let step: Double
        if frame % 5000 == 4999 { step = 0 }
        else if frame % 7000 == 6999 { step = 5.0 }
        else { step = dt }
        system.advance(dt: step)
        let bodies = system.bodies
        expect(allFinite(bodies), "\(label) bodies stay finite")
        let physicalRadius=bodies.map {hypot($0.position.x-system.driftOffset.x,$0.position.y-system.driftOffset.y)}.max() ?? 0
        expect(physicalRadius <= limit + 1e-6, "\(label) centers stay within the containment radius")
        expect(bodies.allSatisfy { abs($0.position.x) <= 0.45 && abs($0.position.y) <= 0.45 },
               "\(label) centers stay inside +/-0.45")
        expect(bodies.allSatisfy { $0.depth >= 0 && $0.depth <= 1 }, "\(label) depth in 0...1")
        expect(bodies.allSatisfy { $0.encounter >= 0 && $0.encounter <= 1 }, "\(label) encounter in 0...1")
        minSep = min(minSep, minSeparation(bodies))
        maxSep = max(maxSep, maxSeparation(bodies))
        for body in bodies { maxEnc = max(maxEnc, body.encounter); minEnc = min(minEnc, body.encounter) }
    }
    expect(system.collisions>0,"\(label) includes real collision contacts")
    print(String(format: "%@: frames=%d minSep=%.4f maxSep=%.4f encounter=[%.2f..%.2f] collisions=%llu",
                 label, frames, minSep, maxSep, minEnc, maxEnc, system.collisions))
    return (minSep, maxSep, maxEnc)
}

func maxSeparation(_ bodies: [OrbitalBody]) -> Double {
    var best = 0.0
    for i in 0..<bodies.count {
        for j in (i + 1)..<bodies.count {
            best = max(best, hypot(bodies[i].position.x - bodies[j].position.x,
                                   bodies[i].position.y - bodies[j].position.y))
        }
    }
    return best
}

let twoResult = longRun(count: 2, frames: 30 * 3600, dt: 1.0 / 30, label: "two-body 1h")
expect(twoResult.0 > 0.02, "two bodies never permanently overlap")
expect(twoResult.1 > 0.05, "two bodies actually separate")
expect(twoResult.2 > 0.5, "two-body close approach is detected by encounter")

let threeResult = longRun(count: 3, frames: 30 * 3600, dt: 1.0 / 30, label: "three-body 1h")
expect(threeResult.0 > 0.02, "three bodies never permanently overlap")
expect(threeResult.1 > 0.05, "three bodies actually separate")
expect(threeResult.2 > 0.5, "three-body close approach is detected by encounter")

// MARK: Smooth depth and encounter (no per-frame jumps)

do {
    let system = OrbitalSystem(count: 3)
    var previous = system.bodies
    var maxDepthJump = 0.0
    var maxEncJump = 0.0
    for _ in 0..<(30 * 600) {
        system.advance(dt: 1.0 / 30)
        for body in system.bodies {
            let old = previous[body.id]
            maxDepthJump = max(maxDepthJump, abs(body.depth - old.depth))
            maxEncJump = max(maxEncJump, abs(body.encounter - old.encounter))
        }
        previous = system.bodies
    }
    expect(maxDepthJump < 0.05, "depth varies smoothly frame to frame")
    expect(maxEncJump < 0.30, "encounter varies smoothly frame to frame")
    print(String(format: "smoothness: maxDepthJump/frame=%.4f maxEncounterJump/frame=%.4f",
                 maxDepthJump, maxEncJump))
}

// MARK: Wake / bounded steps

do {
    let system = OrbitalSystem(count: 3)
    for _ in 0..<100 { system.advance(dt: 1.0 / 30) }
    let before = system.bodies
    system.advance(dt: 1e9)                                 // simulated "wake after long stall"
    expect(allFinite(system.bodies), "huge dt stays finite")
    expect(maxRadius(system.bodies) <= 0.45 + 1e-6, "huge dt stays bounded")
    let jump = zip(system.bodies, before).reduce(0.0) {
        $0 + hypot($1.0.position.x - $1.1.position.x, $1.0.position.y - $1.1.position.y)
    }
    expect(jump < 1.0, "huge dt advances at most a bounded number of substeps (no teleport)")
    // A very large speed is clamped and must not hang or explode.
    system.advance(dt: 1.0 / 30, speed: 1e9)
    expect(allFinite(system.bodies) && maxRadius(system.bodies) <= 0.45 + 1e-6,
           "huge speed is clamped and stays bounded")
}

print("PASS (\(checks) checks): OrbitalSystem 2/3-body motion, determinism, reset, dt0/invalid, speed, bounds")
