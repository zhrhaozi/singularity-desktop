import Foundation
import CoreGraphics

// Chipmunk2D advances bodies and resolves core collisions at fixed substeps.
// Softened pairwise gravity, a central containment force, and a safety boundary
// produce controlled near-misses for a desktop animation, not a GR simulation.

/// One body of the orbital system, in normalised centred scene units.
struct OrbitalBody: Equatable {
    /// Stable index of the body within the system (0-based).
    let id: Int
    /// Centre position in normalised units, roughly -0.3...0.3 on each axis.
    let position: CGPoint
    /// Local quad size scale: 0.42 for two bodies, 0.34 for three.
    let radius: Double
    /// Smooth compositor ordering hint in 0...1 (0 = behind, 1 = front).
    let depth: Double
    /// Smooth closeness hint in 0...1 (1 = closest approach to a neighbour).
    let encounter: Double
    /// Decaying impulse from an actual core collision, not a proximity estimate.
    let impact: Double
}

/// Tunable, documented constants for the orbital simulation.
enum OrbitalTuning {
    /// Fixed physics substep in seconds. Motion is always advanced in whole
    /// substeps of this size so results do not depend on the caller's frame
    /// cadence.
    static let fixedStep: Double = 1.0 / 120.0
    /// Largest frame delta accepted per `advance` call (clamped after wake).
    static let maxFrameDt: Double = 0.1
    /// Largest number of substeps advanced per `advance` call. A stalled or
    /// woken app can therefore never simulate an unbounded jump at once.
    static let maxSubsteps: Int = 16
    /// Largest accepted `speed` multiplier.
    static let maxSpeedScale: Double = 4.0

    /// Half-extent of the common scene box including silhouettes.
    static let containmentExtent: Double = 0.45
    /// Assumed silhouette half extent as a fraction of `radius`. The compositor
    /// maps `radius` (a scale) to a real quad; this documents the mapping this
    /// module assumes when reserving the containment box.
    static let silhouetteFactor: Double = 0.35

    /// Pairwise gravity strength.
    ///
    /// * Two bodies: strong enough that the pair is gravity dominated, so the
    ///   two bodies genuinely orbit *each other* and sweep through a periodic
    ///   close approach.
    /// * Three bodies: weaker attraction with a counter-orbiting member;
    ///   close approaches are resolved by repulsion and core collisions.
    static func gravity(for count: Int) -> Double { count == 3 ? 0.004 : 0.05 }
    /// Gravity softening length (removes the inverse-square singularity).
    static func softening(for count: Int) -> Double { count == 3 ? 0.02 : 0.03 }
    /// Distance at which short-range repulsion starts.
    static func repelRange(for count: Int) -> Double { count == 3 ? 0.075 : 0.085 }
    /// Strength of the short-range repulsion (soft anti-overlap core).
    static let repelStrength: Double = 25.0
    /// Artistic external radial field: a gentle harmonic pull toward the scene
    /// centre (a = -trapStrength * r) acting on every body. This is deliberate
    /// staging, not an isolated gravitational system. The safety wall supplies
    /// the hard position bound.
    static func trapStrength(for count: Int) -> Double { count == 3 ? 3.0 : 2.5 }
    /// Restitution of the hard safety wall (artistic containment).
    static let wallRestitution: Double = 0.4
    /// Velocity clamp as a final safety net against fly-away.
    static let maxSpeed: Double = 2.0
    /// No extra velocity damping; collisions and safety clamps can lose energy.
    static let damping: Double = 0.0

    /// Ratio of the launch speed to the local circular speed. Below 1 makes the
    /// initial orbit eccentric; mutual forces and collisions then perturb it.
    static func speedFactor(for count: Int) -> Double { count == 3 ? 0.88 : 0.66 }
    /// Launch ring radii per body count. Two bodies start on nearly the same
    /// ring, on opposite sides of the shared centre, so they orbit each other.
    /// Three bodies start at different radii and angular positions.
    static func launchRadii(for count: Int) -> [Double] {
        count == 3 ? [0.160, 0.190, 0.220] : [0.130, 0.135]
    }
    /// Seeded asymmetry applied to the launch ring (breaks the perfect
    /// mirror symmetry so the bodies are not locked diametrically opposite).
    static let launchJitter: Double = 0.06
    /// Start two bodies opposite one another and three bodies 120 degrees apart.
    static func launchAngleSpread(for count: Int) -> Double { count == 3 ? Double.pi * 2 / 3 : Double.pi }

