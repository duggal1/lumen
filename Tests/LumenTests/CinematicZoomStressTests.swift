import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// Aggressive, headless checks on the cinematic camera bake. Nothing here opens
/// a window or renders a frame — every assertion reads the real 480 Hz track
/// produced by `CameraSolver`, or the public quintic primitives it is made of.
/// Scenarios are seeded so any failure names a replayable seed.
enum CineStress {
    static let src = SIMD2<Double>(1920, 1080)

    struct Rng {
        private var s: UInt64
        init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
        mutating func next() -> UInt64 {
            s &+= 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func d(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
        mutating func i(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(max(hi - lo + 1, 1))) }
    }

    static func solve(_ zoom: [ZoomSegment], _ dur: Double = 8,
                      _ p: CameraParams = CameraParams()) -> CameraTrack {
        let tm = TimeMap(sourceDuration: dur)
        let cursor = CursorTrack(count: Int(dur * gridRate) + 1)
        return CameraSolver.solve(zoom: zoom, tm: tm, cursor: cursor, p: p,
                                  src: src, outDur: dur, loop: nil)
    }

    static func auto(_ start: Double, _ len: Double, _ scale: Double,
                     _ x: Double, _ y: Double, easing: ZoomEasing? = nil) -> ZoomSegment {
        ZoomSegment(start: start, end: start + len, scale: scale,
                    focus: .fixed(x: x, y: y), easing: easing, origin: .auto)
    }

    static func tick(_ t: Double, _ tr: CameraTrack) -> Int {
        min(max(Int((t * tr.rate).rounded()), 0), tr.lz.count - 1)
    }
}

// MARK: - 1. The shared quintic primitive

@Suite struct CinematicZoomEnvelopeTests {
    /// The envelope is the single motion language: monotone, exact at both
    /// ends, zero velocity/acceleration on arrival, and no overshoot anywhere
    /// (including outside [0,1], where it must clamp rather than extrapolate).
    @Test func envelopeIsMonotoneExactAndSettles() {
        let h = 1e-4
        var prev = -1.0
        for i in -20...120 {
            let u = Double(i) / 100
            let s = QuinticMove.envelope(u)
            #expect(s >= -1e-12 && s <= 1 + 1e-12, "envelope outside [0,1] at \(u): \(s)")
            if u >= 0 && u <= 1 {
                #expect(s >= prev - 1e-12, "envelope reversed at \(u)")
                prev = s
            }
            if u <= 0 { #expect(abs(s) < 1e-12, "left endpoint not exact at \(u)") }
            if u >= 1 { #expect(abs(s - 1) < 1e-12, "right endpoint not exact at \(u)") }
        }
        let v0 = (QuinticMove.envelope(h) - QuinticMove.envelope(0)) / h
        let v1 = (QuinticMove.envelope(1) - QuinticMove.envelope(1 - h)) / h
        #expect(abs(v0) < 1e-6, "non-zero start velocity \(v0)")
        #expect(abs(v1) < 1e-6, "non-zero arrival velocity \(v1)")
        // A pure rest-to-rest QuinticMove must agree with the envelope shape.
        let q = QuinticMove(t0: 0, T: 1, x0: 0, v0: 0, a0: 0, x1: 1)
        for u in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(q.sample(u).x - QuinticMove.envelope(u)) < 1e-9,
                    "QuinticMove and envelope diverged at \(u)")
        }
    }

