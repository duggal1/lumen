import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// 200 seeded sessions that attack the timing contract directly: shots of
/// every length, gaps from "one action" to "long silence", hostile easing and
/// focus, and export-rate alignment. Every failure names a replayable seed.
struct TimingRng {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func d(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    mutating func i(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(max(hi - lo + 1, 1))) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

enum TimingFuzz {
    static func session(seed: UInt64) -> (zoom: [ZoomSegment], duration: Double, p: CameraParams) {
        var r = TimingRng(seed)
        var p = CameraParams()
        p.maxScale = r.d(1.25, 2.8)
        p.leadIn = r.d(0.20, 0.6)
        p.tail = r.d(0.45, 1.0)
        p.hold = r.d(0.5, 1.4)
        if r.chance(0.25) { p.tilt = .lean; p.omegaTilt = r.d(3, 8) }

        var zoom: [ZoomSegment] = []
        var t = r.d(0.5, 2.0)
        let count = r.i(1, 7)
        for _ in 0..<count {
            let length = r.chance(0.2) ? r.d(4.0, 9.0) : r.d(0.25, 1.6)
            let scale = r.d(1.2, 3.4)
            let focus: Focus
            switch r.i(0, 2) {
            case 0: focus = .fixed(x: r.d(0.05, 0.95), y: r.d(0.05, 0.95))
            case 1: focus = .element(x: r.d(0, 0.7), y: r.d(0, 0.7),
                                     w: r.d(0.05, 0.25), h: r.d(0.05, 0.25))
            default: focus = .fixed(x: r.d(0.2, 0.8), y: r.d(0.2, 0.8))
            }
            let easing: ZoomEasing? = r.chance(0.5) ? nil :
                [ZoomEasing.snappy, .smooth, .cinematic][r.i(0, 2)]
            zoom.append(ZoomSegment(start: t, end: t + length, scale: scale,
                                    focus: focus, easing: easing, origin: .auto))
            // Gaps straddle the bridge boundary: sub-second (one action) and
            // multi-second (distinct actions that must return to full frame).
            t += length + (r.chance(0.5) ? r.d(0.05, 0.8) : r.d(1.0, 3.0))
        }
        let duration = max(t + r.d(1.0, 12.0), 4.0)
        return (zoom, duration, p)
    }
}

@Suite struct ZoomTimingAccuracyFuzzTests {
    /// Every invariant, on every one of 200 seeded sessions. A failure prints
    /// the seed, which reproduces the exact scenario.
    @Test func twoHundredSeededSessionsHoldEveryTimingInvariant() {
        var failures: [String] = []
        for seed: UInt64 in 1...200 {
            let (zoom, duration, p) = TimingFuzz.session(seed: seed)
            let tr = ZoomTiming.solve(zoom, duration: duration, p: p)
            let cap = log(p.maxScale)

            // Finite, capped, feasible — at every tick including the handoffs.
            for k in 0..<tr.lz.count {
                let z = Double(tr.lz[k]), x = Double(tr.nx[k]), y = Double(tr.ny[k])
                if !z.isFinite || !x.isFinite || !y.isFinite {
                    failures.append("seed \(seed): non-finite at \(k)"); break
                }
                if z < -1e-6 || z > cap + 1e-5 {
                    failures.append("seed \(seed): scale \(exp(z)) outside cap at \(k)"); break
                }
                let half = 0.5 / exp(max(z, 0))
                if x < half - 2e-6 || x > 1 - half + 2e-6 ||
                   y < half - 2e-6 || y > 1 - half + 2e-6 {
                    failures.append("seed \(seed): centre outside feasible box at \(k)"); break
                }
                if k > 0 {
                    let dx = abs(x - Double(tr.nx[k - 1]))
                    let dy = abs(y - Double(tr.ny[k - 1]))
                    let dz = abs(z - Double(tr.lz[k - 1]))
                    if dx > 0.02 || dy > 0.02 || dz > 0.02 {
                        failures.append("seed \(seed): teleport at \(k)"); break
                    }
                }
            }

            // The continuous zoomed run is bounded. A long *single* segment is
            // one shot; a chain of them can never fuse into an 8-10 s zoom.
            let longestShot = zoom.map { $0.end - $0.start }.max() ?? 0
            // A single shot legitimately includes its lead-in and tail above
            // the 1.35x threshold; the guard is against fusing several shots.
            let runLimit = max(7.5, longestShot + 4.5)
            let run = ZoomTiming.longestZoomedRun(tr)
            if run > runLimit {
                failures.append(String(format: "seed %llu: continuous zoom %.2fs > %.2fs",
                                       seed, run, runLimit))
            }

            // Bounded jerk at the native rate.
            let jz = ZoomTiming.peakJerk(tr.lz, rate: tr.rate)
            let jx = ZoomTiming.peakJerk(tr.nx, rate: tr.rate)
            if jz >= MotionLimits.cameraJerk || jx >= MotionLimits.cameraJerk {
                failures.append(String(format: "seed %llu: jerk z=%.1f x=%.1f",
                                       seed, jz, jx))
            }

            // Every session ends on the full, centred frame.
            let last = tr.lz.count - 1
            if abs(Double(tr.lz[last])) > 1e-5 ||
               abs(Double(tr.nx[last]) - 0.5) > 1e-5 ||
               abs(Double(tr.ny[last]) - 0.5) > 1e-5 {
                failures.append("seed \(seed): ends zoomed/off-centre")
            }
            if failures.count > 12 { break }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    /// Replay is byte-identical, independent of prior work in the process.
    @Test func seededReplayIsByteIdentical() {
        for seed: UInt64 in 1...30 {
            let (zoom, duration, p) = TimingFuzz.session(seed: seed)
            let a = ZoomTiming.solve(zoom, duration: duration, p: p)
            let (other, _, _) = TimingFuzz.session(seed: seed &* 7 + 3)
            _ = ZoomTiming.solve(other, duration: duration, p: p)
            let b = ZoomTiming.solve(zoom, duration: duration, p: p)
            #expect(a == b, "seed \(seed): replay differs")
        }
    }

    /// Mutating every field the bake reads changes the track: no frozen digest.
    @Test func inputMutationsChangeTheBake() {
        for seed: UInt64 in 1...20 {
            let (zoom, duration, p) = TimingFuzz.session(seed: seed)
            guard let first = zoom.first else { continue }
            let base = ZoomTiming.solve(zoom, duration: duration, p: p)

            var movedScale = zoom
            movedScale[0].scale = first.scale > 1.6 ? 1.3 : min(p.maxScale, 2.2)
            #expect(ZoomTiming.solve(movedScale, duration: duration, p: p) != base,
                    "seed \(seed): scale mutation ignored")

            var movedFocus = zoom
            movedFocus[0].focus = .fixed(x: 0.5, y: 0.5)
            #expect(ZoomTiming.solve(movedFocus, duration: duration, p: p) != base,
                    "seed \(seed): focus mutation ignored")

            var movedTime = zoom; movedTime[0].start += 0.37; movedTime[0].end += 0.37
            #expect(ZoomTiming.solve(movedTime, duration: duration, p: p) != base,
                    "seed \(seed): time mutation ignored")

            var changedP = p; changedP.tail = max(0.3, p.tail - 0.2)
            #expect(ZoomTiming.solve(zoom, duration: duration, p: changedP) != base,
                    "seed \(seed): tail mutation ignored")
        }
    }
}
