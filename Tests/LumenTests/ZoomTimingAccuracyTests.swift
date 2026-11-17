import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// Camera-timing accuracy, headless and deterministic.
///
/// Every assertion reads the real 480 Hz `CameraSolver` bake (and, where a frame
/// is mentioned, `Timeline.evaluate` — the exact preview/export path). No window,
/// no render, no GUI. The scenarios are the ones the 12 screenshots exposed:
/// shots chained into an 8-10 s continuous zoom, a waveform that ends at 54 s
/// while the recording runs to 65 s, and a camera that never returns promptly.
enum ZoomTiming {
    static let source = SIMD2<Double>(1920, 1080)

    static func solve(_ zoom: [ZoomSegment], duration: Double,
                      p: CameraParams = CameraParams()) -> CameraTrack {
        let tm = TimeMap(sourceDuration: duration)
        let cursor = CursorTrack(count: Int(duration * gridRate) + 1)
        return CameraSolver.solve(zoom: zoom, tm: tm, cursor: cursor, p: p,
                                  src: source, outDur: duration, loop: nil)
    }

    static func index(_ t: Double, _ tr: CameraTrack) -> Int {
        min(max(Int((t * tr.rate).rounded()), 0), tr.lz.count - 1)
    }
    static func lz(_ t: Double, _ tr: CameraTrack) -> Double { Double(tr.lz[index(t, tr)]) }
    static func scale(_ t: Double, _ tr: CameraTrack) -> Double { exp(lz(t, tr)) }
    static func center(_ t: Double, _ tr: CameraTrack) -> SIMD2<Double> {
        SIMD2(Double(tr.nx[index(t, tr)]), Double(tr.ny[index(t, tr)]))
    }

    static func auto(_ start: Double, _ length: Double, _ scale: Double = 2,
                     x: Double = 0.34, y: Double = 0.62) -> ZoomSegment {
        ZoomSegment(start: start, end: start + length, scale: scale,
                    focus: .fixed(x: x, y: y), origin: .auto)
    }

    /// Longest continuous span (seconds) whose scale stays above `threshold`.
    /// This is the number the screenshots got wrong: chained shots made it 8-10 s.
    static func longestZoomedRun(_ tr: CameraTrack, threshold: Double = 1.35) -> Double {
        var best = 0.0, runStart: Double? = nil
        let dt = 1 / tr.rate
        for k in 0..<tr.lz.count {
            let zoomed = exp(Double(tr.lz[k])) > threshold
            if zoomed {
                if runStart == nil { runStart = Double(k) * dt }
            } else if let s = runStart {
                best = max(best, Double(k) * dt - s)
                runStart = nil
            }
        }
        if let s = runStart { best = max(best, Double(tr.lz.count - 1) * dt - s) }
        return best
    }

    /// Third-difference jerk at the native bake rate, in the curve's own units.
    static func peakJerk(_ values: [Float], rate: Double) -> Double {
        guard values.count > 3 else { return 0 }
        var peak = 0.0
        for i in 2..<(values.count - 1) {
            let j = (Double(values[i + 1]) - 3 * Double(values[i])
                     + 3 * Double(values[i - 1]) - Double(values[i - 2])) * rate * rate * rate
            peak = max(peak, abs(j))
        }
        return peak
    }
}

// MARK: - 1. No 8-10 s continuous zoom (the headline defect)

@Suite struct ZoomTimingLongHoldTests {
    /// Six short shots with ~1 s gaps used to bridge into one continuous zoom
    /// that covered the entire segment. Each gap must now show the full frame.
    @Test func chainedShortShotsReturnToFullFrameBetweenThem() {
        let zoom = [2.0, 4.0, 6.0, 8.0, 10.0, 12.0].map { ZoomTiming.auto($0, 1.0) }
        let tr = ZoomTiming.solve(zoom, duration: 16)
        var failures: [String] = []
        for t in [3.5, 5.5, 7.5, 9.5, 11.5] {
            let s = ZoomTiming.scale(t, tr), c = ZoomTiming.center(t, tr)
            if abs(s - 1) > 1e-3 {
                failures.append("t=\(t): scale \(s) (expected full frame)")
            }
            if abs(c.x - 0.5) > 1e-3 || abs(c.y - 0.5) > 1e-3 {
                failures.append("t=\(t): centre \(c) (expected (0.5,0.5))")
            }
        }
        let run = ZoomTiming.longestZoomedRun(tr)
        #expect(run < 3.6, "one continuous zoom ran \(run)s (expected < 3.6s)")
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    /// Even when every shot is tight enough to bridge, a run is capped: the
    /// camera comes up for air rather than holding one magnification for 10 s.
    @Test func bridgedRunIsCapped() {
        let zoom = (0..<14).map { ZoomTiming.auto(1.0 + Double($0) * 0.75, 0.55) }
        let tr = ZoomTiming.solve(zoom, duration: 14)
        #expect(ZoomTiming.longestZoomedRun(tr) < 7.0,
                "bridged run reached \(ZoomTiming.longestZoomedRun(tr))s")
        // Arrival still happens: at least one shot reached full magnification.
        let arrived = (0..<tr.lz.count).contains { Double(tr.lz[$0]) > log(1.8) }
        #expect(arrived, "the capped run never zoomed in")
    }

