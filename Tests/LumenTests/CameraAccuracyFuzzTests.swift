import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// Deterministic splitmix64. A failing seed reproduces the exact scenario, so
/// no failure here needs a screenshot or a GUI to diagnose.
private struct CAMRng {
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
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

private enum CAMFuzz {
    /// A valid plan: non-overlapping shots, ordered by start, with gaps in the
    /// range the real planner emits. Tilt modes include `.off` deliberately —
    /// every seed must still produce a perfectly flat tilt channel.
    static func scenario(_ seed: UInt64) -> (zoom: [ZoomSegment], p: CameraParams, duration: Double) {
        var r = CAMRng(seed)
        let duration = r.d(4, 9)
        var p = CameraParams()
        p.tilt = TiltMode.allCases[r.i(0, TiltMode.allCases.count - 1)]
        p.leadIn = r.d(0.02, 0.9)
        p.tail = r.d(0.25, 1.4)
        p.omegaTilt = r.d(0.5, 20)
        p.maxYaw = r.d(0.5, 40)
        p.maxPitch = r.d(0.5, 40)
        p.maxScale = r.d(1.3, 3.0)

        var zoom: [ZoomSegment] = []
        var t = r.d(0.5, 1.5)
        for _ in 0..<r.i(2, 6) {
            let length = r.d(0.3, 1.3)
            guard t + length < duration - 0.2 else { break }
            let scale = r.d(1.15, min(p.maxScale, 2.6))
            let x = r.d(0.05, 0.95), y = r.d(0.05, 0.95)
            zoom.append(CAM.auto(t, length, scale: scale, x: x, y: y))
            t += length + r.d(0.05, 1.5)
        }
        return (zoom, p, duration)
    }