    /// Separation mapped to `encounter` == 1.
    static let closeApproach: Double = 0.11
    /// Separation mapped to `encounter` == 0.
    static let nearRange: Double = 0.26
    /// Low-pass rate for the smooth `encounter` hint (per second).
    static let encounterRate: Double = 5.0
    /// Period in seconds of the smooth `depth` oscillation.
    static let depthPeriod: Double = 7.0
    static let driftAmplitude: Double = 0.025

    /// Supported body counts.
    static func supported(_ count: Int) -> Int { (count == 3) ? 3 : 2 }
    /// Local quad scale for a body count.
    static func radius(for count: Int) -> Double { count == 3 ? 0.34 : 0.42 }
    /// Hard radial position clamp (keeps silhouettes inside the scene box).
    static func centreLimit(for count: Int) -> Double {
        containmentExtent - radius(for: count) * silhouetteFactor
    }
}

/// Deterministic, seeded pseudo random generator (SplitMix64) used only to
/// break symmetry on reset; never called during `advance`.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform value in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    /// Uniform value in [-1, 1).
    mutating func signed() -> Double { unit() * 2.0 - 1.0 }
}

/// Drives the deterministic multi-body motion for the desktop pet.
final class OrbitalSystem {
    // MARK: Public interface

    /// The bodies in stable id order.
    private(set) var bodies: [OrbitalBody]
    var driftEnabled = true { didSet { bodies = makeBodies() } }
    var collisions: UInt64 { sg_orbit_collisions(physics) }
    var driftOffset: CGPoint {
        guard driftEnabled else { return .zero }
        return CGPoint(x: OrbitalTuning.driftAmplitude * sin(simTime * 0.31),
                       y: OrbitalTuning.driftAmplitude * 0.7 * sin(simTime * 0.47))
    }

    /// Creates a system with `count` bodies (2 or 3; anything else clamps to 2).
    init(count: Int = 2) {
        self.bodies = []
        reset(count: count)
    }
    deinit { sg_orbit_destroy(physics) }

    /// Rebuilds the system from the fixed seed. Resetting to the same `count`
    /// always reproduces the identical initial state.
    func reset(count: Int) {
        let n = OrbitalTuning.supported(count)
        var rng = SplitMix64(seed: Self.baseSeed)
        particles = Self.makeParticles(count: n, rng: &rng)
        sg_orbit_destroy(physics)
        physics=sg_orbit_create(Int32(n))
        precondition(physics != nil,"Chipmunk2D world allocation")
        sg_orbit_configure(physics,OrbitalTuning.gravity(for:n),OrbitalTuning.softening(for:n),
                           OrbitalTuning.repelRange(for:n),OrbitalTuning.repelStrength,OrbitalTuning.trapStrength(for:n))
        for (index,p) in particles.enumerated() {
            sg_orbit_set_state(physics,Int32(index),SGOrbitState(x:p.x,y:p.y,vx:p.vx,vy:p.vy))
        }
        accumulator = 0
        simTime = 0
        bodies = makeBodies()
    }