    /// A single long segment is one shot, not a licence to add bridging on top:
    /// the return starts at the segment end and completes within the tail.
    @Test func longShotReturnsAtItsOwnEnd() {
        let tr = ZoomTiming.solve([ZoomTiming.auto(2, 8)], duration: 14)
        #expect(abs(ZoomTiming.scale(9.9, tr) - 2) < 1e-3, "no hold through the shot")
        #expect(ZoomTiming.scale(10.2, tr) < 1.9, "return did not begin at segment end")
        #expect(abs(ZoomTiming.scale(10.8, tr) - 1) < 1e-3, "return not complete within tail")
        for t in stride(from: 11.0, through: 13.9, by: 0.25) {
            #expect(abs(ZoomTiming.scale(t, tr) - 1) < 1e-4, "drift in silent tail at \(t)")
        }
    }
}

// MARK: - 2. Trailing silent tail

@Suite struct ZoomTimingSilentTailTests {
    /// The reported case: activity ends at 54 s in a 65 s recording. The frame
    /// must be full and centred from just after 54 s all the way to the end.
    @Test func activityEndingAt54SecondsLeavesTheFrameFull() {
        let zoom = [
            ZoomTiming.auto(50, 1.0),
            ZoomTiming.auto(52, 1.0),
            ZoomTiming.auto(53.4, 0.6),
        ]
        let tr = ZoomTiming.solve(zoom, duration: 65)
        #expect(ZoomTiming.scale(53.7, tr) > 1.1, "the last shot did not happen")
        for t in stride(from: 55.0, through: 64.9, by: 0.25) {
            let s = ZoomTiming.scale(t, tr), c = ZoomTiming.center(t, tr)
            if abs(s - 1) > 1e-3 || abs(c.x - 0.5) > 1e-3 || abs(c.y - 0.5) > 1e-3 {
                Issue.record("silent tail at \(t): scale=\(s) centre=\(c)")
                break
            }
        }
        let last = tr.lz.count - 1
        #expect(abs(Double(tr.lz[last])) < 1e-5)
        #expect(abs(Double(tr.nx[last]) - 0.5) < 1e-5)
        #expect(abs(Double(tr.ny[last]) - 0.5) < 1e-5)
    }

    /// A click in the very last fraction of the recording cannot strand the
    /// camera zoomed in; the mandatory tail always lands on the final tick.
    @Test func lastMomentActivityStillEndsFullFrame() {
        for end in [64.5, 64.9, 65.0] {
            let tr = ZoomTiming.solve([ZoomTiming.auto(end - 1.0, 1.0)], duration: 65)
            let last = tr.lz.count - 1
            #expect(abs(Double(tr.lz[last])) < 1e-5, "end=\(end) stuck at \(exp(Double(tr.lz[last])))x")
            #expect(abs(Double(tr.nx[last]) - 0.5) < 1e-5)
        }
    }
}

// MARK: - 3. Arrival and return timing

@Suite struct ZoomTimingArrivalReturnTests {
    /// The frame is composed before the action, holds through it, then leaves
    /// at the segment end — one clean descent, no early exit, no late crawl.
    @Test func arrivalIsSettledAndReturnStartsAtActionEnd() {
        let tr = ZoomTiming.solve([ZoomTiming.auto(2, 1.0)], duration: 8)
        let target = log(2.0)
        #expect(abs(ZoomTiming.lz(1.95, tr) - target) < 1e-5, "not settled at the event")
        #expect(ZoomTiming.lz(1.5, tr) < 0.05 * target, "lead-in did not anticipate")
        #expect(abs(ZoomTiming.scale(2.9, tr) - 2) < 1e-3, "hold did not cover the action")
        #expect(ZoomTiming.scale(3.2, tr) < 1.9, "zoom-out did not begin at the action end")
        #expect(abs(ZoomTiming.scale(3.75, tr) - 1) < 1e-3, "zoom-out not complete within tail")

        var previous = ZoomTiming.scale(3.0, tr)
        for k in 1...Int((0.8 * tr.rate).rounded()) {
            let s = ZoomTiming.scale(3.0 + Double(k) / tr.rate, tr)
            #expect(s >= 1 - 1e-6, "dipped below full frame at \(k)")
            #expect(s <= previous + 1e-4, "rose during zoom-out at \(k)")
            previous = s
        }
    }