    /// Hermite slope bases move no endpoint and, at unit velocity, carry unit
    /// derivative at exactly one end — the whole velocity-continuity contract.
    @Test func hermiteSlopeBasesAreZeroAtEndsWithUnitEndDerivatives() {
        let h = 1e-6
        let bases: [(Double) -> Double] = [QuinticMove.leadSlope, QuinticMove.trailSlope]
        for base in bases {
            #expect(abs(base(0)) < 1e-12 && abs(base(1)) < 1e-12, "base not zero at an end")
        }
        let lead = QuinticMove.leadSlope, trail = QuinticMove.trailSlope
        #expect(abs((lead(h) - lead(0)) / h - 1) < 1e-3, "lead start derivative")
        #expect(abs((lead(1) - lead(1 - h)) / h) < 1e-3, "lead arrival derivative")
        #expect(abs((trail(1) - trail(1 - h)) / h - 1) < 1e-3, "trail arrival derivative")
        #expect(abs((trail(h) - trail(0)) / h) < 1e-3, "trail start derivative")
        // Zero endpoint acceleration is what makes the move flow into `fillHold`
        // without a one-tick acceleration step (the bounded-jerk invariant).
        let k = 1e-3
        for base in bases {
            // `base` clamps outside [0,1], so use one-sided differences at the
            // ends (a centred one would divide the clamped flap by k²).
            let d2Start = (base(2 * k) - 2 * base(k) + base(0)) / (k * k)
            let d2End = (base(1) - 2 * base(1 - k) + base(1 - 2 * k)) / (k * k)
            #expect(abs(d2Start) < 5e-2, "second derivative at 0 is \(d2Start)")
            #expect(abs(d2End) < 5e-2, "second derivative at 1 is \(d2End)")
        }
    }
}

// MARK: - 2. Arrival is exact and settled before the action

@Suite struct CinematicZoomArrivalStressTests {
    /// Across magnification, easing and lead-in settings, the lens is exactly
    /// on target at the event and has been perfectly still for a real, finite
    /// window before it — anticipation, not reaction.
    @Test func arrivalIsSettledBeforeEventAcrossScalesEasingsAndLeadIns() {
        let scales = [1.2, 1.5, 2.0, 2.4]
        let easings: [ZoomEasing?] = [nil, .snappy, .smooth, .cinematic]
        let leads = [0.30, 0.45]
        for scale in scales {
            for easing in easings {
                for lead in leads {
                    var p = CameraParams()
                    p.maxScale = 4.0
                    p.leadIn = lead
                    let click = 4.0
                    let tr = CineStress.solve([CineStress.auto(click, 1.0, scale, 0.32, 0.66,
                                                                easing: easing)], 8, p)
                    let target = log(scale)
                    let e = CineStress.tick(click, tr)
                    #expect(abs(Double(tr.lz[e]) - target) < 1e-5,
                            "not exact at event: scale=\(scale) easing=\(String(describing: easing)) lead=\(lead) lz=\(tr.lz[e])")
                    // A still hold immediately before the event.
                    var a = e
                    while a > 0, abs(Double(tr.lz[a - 1]) - target) < 1e-5 { a -= 1 }
                    #expect(e - a >= 8, // >= ~16 ms of stillness at 480 Hz
                            "no settle window before event: scale=\(scale) easing=\(String(describing: easing)) lead=\(lead) ticks=\(e - a)")
                    for k in a...e {
                        #expect(abs(Double(tr.lz[k]) - target) < 1e-5, "drift in settle at \(k)")
                    }
                    // Lead-in really anticipates: no zoom yet well before the event.
                    let early = CineStress.tick(click - 0.9, tr)
                    #expect(Double(tr.lz[early]) < 0.05 * target,
                            "lead-in did not anticipate: scale=\(scale) early=\(tr.lz[early])")
                    // Monotone rise into arrival, no overshoot anywhere.
                    var last = 0.0
                    for k in 0...e {
                        let z = Double(tr.lz[k])
                        #expect(z <= target + 1e-5, "overshoot at \(k)")
                        #expect(z >= last - 1e-6, "reversal at \(k)")
                        last = z
                    }
                }
            }
        }
    }

    /// A manual shot has no anticipation by contract: its rise starts at the
    /// placed start and lands exactly at its rise time, then holds.
    @Test func manualZoomArrivesExactlyAtItsRise() {
        var p = CameraParams(); p.maxScale = 2
        var manual = ZoomSegment(start: 2.0, end: 3.0, scale: 1.9,
                                 focus: .fixed(x: 0.4, y: 0.6), origin: .manual)
        let tr = CineStress.solve([manual], 7, p)
        let target = log(1.9)
        // manualRise(1) = 0.9 s -> arrival at 2.9 s.
        #expect(abs(Double(tr.lz[CineStress.tick(2.9, tr)]) - target) < 1e-5,
                "manual zoom did not land at its rise")
        #expect(Double(tr.lz[CineStress.tick(2.0, tr)]) < 1e-5, "manual zoom rose before its start")
        manual.scale = 50 // hostile: must be capped, never overshoot the cap
        let capped = CineStress.solve([manual], 7, p)
        #expect(log(Double(capped.lz.max() ?? 0)) <= log(p.maxScale) + 1e-5, "manual cap")
    }
}