    /// Advances the simulation by `dt` seconds scaled by `speed`.
    ///
    /// * `dt <= 0`, NaN or infinite produces no change at all.
    /// * `dt` is clamped to `OrbitalTuning.maxFrameDt` and at most
    ///   `OrbitalTuning.maxSubsteps` fixed substeps are taken, so a stalled
    ///   and later woken app can never jump.
    /// * Non-finite `speed` falls back to 1; `speed` is clamped to
    ///   0...`maxSpeedScale`; a zero speed freezes the system.
    func advance(dt: Double, speed: Double = 1) {
        guard dt.isFinite, dt > 0 else { return }          // zero/invalid dt: no change
        let rawSpeed = speed.isFinite ? speed : 1
        let scale = min(max(rawSpeed, 0), OrbitalTuning.maxSpeedScale)
        guard scale > 0 else { return }                    // frozen

        accumulator += min(dt, OrbitalTuning.maxFrameDt) * scale
        var steps = 0
        while accumulator >= OrbitalTuning.fixedStep, steps < OrbitalTuning.maxSubsteps {
            substep(OrbitalTuning.fixedStep)
            accumulator -= OrbitalTuning.fixedStep
            steps += 1
        }
        if steps >= OrbitalTuning.maxSubsteps {
            // Drop any backlog so a long wake cannot store unbounded debt.
            accumulator = min(accumulator, OrbitalTuning.fixedStep)
        }
        bodies = makeBodies()
    }

    // MARK: Private state

    private struct Particle {
        var x: Double
        var y: Double
        var vx: Double
        var vy: Double
        let mass: Double
        let phase: Double
        var encounter: Double
    }

    private static let baseSeed: UInt64 = 0x5EED_0B17_A1C0_FFEE
    private var particles: [Particle] = []
    private var accumulator: Double = 0
    private var simTime: Double = 0
    private var physics: OpaquePointer?

    // MARK: Initial conditions

    private static func makeParticles(count: Int, rng: inout SplitMix64) -> [Particle] {
        // Seeded asymmetry keeps resets reproducible without exact symmetry.
        let masses = [Double](repeating: 1.0, count: count)
        let radii = OrbitalTuning.launchRadii(for: count)
        let spread = OrbitalTuning.launchAngleSpread(for: count)
        var result: [Particle] = []
        for i in 0..<count {
            let angle = Double(i) * spread + rng.signed() * OrbitalTuning.launchJitter
            let radius = radii[i] * (1.0 + rng.signed() * OrbitalTuning.launchJitter)
            result.append(Particle(x: cos(angle) * radius, y: sin(angle) * radius,
                                   vx: 0, vy: 0, mass: masses[i],
                                   phase: rng.unit() * 2.0 * Double.pi, encounter: 0))
        }
        // Circular speed from the real acceleration (radial field + gravity),
        // then scaled below 1 for a bound elliptical rosette.
        let (ax, ay) = accelerations(result)
        for i in result.indices {
            let x = result[i].x, y = result[i].y
            let r = max(sqrt(x * x + y * y), 1e-6)
            let rhatX = x / r, rhatY = y / r
            let inward = -(ax[i] * rhatX + ay[i] * rhatY)
            let circular = sqrt(max(inward, 0) * r)
            let v = circular * OrbitalTuning.speedFactor(for: count) * (1.0 + rng.signed() * OrbitalTuning.launchJitter)
            // One counter-orbiting member produces conjunctions in triple mode.
            let radial = rng.signed() * 0.05 * circular
            let direction = count==3 && i==2 ? -0.85 : 1.0
            result[i].vx = -rhatY * v * direction + radial * rhatX
            result[i].vy = rhatX * v * direction + radial * rhatY
        }
        return result
    }

    // MARK: Physics

