import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// Brutal, headless camera-accuracy oracle. Nothing here opens a window, renders a
/// frame or reads a screenshot: every assertion is on the real 480 Hz bake (and,
/// where a frame matters, on `Timeline.evaluate`, the exact preview/export path).
///
/// The defect these tests pin is visible in all 18 reference screenshots: the
/// zoomed frame wanders left/right/top while the action is otherwise still. The
/// source is the seeded two-sine `.off` oscillator in the camera tilt loop,
/// not the shot geometry. Float is deleted; the filmed quintic stays.
enum CAM {
    static let source = SIMD2<Double>(1920, 1080)

    static func params(_ tilt: TiltMode = .off) -> CameraParams {
        var p = CameraParams()
        p.tilt = tilt
        return p
    }

    static func auto(_ start: Double, _ length: Double = 1.0,
                     scale: Double = 2, x: Double = 0.34, y: Double = 0.62) -> ZoomSegment {
        ZoomSegment(start: start, end: start + length, scale: scale,
                    focus: .fixed(x: x, y: y), origin: .auto)
    }

    static func solve(_ zoom: [ZoomSegment], duration: Double,
                      p: CameraParams = CameraParams()) -> CameraTrack {
        let tm = TimeMap(sourceDuration: duration)
        let cursor = CursorTrack(count: Int(duration * gridRate) + 1)
        return CameraSolver.solve(zoom: zoom, tm: tm, cursor: cursor, p: p,
                                  src: source, outDur: duration, loop: nil)
    }

    static func idx(_ t: Double, _ tr: CameraTrack) -> Int {
        min(max(Int((t * tr.rate).rounded()), 0), tr.lz.count - 1)
    }

    /// Longest span whose scale stays above `threshold`, in seconds.
    static func longestZoomedRun(_ tr: CameraTrack, threshold: Double = 1.35) -> Double {
        var best = 0.0, start: Double? = nil
        let dt = 1 / tr.rate
        for k in tr.lz.indices {
            if exp(Double(tr.lz[k])) > threshold {
                if start == nil { start = Double(k) * dt }
            } else if let s = start {
                best = max(best, Double(k) * dt - s)
                start = nil
            }
        }
        if let s = start { best = max(best, Double((tr.lz.count - 1)) * dt - s) }
        return best
    }

    static func derivedTimeline(_ events: [InputEvent], duration: Double) throws -> Timeline {
        let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: duration,
                             backingScale: 1, originX: 0, originY: 0)
        var tl = Timeline(duration: duration)
        tl.audio.speedRampsAuto = false
        return Director.derive(tl, input: DirectorInput(events: events, source: src), revision: 1)
    }
}

// MARK: - 1. Float is deleted, not merely disabled in the UI