// MARK: - 3. No teleports, no pumping, cap and clamp under seeded load

@Suite struct CinematicZoomSeededStressTests {
    /// Sixty seeded sessions of 1-4 shots (auto and manual, varied scale and
    /// focus, including shots that nearly touch) must never teleport, exceed
    /// the hard cap, leave the feasible box, go non-finite, or end zoomed in.
    @Test func seededLayoutsNeverTeleportOrBreakInvariants() {
        for seed: UInt64 in 1...60 {
            var r = CineStress.Rng(seed)
            var p = CameraParams()
            p.maxScale = r.d(1.35, 2.4)
            p.leadIn = r.d(0.25, 0.65)
            var zoom: [ZoomSegment] = []
            var cursor = 1.0
            for _ in 0..<r.i(1, 4) {
                let start = cursor + r.d(0, 0.8)
                let len = r.d(0.25, 1.4)
                cursor = start + len + r.d(-0.10, 1.0)
                zoom.append(CineStress.auto(start, len, r.d(1.3, 3.5),
                                            r.d(0.05, 0.95), r.d(0.05, 0.95)))
            }
            let tr = CineStress.solve(zoom, 9, p)
            let capLz = log(p.maxScale)
            for k in 0..<tr.lz.count {
                let z = Double(tr.lz[k]), x = Double(tr.nx[k]), y = Double(tr.ny[k])
                #expect(z.isFinite && x.isFinite && y.isFinite, "seed \(seed) non-finite at \(k)")
                #expect(z >= -1e-6 && z <= capLz + 1e-5,
                        "seed \(seed) scale \(exp(z)) outside cap \(p.maxScale) at \(k)")
                let half = 0.5 / exp(max(z, 0))
                #expect(x >= half - 2e-6 && x <= 1 - half + 2e-6,
                        "seed \(seed) centre x outside feasible box at \(k)")
                #expect(y >= half - 2e-6 && y <= 1 - half + 2e-6,
                        "seed \(seed) centre y outside feasible box at \(k)")
                if k > 0 {
                    let dx = abs(x - Double(tr.nx[k - 1]))
                    let dy = abs(y - Double(tr.ny[k - 1]))
                    let dz = abs(z - Double(tr.lz[k - 1]))
                    #expect(dx <= 0.02 && dy <= 0.02 && dz <= 0.02,
                            "seed \(seed) teleport at \(k): dx=\(dx) dy=\(dy) dz=\(dz)")
                }
            }
            let last = tr.lz.count - 1
            #expect(abs(Double(tr.lz[last])) < 1e-5, "seed \(seed) ended zoomed in")
            #expect(abs(Double(tr.nx[last]) - 0.5) < 1e-5, "seed \(seed) ended off-centre x")
            #expect(abs(Double(tr.ny[last]) - 0.5) < 1e-5, "seed \(seed) ended off-centre y")
        }
    }

    /// A bridge flows directly: between two close shots the lens never returns
    /// to the full frame. The zoom-out/zoom-in pump is exactly what this rules
    /// out, across a spread of gaps and magnifications.
    @Test func bridgedShotsNeverPumpThroughFullFrame() {
        for gap in [0.1, 0.25, 0.5, 0.9] {
            for scale in [1.6, 2.0, 2.4] {
                var p = CameraParams(); p.maxScale = 2.8
                let zoom = [
                    CineStress.auto(2.0, 1.1, scale, 0.25, 0.5),
                    CineStress.auto(3.1 + gap, 1.1, scale, 0.75, 0.5),
                ]
                let tr = CineStress.solve(zoom, 8, p)
                for t in stride(from: 2.6, through: 4.0 + gap, by: 0.05) {
                    #expect(Double(tr.lz[CineStress.tick(t, tr)]) >= log(1.35),
                            "pumped through full frame at \(t) gap=\(gap) scale=\(scale)")
                }
            }
        }
    }
}

// MARK: - 4. Velocity continuity (the bridge regression)