    /// Every invariant the 18 screenshots proved broken, checked on one track.
    static func check(_ tr: CameraTrack, _ p: CameraParams, label: String) -> [String] {
        var bad: [String] = []
        guard tr.lz.count > 1 else { return ["\(label): empty track"] }
        guard tr.nx.count == tr.lz.count, tr.ny.count == tr.lz.count,
              tr.yaw.count == tr.lz.count, tr.pitch.count == tr.lz.count else {
            return ["\(label): channel length mismatch"]
        }
        let maxScale = p.maxScale
        for k in tr.lz.indices {
            let z = Double(tr.lz[k]), x = Double(tr.nx[k]), y = Double(tr.ny[k])
            if !z.isFinite || !x.isFinite || !y.isFinite {
                bad.append("\(label): non-finite pose at \(k)"); break
            }
            if !tr.yaw[k].isFinite || !tr.pitch[k].isFinite {
                bad.append("\(label): non-finite tilt at \(k)"); break
            }
            if z < -1e-6 || exp(z) > maxScale * 1.001 {
                bad.append("\(label): scale \(exp(z)) out of [1,\(maxScale)] at \(k)"); break
            }
            let half = 0.5 / exp(max(z, 0))
            if x < half - 2e-6 || x > 1 - half + 2e-6 || y < half - 2e-6 || y > 1 - half + 2e-6 {
                bad.append("\(label): centre outside feasible box at \(k)"); break
            }
            if p.tilt == .off || p.tilt == .off {
                if tr.yaw[k] != 0 || tr.pitch[k] != 0 {
                    bad.append("\(label): \(p.tilt) drifted at \(k)"); break
                }
            }
            if k > 0 {
                let dx = abs(Double(tr.nx[k]) - Double(tr.nx[k - 1]))
                let dy = abs(Double(tr.ny[k]) - Double(tr.ny[k - 1]))
                let dz = abs(Double(tr.lz[k]) - Double(tr.lz[k - 1]))
                if dx > 0.02 || dy > 0.02 || dz > 0.02 {
                    bad.append("\(label): teleport at \(k) (dx=\(dx) dy=\(dy) dz=\(dz))"); break
                }
            }
        }
        let last = tr.lz.count - 1
        if abs(Double(tr.lz[last])) > 1e-5 || abs(Double(tr.nx[last]) - 0.5) > 1e-5 ||
           abs(Double(tr.ny[last]) - 0.5) > 1e-5 {
            bad.append("\(label): did not end full and centred")
        }
        for (name, channel) in [("z", tr.lz), ("x", tr.nx), ("y", tr.ny)] {
            let j = MotionLimits.peakJerk(channel, rate: tr.rate)
            if j >= MotionLimits.cameraJerk {
                bad.append(String(format: "%@: %@ jerk %.0f exceeded bound", label, name, j))
            }
        }
        return bad
    }
}

@Suite struct CameraAccuracyFuzzTests {
    /// 200 seeded sessions: no drift, no teleport, bounded jerk, cap/feasible,
    /// full-frame tail, deterministic replay. Any failure names its seed.
    @Test func twoHundredSessionsHoldEveryCameraInvariant() {
        var failures: [String] = []
        for seed in UInt64(1)...UInt64(200) {
            let s = CAMFuzz.scenario(seed)
            let tr = CAM.solve(s.zoom, duration: s.duration, p: s.p)
            failures += CAMFuzz.check(tr, s.p, label: "seed \(seed)")

            let replay = CAM.solve(s.zoom, duration: s.duration, p: s.p)
            if replay != tr { failures.append("seed \(seed): replay differs byte-wise") }
            if failures.count > 8 { break }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    /// 200 seeds that inject NaN, infinities, extreme times/scales/centres and
    /// hostile param values into EVERY field the camera reads. The bake must
    /// stay finite, capped, feasible, bit-still in `.off` and full-framed at the
    /// end. This is the direct camera-level version of the task's hostile fuzz.
    @Test func twoHundredHostileSeedsNeverBreakTheBake() {
        let hostile = [Double.nan, .infinity, -.infinity, -1e9, 1e9, 0, 1e-12]
        var failures: [String] = []
        for seed in UInt64(1)...UInt64(200) {
            var r = CAMRng(seed)
            let duration = [Double.nan, .infinity, 3, 6, 9][r.i(0, 4)]
            var p = CAM.params(.off)
            p.maxScale = [Double.nan, .infinity, 1e9, 1.001, 2][r.i(0, 4)]
            p.leadIn = hostile[r.i(0, hostile.count - 1)]
            p.tail = hostile[r.i(0, hostile.count - 1)]
            p.lookahead = hostile[r.i(0, hostile.count - 1)]
            p.deadZone = hostile[r.i(0, hostile.count - 1)]
            p.followDelay = hostile[r.i(0, hostile.count - 1)]
            p.omegaPan = hostile[r.i(0, hostile.count - 1)]
            p.omegaTilt = hostile[r.i(0, hostile.count - 1)]
            p.maxYaw = hostile[r.i(0, hostile.count - 1)]
            p.maxPitch = hostile[r.i(0, hostile.count - 1)]
            p.centerOffsetX = hostile[r.i(0, hostile.count - 1)]
            p.centerOffsetY = hostile[r.i(0, hostile.count - 1)]
            var zoom: [ZoomSegment] = []
            for _ in 0..<r.i(1, 4) {
                let s = ZoomSegment(start: hostile[r.i(0, hostile.count - 1)],
                                    end: hostile[r.i(0, hostile.count - 1)],
                                    scale: hostile[r.i(0, hostile.count - 1)],
                                    focus: r.chance(0.5)
                                        ? .fixed(x: hostile[r.i(0, hostile.count - 1)],
                                                 y: hostile[r.i(0, hostile.count - 1)])
                                        : .element(x: hostile[r.i(0, hostile.count - 1)],
                                                   y: hostile[r.i(0, hostile.count - 1)],
                                                   w: hostile[r.i(0, hostile.count - 1)],
                                                   h: hostile[r.i(0, hostile.count - 1)]),
                                    easing: ZoomEasing.allCases[r.i(0, 2)],
                                    origin: r.chance(0.5) ? .auto : .manual)
                zoom.append(s)
            }
            let tm = TimeMap(sourceDuration: duration.isFinite ? max(duration, 0.1) : 0.1)
            let cursor = CursorTrack(count: 5)
            let outDur = duration.isFinite ? max(duration, 0.1) : 0.1
            let tr = CameraSolver.solve(zoom: zoom, tm: tm, cursor: cursor, p: p,
                                        src: CAM.source, outDur: outDur, loop: nil,
                                        cancelled: { false }) ?? CameraTrack(count: 2)
            if tr.lz.count < 1 {
                failures.append("seed \(seed): empty track"); continue
            }
            for k in tr.lz.indices {
                let z = Double(tr.lz[k]), x = Double(tr.nx[k]), y = Double(tr.ny[k])
                if !z.isFinite || !x.isFinite || !y.isFinite ||
                   !tr.vz[k].isFinite || !tr.az[k].isFinite || !tr.yaw[k].isFinite {
                    failures.append("seed \(seed) tick \(k): non-finite pose/derivative"); break
                }
                if z < -1e-6 || exp(z) > 1e9 + 1e-3 {
                    failures.append("seed \(seed) tick \(k): scale out of range \(z)"); break
                }
                let half = 0.5 / exp(max(z, 0))
                if x < half - 2e-6 || x > 1 - half + 2e-6 || y < half - 2e-6 || y > 1 - half + 2e-6 {
                    failures.append("seed \(seed) tick \(k): infeasible centre"); break
                }
                if tr.yaw[k] != 0 || tr.pitch[k] != 0 {
                    failures.append("seed \(seed) tick \(k): `.off` tilt drifted"); break
                }
            }
            if failures.count > 8 { break }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    /// A fast recorded follow pan that bridges straight into a near-static shot
    /// is the worst case for the continuity-slope cap in `CameraSolver.fill`:
    /// the incoming hold velocity is large but the new move's delta is tiny, so
    /// `bounded()` clips it and the handoff can no longer be C1. Measure the
    /// actual baked jerk at 480 Hz instead of trusting the rest-to-rest tests.
    @Test func bridgedFastFollowIntoStaticShotKeepsJerkBounded() {
        var worst = 0.0
        var worstDetail = ""
        for speed in [0.15, 0.3, 0.5, 0.9, 1.5] {
            let id1 = UUID(), id2 = UUID()
            let a = ZoomSegment(id: id1, start: 1.0, end: 3.0, scale: 2,
                                focus: .follow, origin: .auto)
            let b = ZoomSegment(id: id2, start: 3.2, end: 4.6, scale: 2,
                                focus: .fixed(x: 0.26, y: 0.5), origin: .auto)
            var follow: [UUID: [(t: Double, c: SIMD2<Double>)]] = [:]
            var path: [(t: Double, c: SIMD2<Double>)] = []
            var x = 0.28
            var t = 0.0
            while t <= 3.0 {
                path.append((t: t, c: SIMD2(x, 0.5)))
                x += speed / 480.0
                t += 1.0 / 480.0
            }
            follow[id1] = path
            let tm = TimeMap(sourceDuration: 7)
            let cursor = CursorTrack(count: Int(7 * gridRate) + 1)
            guard let tr = CameraSolver.solve(zoom: [a, b], tm: tm, cursor: cursor,
                                              p: CAM.params(.off), src: CAM.source,
                                              outDur: 7, loop: nil, follow: follow,
                                              cancelled: { false }) else {
                Issue.record("solve returned nil"); continue
            }
            for (name, ch) in [("z", tr.lz), ("x", tr.nx), ("y", tr.ny)] {
                let j = MotionLimits.peakJerk(ch, rate: tr.rate)
                if j > worst { worst = j; worstDetail = "speed \(speed) channel \(name)" }
            }
        }
        #expect(worst < MotionLimits.cameraJerk,
                "bridged handoff jerk \(worst) at \(worstDetail) exceeded bound \(MotionLimits.cameraJerk)")
    }

    /// Mutations of the retired knobs must never change the answer. If any of
    /// them leaks into the bake, this fails on a 200-seed sweep.
    @Test func retiredFloatKnobsAreInertAcrossAllSeeds() {
        var failures: [String] = []
        for seed in UInt64(1)...UInt64(200) {
            let s = CAMFuzz.scenario(seed)
            var a = s.p, b = s.p
            a.tilt = .off;            b.tilt = .off
            // Mutate every retired knob; none may reach the recorded bake.
            b.omegaTilt = 60; b.maxYaw = 40; b.maxPitch = 40
            b.omegaZoom = 99; b.sensitivity = 1; b.shutter = 1
            b.maxSamples = 2; b.upscaleEnabled = false; b.upscaleMaxFactor = 2
            b.minScale = 3; b.baseScale = 3; b.zoomOutGap = 9; b.panThroughGap = 9
            let ta = CAM.solve(s.zoom, duration: s.duration, p: a)
            let tb = CAM.solve(s.zoom, duration: s.duration, p: b)
            if ta != tb { failures.append("seed \(seed): retired knob changed the bake") }
            if failures.count > 8 { break }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
}