    /// Short shots and long shots share the same envelope: arrival is exact in
    /// both, and the rise is monotone with a gentle, decelerating settle.
    @Test func shortAndLongShotsShareTheSameSettle() {
        for length in [0.25, 1.0, 6.0] {
            let tr = ZoomTiming.solve([ZoomTiming.auto(3, length)], duration: 12)
            let target = log(2.0)
            #expect(abs(ZoomTiming.lz(3.0, tr) - target) < 1e-5, "len=\(length): not exact at event")
            var previous = 0.0
            var speeds: [Double] = []
            for k in 0...ZoomTiming.index(3.0, tr) {
                let z = Double(tr.lz[k])
                #expect(z <= target + 1e-5, "len=\(length): overshoot at \(k)")
                #expect(z >= previous - 1e-6, "len=\(length): reversal at \(k)")
                speeds.append((z - previous) * tr.rate)
                previous = z
            }
            let peak = speeds.max() ?? 0
            #expect(peak > 1e-3, "len=\(length): camera never moved")
            #expect(speeds.suffix(10).allSatisfy { $0 <= peak * 0.25 + 1e-6 },
                    "len=\(length): late pump in the settle")
        }
    }
}

// MARK: - 4. Continuity, pumping, jerk

@Suite struct ZoomTimingContinuityTests {
    /// Two shots too close to allow a return stay one continuous move — the
    /// zoom-out/zoom-in pump is exactly what the geometry rule rules out.
    @Test func tightShotsDoNotPumpThroughFullFrame() {
        for gap in [0.05, 0.3, 0.6, 0.9] {
            let zoom = [ZoomTiming.auto(2, 1.0), ZoomTiming.auto(3.0 + gap, 1.0)]
            let tr = ZoomTiming.solve(zoom, duration: 8)
            for t in stride(from: 2.5, through: 3.6 + gap, by: 0.05) {
                #expect(ZoomTiming.scale(t, tr) >= 1.35,
                        "pumped to \(ZoomTiming.scale(t, tr))x at \(t) gap=\(gap)")
            }
        }
    }

    /// A forced break of an overlong bridged run must be a filmed return, not
    /// a cut: no per-tick teleport and no isolated velocity spike.
    @Test func forcedBreaksHaveNoTeleportsOrVelocitySpikes() {
        let zoom = (0..<14).map { ZoomTiming.auto(1.0 + Double($0) * 0.7, 0.5) }
        let tr = ZoomTiming.solve(zoom, duration: 14)
        let peakZ = (0..<tr.lz.count).map { abs(Double(tr.vz[$0])) }.max() ?? 0
        #expect(peakZ > 1e-3, "camera never moved")
        for k in 1..<tr.lz.count {
            let dx = abs(Double(tr.nx[k]) - Double(tr.nx[k - 1]))
            let dy = abs(Double(tr.ny[k]) - Double(tr.ny[k - 1]))
            let dz = abs(Double(tr.lz[k]) - Double(tr.lz[k - 1]))
            #expect(dx <= 0.02 && dy <= 0.02 && dz <= 0.02,
                    "teleport at \(k): dx=\(dx) dy=\(dy) dz=\(dz)")
            let jump = abs(Double(tr.vz[k]) - Double(tr.vz[k - 1]))
            #expect(jump <= peakZ * 0.5 + 1e-3, "scale velocity spike at \(k): \(jump)")
        }
    }

    /// Bounded jerk at the native rate. The quintic needs a finite runway; a
    /// squeeze would spike the third difference well past the shared limit.
    @Test func jerkIsBoundedAtTheBakeRate() {
        let layouts: [[ZoomSegment]] = [
            [ZoomTiming.auto(2, 1.0)],
            [ZoomTiming.auto(2, 1.0), ZoomTiming.auto(3.4, 1.0)],
            (0..<12).map { ZoomTiming.auto(1.0 + Double($0) * 0.7, 0.5) },
        ]
        for (n, zoom) in layouts.enumerated() {
            let tr = ZoomTiming.solve(zoom, duration: 13)
            let jz = ZoomTiming.peakJerk(tr.lz, rate: tr.rate)
            let jx = ZoomTiming.peakJerk(tr.nx, rate: tr.rate)
            let jy = ZoomTiming.peakJerk(tr.ny, rate: tr.rate)
            #expect(jz < MotionLimits.cameraJerk, "layout \(n): log-zoom jerk \(jz)")
            #expect(jx < MotionLimits.cameraJerk, "layout \(n): pan x jerk \(jx)")
            #expect(jy < MotionLimits.cameraJerk, "layout \(n): pan y jerk \(jy)")
        }
    }
}