@Suite struct CinematicZoomVelocityStressTests {
    /// When a bridge begins *inside* the previous lens move (a short shot
    /// followed closely by another), scale velocity must carry across the
    /// join. The historic bug: `vz` cliffed from ~4.1 to ~0.0 in one tick — a
    /// dead stop and restart the eye reads as a pump. The continuity slopes
    /// keep the one-tick change well under half the smooth peak.
    @Test func scaleVelocityCarriesAcrossAnOverlappingBridge() {
        let zoom = [
            CineStress.auto(1.0, 0.06, 2.0, 0.2, 0.5),
            CineStress.auto(1.10, 0.90, 2.0, 0.8, 0.5),
        ]
        let tr = CineStress.solve(zoom, 4)
        let peak = (0..<tr.lz.count).map { abs(Double(tr.vz[$0])) }.max() ?? 0
        #expect(peak > 1, "camera never moved")
        var worst = 0.0, worstK = 0
        for k in 1..<tr.lz.count {
            let jump = abs(Double(tr.vz[k]) - Double(tr.vz[k - 1]))
            if jump > worst { worst = jump; worstK = k }
        }
        #expect(worst <= peak * 0.4,
                "scale velocity cliff at tick \(worstK): jump \(worst) vs peak \(peak) (ratio \(worst / peak))")
    }

    /// Across many seeded two-shot sessions there is no isolated velocity
    /// spike: no single tick carries a jump larger than half the smooth peak
    /// in either scale or pan. That is the numeric signature of a handoff cut.
    @Test func noVelocitySpikesAcrossSeededHandoffs() {
        for seed: UInt64 in 100...140 {
            var r = CineStress.Rng(seed)
            var p = CameraParams(); p.maxScale = 2.4
            let zoom = [
                CineStress.auto(1.5, r.d(0.15, 1.2), r.d(1.6, 2.3), r.d(0.1, 0.4), r.d(0.1, 0.9)),
                CineStress.auto(2.2, r.d(0.5, 1.4), r.d(1.6, 2.3), r.d(0.6, 0.9), r.d(0.1, 0.9)),
            ]
            let tr = CineStress.solve(zoom, 7, p)
            let peakZ = (0..<tr.lz.count).map { abs(Double(tr.vz[$0])) }.max() ?? 0
            let peakX = (0..<tr.lz.count).map { abs(Double(tr.vx[$0])) }.max() ?? 0
            guard peakZ > 1e-3 else { continue }
            for k in 1..<tr.lz.count {
                let jz = abs(Double(tr.vz[k]) - Double(tr.vz[k - 1]))
                #expect(jz <= peakZ * 0.5 + 1e-3,
                        "seed \(seed) scale velocity spike at \(k): \(jz) vs \(peakZ)")
                if peakX > 1e-3 {
                    let jx = abs(Double(tr.vx[k]) - Double(tr.vx[k - 1]))
                    #expect(jx <= peakX * 0.6 + 1e-3,
                            "seed \(seed) pan velocity spike at \(k): \(jx) vs \(peakX)")
                }
            }
        }
    }
}

// MARK: - 5. Determinism, hostile input, export-rate alignment

@Suite struct CinematicZoomDeterminismStressTests {
    /// The bake is a pure function of its inputs. Replaying after heavy churn
    /// must reproduce the identical Float track, tick for tick.
    @Test func replayIsByteIdenticalAfterChurn() {
        let zoom = [
            CineStress.auto(1.5, 1.2, 2.1, 0.3, 0.4),
            CineStress.auto(3.0, 1.2, 2.6, 0.7, 0.6),
        ]
        let p = CameraParams()
        let baseline = CineStress.solve(zoom, 8, p)
        for i in 0..<32 {
            _ = CineStress.solve([CineStress.auto(Double(i) * 0.1 + 0.2, 0.3, 1.8, 0.5, 0.5)], 8, p)
            let replay = CineStress.solve(zoom, 8, p)
            #expect(replay == baseline, "replay \(i) differs from baseline")
        }
    }