    /// Net acceleration (gravity + repulsion + containment + damping) for a
    /// set of particles using the current positions/velocities.
    private static func accelerations(_ p: [Particle]) -> ([Double], [Double]) {
        let n = p.count
        var ax = [Double](repeating: 0, count: n)
        var ay = [Double](repeating: 0, count: n)
        guard n > 0 else { return (ax, ay) }
        let softening = OrbitalTuning.softening(for: n)
        let soft2 = softening * softening
        let gravity = OrbitalTuning.gravity(for: n)
        let repelRange = OrbitalTuning.repelRange(for: n)

        // Pairwise field: softened gravity plus short-range anti-overlap push.
        for i in 0..<n {
            for j in (i + 1)..<n {
                let dx = p[j].x - p[i].x
                let dy = p[j].y - p[i].y
                let r2 = dx * dx + dy * dy
                let r = sqrt(r2)
                let inv = 1.0 / max(r, 1e-9)
                let ux = dx * inv
                let uy = dy * inv

                let denom = (r2 + soft2) * sqrt(r2 + soft2)
                let gCommon = gravity / denom
                let gi = gCommon * p[j].mass
                let gj = gCommon * p[i].mass
                ax[i] += gi * dx; ay[i] += gi * dy
                ax[j] -= gj * dx; ay[j] -= gj * dy

                if r < repelRange {
                    let strength = OrbitalTuning.repelStrength
                        * (repelRange - r) / repelRange
                    ax[i] -= strength * ux; ay[i] -= strength * uy
                    ax[j] += strength * ux; ay[j] += strength * uy
                }
            }
        }

        for i in 0..<n {
            let x = p[i].x, y = p[i].y
            // Artistic external radial field: harmonic pull toward the centre.
            let trap = OrbitalTuning.trapStrength(for: n)
            ax[i] -= trap * x
            ay[i] -= trap * y
            ax[i] -= OrbitalTuning.damping * p[i].vx
            ay[i] -= OrbitalTuning.damping * p[i].vy
        }
        return (ax, ay)
    }

    private func substep(_ h: Double) {
        let n = particles.count
        guard n > 0 else { return }
        let limit = OrbitalTuning.centreLimit(for: n)

        sg_orbit_step(physics,h)
        for i in 0..<n {
            let state=sg_orbit_get_state(physics,Int32(i))
            var vx=state.vx,vy=state.vy
            let v = sqrt(vx * vx + vy * vy)
            if v > OrbitalTuning.maxSpeed {
                let s = OrbitalTuning.maxSpeed / v; vx *= s; vy *= s
            }
            particles[i].vx = vx; particles[i].vy = vy
            var x=state.x,y=state.y
            let rr = sqrt(x * x + y * y)
            if rr > limit {
                // Safety wall: fold onto the boundary and bounce the outward
                // radial velocity so bodies never stick or escape.
                let s = limit / rr
                x *= s; y *= s
                let rx = x / limit, ry = y / limit
                let vr = vx * rx + vy * ry
                if vr > 0 {
                    let restitution = OrbitalTuning.wallRestitution
                    vx -= (1.0 + restitution) * vr * rx
                    vy -= (1.0 + restitution) * vr * ry
                    particles[i].vx = vx; particles[i].vy = vy
                }
            }
            particles[i].x = x; particles[i].y = y
            sg_orbit_set_state(physics,Int32(i),SGOrbitState(x:x,y:y,vx:particles[i].vx,vy:particles[i].vy))
        }

        // Nearest-neighbour distances for the smooth encounter hint.
        var nearestDistance = [Double](repeating: Double.greatestFiniteMagnitude, count: n)
        for i in 0..<n {
            for j in 0..<n where j != i {
                let dx = particles[j].x - particles[i].x
                let dy = particles[j].y - particles[i].y
                let d = sqrt(dx * dx + dy * dy)
                if d < nearestDistance[i] { nearestDistance[i] = d }
            }
        }
        let span = max(OrbitalTuning.nearRange - OrbitalTuning.closeApproach, 1e-6)
        let blend = min(1.0, h * OrbitalTuning.encounterRate)
        for i in 0..<n {
            let d = nearestDistance[i]
            let target = min(1.0, max(0.0, (OrbitalTuning.nearRange - d) / span))
            particles[i].encounter += (target - particles[i].encounter) * blend
        }

        simTime += h
    }

    private func makeBodies() -> [OrbitalBody] {
        let count = particles.count
        let radius = OrbitalTuning.radius(for: count)
        let omega = 2.0 * Double.pi / OrbitalTuning.depthPeriod
        let drift = driftOffset
        return particles.enumerated().map { index, p in
            let depth = 0.5 + 0.5 * sin(omega * simTime + p.phase)
            return OrbitalBody(id: index,
                               position: CGPoint(x: p.x + drift.x, y: p.y + drift.y),
                               radius: radius,
                               depth: depth,
                               encounter: min(1.0, max(0.0, p.encounter)),
                               impact: sg_orbit_impact(physics, Int32(index)))
        }
    }
}