// MARK: - 5. Determinism, export exactness, hostile input

@Suite struct ZoomTimingRobustnessTests {
    @Test func bakeIsDeterministicUnderChurn() {
        let zoom = [ZoomTiming.auto(2, 1.0), ZoomTiming.auto(4.5, 1.2, 2.3)]
        let p = CameraParams()
        let baseline = ZoomTiming.solve(zoom, duration: 9, p: p)
        for i in 0..<24 {
            _ = ZoomTiming.solve([ZoomTiming.auto(Double(i) * 0.13, 0.4)], duration: 9, p: p)
            #expect(ZoomTiming.solve(zoom, duration: 9, p: p) == baseline, "replay \(i) differs")
        }
    }

    @Test func exportRatesLandOnBakedTicks() {
        for fps in [60.0, 120.0, 240.0] {
            #expect((480 / fps).rounded() == 480 / fps, "480 Hz is not a multiple of \(fps)")
        }
        let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 8,
                             backingScale: 1, originX: 0, originY: 0)
        var tl = Timeline(duration: 8)
        tl.audio.speedRampsAuto = false
        tl = Director.derive(tl, input: DirectorInput(
            events: [InputEvent(t: 2, kind: .down, x: 700, y: 400)], source: src), revision: 1)
        guard let cam = tl.derived?.camera else { Issue.record("no camera track"); return }
        for fps in [60.0, 120.0, 240.0] {
            for f in 0..<Int(6 * fps) {
                let t = Double(f) / fps
                let tick = min(max(Int((t * cam.rate).rounded()), 0), cam.lz.count - 1)
                #expect(abs(t - Double(tick) / cam.rate) < 1e-12, "frame \(f) @ \(fps) missed a tick")
                let evaluated = tl.evaluate(at: t).cameraScale
                #expect(abs(Double(evaluated) - exp(Double(cam.lz[tick]))) < 2e-4,
                        "frame \(f) @ \(fps): evaluated != baked")
            }
        }
    }

    @Test func hostileInputsStayFiniteCappedAndFullAtTheEnd() {
        let bad = [
            ZoomSegment(start: .nan, end: 2, scale: 2, focus: .fixed(x: 0.5, y: 0.5), origin: .auto),
            ZoomSegment(start: 1, end: .infinity, scale: 2, focus: .fixed(x: 0.5, y: 0.5), origin: .auto),
            ZoomSegment(start: -4, end: -2, scale: 1e9, focus: .fixed(x: -3, y: 4), origin: .auto),
            ZoomSegment(start: 2, end: 3, scale: 1e12, focus: .fixed(x: 9, y: -9), origin: .auto),
            ZoomSegment(start: 4, end: 4.001, scale: 2, focus: .fixed(x: .nan, y: 0.5), origin: .auto),
            ZoomSegment(start: 5, end: 5.2, scale: .infinity, focus: .element(x: -1, y: -1, w: -2, h: -2), origin: .auto),
        ]
        var p = CameraParams(); p.maxScale = 1.5
        let tr = ZoomTiming.solve(bad, duration: 8, p: p)
        #expect(tr.lz.count > 1)
        for k in 0..<tr.lz.count {
            let z = Double(tr.lz[k]), x = Double(tr.nx[k]), y = Double(tr.ny[k])
            #expect(z.isFinite && x.isFinite && y.isFinite, "non-finite at \(k)")
            #expect(z >= -1e-6 && z <= log(p.maxScale) + 1e-5, "cap exceeded at \(k)")
            let half = 0.5 / exp(max(z, 0))
            #expect(x >= half - 2e-6 && x <= 1 - half + 2e-6, "feasible x at \(k)")
            #expect(y >= half - 2e-6 && y <= 1 - half + 2e-6, "feasible y at \(k)")
        }
        let last = tr.lz.count - 1
        #expect(abs(Double(tr.lz[last])) < 1e-5)
        #expect(abs(Double(tr.nx[last]) - 0.5) < 1e-5)
    }
}