@Suite struct CameraAccuracyNoFloatTests {
    /// The oscillator must be gone at the source: no tilt seed, no float angle,
    /// no matter how hostile, may produce a single degree of yaw or pitch.
    @Test func floatModeIsCompletelyFlatRegardlessOfKnobs() {
        var failures: [String] = []
        for seed in [UInt64(0), 1, 0xC11C, UInt64.max] {
            var p = CAM.params(.off)
            let tr = CAM.solve([CAM.auto(2), CAM.auto(4.5, 1.2, scale: 1.6, x: 0.7, y: 0.3)],
                               duration: 8, p: p)
            for k in tr.yaw.indices where tr.yaw[k] != 0 || tr.pitch[k] != 0 {
                failures.append("seed \(seed) tick \(k): yaw \(Double(tr.yaw[k])) pitch \(Double(tr.pitch[k]))")
                if failures.count > 4 { break }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    /// Dead knobs are removed, not left wired to nothing: changing them cannot
    /// change a single byte of the bake. This mutates every knob the recorded
    /// camera does not consume (tilt dynamics, live-only feel, upscaler, old
    /// planner policy) while keeping the knobs that do shape a fixed-shot bake
    /// identical. A single leak fails this.
    @Test func floatAndSeedKnobsCannotChangeTheBake() {
        let zoom = [CAM.auto(2), CAM.auto(4.5, 1.2, scale: 1.6, x: 0.7, y: 0.3)]
        let a = CAM.params(.off)
        var b = CAM.params(.off)
        b.omegaTilt = 60; b.maxYaw = 40; b.maxPitch = 40
        b.omegaZoom = 99; b.sensitivity = 1; b.shutter = 1
        b.maxSamples = 2; b.upscaleEnabled = false; b.upscaleMaxFactor = 2
        b.minScale = 3; b.baseScale = 3; b.zoomOutGap = 9; b.panThroughGap = 9
        #expect(CAM.solve(zoom, duration: 8, p: a) == CAM.solve(zoom, duration: 8, p: b),
                "a retired knob leaked into the recorded camera bake")
    }

    /// No zoom, no events: the camera must be numerically frozen for its whole
    /// life. A sine oscillator fails this even with an empty shot list.
    @Test func idleRecordingHasNoAutonomousMotion() {
        var failures: [String] = []
        for mode in TiltMode.allCases {
            let tr = CAM.solve([], duration: 5, p: CAM.params(mode))
            for k in tr.lz.indices {
                if tr.lz[k] != 0 || tr.nx[k] != 0.5 || tr.ny[k] != 0.5 {
                    failures.append("\(mode): pose moved at \(k)")
                }
                if (mode == .off || mode == .off) && (tr.yaw[k] != 0 || tr.pitch[k] != 0) {
                    failures.append("\(mode): tilt moved at \(k)")
                }
                if failures.count > 4 { break }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    /// A finished shot holds a fixed subject bit-for-bit still. Positional
    /// wander during the hold is the other half of the screenshot defect.
    @Test func fixedShotIsBitStillThroughTheHoldForEveryTiltMode() {
        for mode in TiltMode.allCases {
            let tr = CAM.solve([CAM.auto(2, 1.0)], duration: 7, p: CAM.params(mode))
            let a = CAM.idx(2.05, tr), b = CAM.idx(2.95, tr)
            guard b > a else { Issue.record("\(mode): no hold window"); continue }
            let lz = tr.lz[a], x = tr.nx[a], y = tr.ny[a]
            for k in (a + 1)...b {
                #expect(tr.lz[k] == lz, "\(mode): log-zoom drifted at \(k)")
                #expect(tr.nx[k] == x, "\(mode): x drifted at \(k)")
                #expect(tr.ny[k] == y, "\(mode): y drifted at \(k)")
            }
        }
    }
}

// MARK: - 2. Exact arrival and return at every export rate

@Suite struct CameraAccuracyExportRateTests {
    /// 480 Hz is an exact multiple of each export rate, so no frame may ever
    /// land between baked ticks — and the baked arrival must be settled before
    /// the click, held through it, then left from the segment end.
    @Test func arrivalAndReturnAreExactAt60_120And240() throws {
        let duration = 8.0
        let tl = try CAM.derivedTimeline(
            [InputEvent(t: 2, kind: .down, x: 700, y: 400)], duration: duration)
        let cam = try #require(tl.derived?.camera, "no camera track")
        let shot = try #require(tl.zoom.first, "planner emitted no shot")
        let target = Double(cam.lz[CAM.idx(2.0, cam)])

        for fps in [60.0, 120.0, 240.0] {
            let tickStride = 480 / fps
            #expect((tickStride - tickStride.rounded()).magnitude < 1e-12, "480 not a multiple of \(fps)")

            let before = Double(tl.evaluate(at: 1.95).cameraScale)
            #expect(abs(before - exp(target)) < 5e-3,
                    "\(fps): not settled before the click: \(before) vs \(exp(target))")

            let atEvent = Double(tl.evaluate(at: 2.0).cameraScale)
            #expect(abs(atEvent - exp(target)) < 5e-3, "\(fps): not exact at the click")

            let during = Double(tl.evaluate(at: (2.0 + shot.end) / 2).cameraScale)
            #expect(abs(during - exp(target)) < 5e-3, "\(fps): hold broke mid-action")

            var previous = during
            let firstReturn = shot.end + 0.04
            for f in Swift.stride(from: Int(firstReturn * fps), to: Int(4.6 * fps), by: 1) {
                let t = Double(f) / fps
                let tick = min(max(Int((t * cam.rate).rounded()), 0), cam.lz.count - 1)
                #expect(abs(t - Double(tick) / cam.rate) < 1e-12, "\(fps): frame \(f) missed a tick")
                let s = Double(tl.evaluate(at: t).cameraScale)
                #expect(s <= previous + 1e-4, "\(fps): zoom pumped at \(t)")
                #expect(s >= 1 - 1e-4, "\(fps): dipped below full frame at \(t)")
                previous = s
            }
            #expect(abs(Double(tl.evaluate(at: 4.8).cameraScale) - 1) < 1e-4,
                    "\(fps): no full-frame tail")
        }
    }

    /// A modelling-rate change must not change the answer: evaluating the same
    /// bake at 60, 120 and 240 gives the same pose to sub-pixel tolerance.
    @Test func exportRatesAgreeWithTheBake() throws {
        let tl = try CAM.derivedTimeline(
            [InputEvent(t: 2, kind: .down, x: 700, y: 400),
             InputEvent(t: 5, kind: .down, x: 1400, y: 300)], duration: 9)
        let cam = try #require(tl.derived?.camera)
        for fps in [60.0, 120.0, 240.0] {
            for f in 0..<Int(7 * fps) {
                let t = Double(f) / fps
                let k = CAM.idx(t, cam)
                let s = Double(tl.evaluate(at: t).cameraScale)
                #expect(abs(s - exp(Double(cam.lz[k]))) < 2e-4, "\(fps): frame \(f) != bake")
            }
        }
    }

    /// Replaying the same plan under churn is byte-identical at the bake level.
    @Test func bakeIsByteIdenticalUnderChurn() {
        let zoom = [CAM.auto(2), CAM.auto(4.5, 1.2, scale: 2.3, x: 0.7, y: 0.3)]
        var p = CAM.params(.off);        let baseline = CAM.solve(zoom, duration: 9, p: p)
        for i in 0..<16 {
            _ = CAM.solve([CAM.auto(Double(i) * 0.11, 0.4)], duration: 9, p: p)
            #expect(CAM.solve(zoom, duration: 9, p: p) == baseline, "replay \(i) differs")
        }
    }
}

// MARK: - 3. Short holds, full-frame trailing silence

@Suite struct CameraAccuracyHoldTests {
    @Test func chainedShotsReturnToFullFrameAndNeverHoldForTenSeconds() {
        let zoom = (0..<14).map { CAM.auto(1.0 + Double($0) * 0.7, 0.5) }
        let tr = CAM.solve(zoom, duration: 15, p: CAM.params(.off))
        #expect(CAM.longestZoomedRun(tr) < 7.0, "run \(CAM.longestZoomedRun(tr))s")

        let lastEnd = zoom.last!.end
        for k in CAM.idx(lastEnd + 1.2, tr)..<tr.lz.count {
            #expect(abs(Double(tr.lz[k])) < 1e-5, "trailing silence not full at \(k)")
            #expect(abs(Double(tr.nx[k]) - 0.5) < 1e-5, "trailing x not centred at \(k)")
            #expect(abs(Double(tr.ny[k]) - 0.5) < 1e-5, "trailing y not centred at \(k)")
        }
    }

    @Test func lastMomentShotStillLandsFullyFramed() {
        for end in [8.5, 8.9, 9.0] {
            let tr = CAM.solve([CAM.auto(end - 1, 1)], duration: 9,
                               p: CAM.params(.off))
            let last = tr.lz.count - 1
            #expect(abs(Double(tr.lz[last])) < 1e-5, "end=\(end): still zoomed")
            #expect(abs(Double(tr.nx[last]) - 0.5) < 1e-5)
            #expect(abs(Double(tr.ny[last]) - 0.5) < 1e-5)
            #expect(tr.yaw[last] == 0 && tr.pitch[last] == 0)
        }
    }
}

// MARK: - 4. Hostile input

@Suite struct CameraAccuracyHostileTests {
    @Test func nonFiniteControlsStillProduceFlatFiniteFullFrameTrack() {
        let bad = [
            ZoomSegment(start: .nan, end: 2, scale: 2, focus: .fixed(x: 0.5, y: 0.5), origin: .auto),
            ZoomSegment(start: 1, end: .infinity, scale: 2, focus: .fixed(x: 0.5, y: 0.5), origin: .auto),
            ZoomSegment(start: -4, end: -2, scale: 1e9, focus: .fixed(x: -3, y: 4), origin: .auto),
            ZoomSegment(start: 2, end: 3, scale: 1e12, focus: .fixed(x: 9, y: -9), origin: .auto),
            ZoomSegment(start: 4, end: 4.001, scale: 2, focus: .fixed(x: .nan, y: 0.5), origin: .auto),
            ZoomSegment(start: 5, end: 5.2, scale: .infinity, focus: .element(x: -1, y: -1, w: -2, h: -2), origin: .auto),
        ]
        var p = CAM.params(.off)
        p.maxScale = 1.5
        p.maxYaw = .nan
        p.maxPitch = .infinity
        p.omegaTilt = .nan
        let tr = CAM.solve(bad, duration: 8, p: p)
        #expect(tr.lz.count > 1)
        for k in tr.lz.indices {
            let z = Double(tr.lz[k]), x = Double(tr.nx[k]), y = Double(tr.ny[k])
            #expect(z.isFinite && x.isFinite && y.isFinite, "non-finite pose at \(k)")
            #expect(tr.yaw[k].isFinite && tr.pitch[k].isFinite, "non-finite tilt at \(k)")
            #expect(tr.yaw[k] == 0 && tr.pitch[k] == 0, "float drifted at \(k)")
            #expect(z >= -1e-6 && z <= log(1.5) + 1e-5, "cap exceeded at \(k)")
            let half = 0.5 / exp(max(z, 0))
            #expect(x >= half - 2e-6 && x <= 1 - half + 2e-6, "infeasible x at \(k)")
            #expect(y >= half - 2e-6 && y <= 1 - half + 2e-6, "infeasible y at \(k)")
        }
        let last = tr.lz.count - 1
        #expect(abs(Double(tr.lz[last])) < 1e-5)
        #expect(abs(Double(tr.nx[last]) - 0.5) < 1e-5)
    }

    /// Every hostile tilt knob is guarded with `isFinite`, but `maxScale` is
    /// fed straight into `log(...)`. An infinite or NaN cap (from a corrupt
    /// project or a hostile plan) must still yield a finite, bounded bake.
    @Test func infiniteMaxScaleNeverLeaksNonFinitePose() {
        for cap in [Double.infinity, 1e300, Double.nan] {
            var p = CAM.params(.off)
            p.maxScale = cap
            let zoom = [ZoomSegment(start: 1, end: 3, scale: .infinity,
                                    focus: .fixed(x: 0.4, y: 0.6), origin: .auto),
                        CAM.auto(4, 1)]
            let tr = CAM.solve(zoom, duration: 7, p: p)
            #expect(tr.lz.count > 1, "cap \(cap): empty track")
            for k in tr.lz.indices {
                #expect(Double(tr.lz[k]).isFinite && Double(tr.nx[k]).isFinite && Double(tr.ny[k]).isFinite,
                        "cap \(cap): non-finite pose at \(k) (z=\(tr.lz[k]))")
                #expect(tr.vz[k].isFinite && tr.az[k].isFinite, "cap \(cap): non-finite derivative at \(k)")
            }
        }
    }

    /// `centerOffset` is a single static framing bias. For a follow shot that
    /// carries a recorded path it is applied once in `pathCenters` and (wrongly)
    /// a second time in `holdCenter`; global-cursor follow applies it only once.
    /// At 2x the one-application shift is -offset * exp(-log2) = -offset/2.
    @Test func followPathCenterOffsetIsAppliedExactlyOnce() {
        let seg = ZoomSegment(start: 1, end: 3, scale: 2, focus: .follow, origin: .auto)
        let path: [(t: Double, c: SIMD2<Double>)] = [
            (t: 0, c: SIMD2(0.5, 0.5)), (t: 1, c: SIMD2(0.5, 0.5)),
            (t: 2, c: SIMD2(0.5, 0.5)), (t: 3, c: SIMD2(0.5, 0.5)),
        ]
        func holdX(_ offset: Double) -> Double {
            var p = CAM.params(.off)
            p.centerOffsetX = offset
            let tm = TimeMap(sourceDuration: 5)
            let cursor = CursorTrack(count: Int(5 * gridRate) + 1)
            let tr = CameraSolver.solve(zoom: [seg], tm: tm, cursor: cursor, p: p,
                                        src: CAM.source, outDur: 5, loop: nil,
                                        follow: [seg.id: path], cancelled: { false })!
            return Double(tr.nx[CAM.idx(2.0, tr)])
        }
        let zero = holdX(0), shifted = holdX(0.2)
        #expect(abs((shifted - zero) - (-0.1)) < 2e-3,
                "centerOffset applied \(abs(shifted - zero) / 0.1)x; expected once (-0.1), got shift \(shifted - zero)")
    }

    @Test func degenerateDurationsScalesAndCentresStayBounded() {
        let cases: [(Double, Double, Double)] = [
            (0, 0, 1), (-1, 0.5, 2), (2, 2, 2), (2, 0.000001, 1e9),
            (1e6, 0.5, 2), (3, -1, -5),
        ]
        for (start, length, scale) in cases {
            let tr = CAM.solve([CAM.auto(start, length, scale: scale, x: 1e9, y: -1e9)],
                               duration: 6, p: CAM.params(.off))
            #expect(tr.lz.count > 1)
            for k in tr.lz.indices {
                #expect(Double(tr.lz[k]).isFinite && Double(tr.nx[k]).isFinite)
                #expect(tr.yaw[k] == 0 && tr.pitch[k] == 0)
            }
        }
    }
}