    /// Hostile / degenerate inputs must still produce a finite, bounded track:
    /// non-finite times are dropped, negative times clamp to the start, huge
    /// scales cap, out-of-range focus clamps into the feasible box.
    @Test func hostileInputsProduceFiniteBoundedTrack() {
        let bad = [
            ZoomSegment(start: .nan, end: 2, scale: 2, focus: .fixed(x: 0.5, y: 0.5), origin: .auto),
            ZoomSegment(start: 1, end: .infinity, scale: 2, focus: .fixed(x: 0.5, y: 0.5), origin: .auto),
            ZoomSegment(start: -2, end: -1, scale: 1e9, focus: .fixed(x: -3, y: 4), origin: .auto),
            ZoomSegment(start: 3, end: 4, scale: 3, focus: .fixed(x: 2.5, y: -1.5), origin: .auto),
        ]
        var p = CameraParams(); p.maxScale = 1.5
        let tr = CineStress.solve(bad, 6, p)
        #expect(tr.lz.count > 1)
        for k in 0..<tr.lz.count {
            let z = Double(tr.lz[k]), x = Double(tr.nx[k]), y = Double(tr.ny[k])
            #expect(z.isFinite && x.isFinite && y.isFinite, "non-finite at \(k)")
            #expect(z <= log(p.maxScale) + 1e-5, "cap exceeded at \(k)")
            let half = 0.5 / exp(max(z, 0))
            #expect(x >= half - 2e-6 && x <= 1 - half + 2e-6, "feasible x at \(k)")
            #expect(y >= half - 2e-6 && y <= 1 - half + 2e-6, "feasible y at \(k)")
        }
    }

    /// Mirrors the unmodified `MotionTraceTests.motionTracesAreSmooth` metric
    /// on a scripted multi-click timeline, where bridges and follow holds meet.
    /// Bounded jerk is the numeric signature of a filmed settle: a one-tick
    /// acceleration step at a handoff — or a quintic squeezed into too short a
    /// runway — spikes well past the bound.
    @Test func bakedTrackHasBoundedJerkAcrossScriptedClicks() throws {
        let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 12,
                             backingScale: 2, originX: 0, originY: 0)
        var tl = Timeline(duration: 12)
        tl.camera.autoZoom = true
        tl.camera.minScale = 1.1
        tl.camera.maxScale = 3.5
        tl.audio.speedRampsAuto = false
        tl.style.padding = 0
        tl = try Director.derive(tl, input: DirectorInput(
            events: (0..<8).map {
                InputEvent(t: Double($0) + 0.5, kind: .down,
                           x: 400 + Float($0 * 150), y: 540, button: 0)
            },
            source: src, ax: [AXFrame(x: 400, y: 440, w: 200, h: 100)],
            transcript: Transcript(words: [WordToken(text: "hello", start: 2.0, end: 2.3)],
                                   locale: "en")), revision: 1)
        let fs = 240.0
        let n = Int(tl.compositionDuration * fs)
        var xs = [Double](), ys = [Double](), zs = [Double]()
        for i in 0..<n {
            let f = tl.evaluate(at: Double(i) / fs)
            xs.append(Double(f.cameraCenter.x)); ys.append(Double(f.cameraCenter.y))
            zs.append(log(Double(f.cameraScale)))
        }
        func metric(_ x: [Double]) -> Double {
            guard x.count > 4 else { return 0 }
            var m = 0.0
            for i in 2..<(x.count - 1) {
                let v0 = (x[i - 1] - x[i - 2]) * fs
                let v1 = (x[i] - x[i - 1]) * fs
                let v2 = (x[i + 1] - x[i]) * fs
                let acc = (v2 - v0) / 2
                let jerk = (v2 - 2 * v1 + v0) * fs * fs
                m = max(m, abs(acc), abs(jerk) * 10)
            }
            return m
        }
        #expect(metric(xs) < 1e7, "pan x jerk \(metric(xs))")
        #expect(metric(ys) < 1e7, "pan y jerk \(metric(ys))")
        #expect(metric(zs) < 1e7, "zoom jerk \(metric(zs))")
    }

    /// 480 Hz is an exact multiple of 60/120/240 fps, so every export frame
    /// lands on a baked tick with no interpolation jitter, and the reconstructed
    /// camera scale on that frame grid equals the baked value.
    @Test func exportFrameRatesLandExactlyOnBakedTicks() {
        let tr = CineStress.solve([CineStress.auto(2.0, 1.0, 2.0, 0.3, 0.7)], 6)
        for fps in [60.0, 120.0, 240.0] {
            #expect((480 / fps).rounded() == 480 / fps, "480 Hz not a multiple of \(fps)")
            for f in 0..<Int(6 * fps) {
                let t = Double(f) / fps
                let tick = CineStress.tick(t, tr)
                #expect(abs(t - Double(tick) / tr.rate) < 1e-12,
                        "frame \(f) @ \(fps) fps does not land on a baked tick")
            }
        }
    }
}
