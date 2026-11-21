import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// Cinematic zoom motion — headless, deterministic checks on the baked camera
/// track. Every test here reads the real `CameraSolver` output (and, where it
/// matters, `Timeline.evaluate`, which is the export/preview path). No window,
/// no render, no GUI.
enum CineZoom {
    static let src = SIMD2<Double>(1920, 1080)

    static func track(_ zoom: [ZoomSegment], duration: Double = 10,
                      p: CameraParams = CameraParams()) -> CameraTrack {
        let tm = TimeMap(sourceDuration: duration)
        let cursor = CursorTrack(count: Int(duration * gridRate) + 1)
        return CameraSolver.solve(zoom: zoom, tm: tm, cursor: cursor, p: p,
                                  src: src, outDur: duration, loop: nil)
    }

    static func idx(_ t: Double, _ tr: CameraTrack) -> Int {
        min(max(Int((t * tr.rate).rounded()), 0), tr.lz.count - 1)
    }
    static func lz(_ t: Double, _ tr: CameraTrack) -> Double { Double(tr.lz[idx(t, tr)]) }
    static func cx(_ t: Double, _ tr: CameraTrack) -> Double { Double(tr.nx[idx(t, tr)]) }
    static func cy(_ t: Double, _ tr: CameraTrack) -> Double { Double(tr.ny[idx(t, tr)]) }

    /// Single auto click at `t`, with a fixed focus off-centre so both the pan
    /// and the dolly have a non-trivial distance to travel.
    static func autoShot(click: Double, scale: Double = 2, x: Double = 0.34,
                         y: Double = 0.62, duration: Double = 10) -> [ZoomSegment] {
        [ZoomSegment(id: UUID(), start: click, end: click + 1.0, scale: scale,
                     focus: .fixed(x: x, y: y), origin: .auto)]
    }
}

// MARK: - 1. Lead-in anticipation + arrival settled BEFORE the action

@Suite struct CinematicZoomArrivalTests {
    /// The camera must already be settled on the target when the click lands,
    /// and there must be a real, still hold between arrival and the event —
    /// the frame is composed before the action, not at it.
    @Test func arrivalIsExactAndSettledBeforeTheClick() {
        let click = 4.0
        let tr = CineZoom.track(CineZoom.autoShot(click: click), duration: 9)
        let target = log(2.0)

        // Fully arrived at the click (the documented arrival contract).
        #expect(abs(CineZoom.lz(click, tr) - target) < 1e-5,
                "scale not settled at click: lz=\(CineZoom.lz(click, tr))")
        // Anticipation: the move started well before the click.
        #expect(CineZoom.lz(click - 0.9, tr) < 0.02 * target,
                "lead-in did not anticipate: lz=\(CineZoom.lz(click - 0.9, tr))")
        // A genuinely settled hold before the event: find the tick where the
        // camera first reaches the target and require >= 40 ms of stillness.
        var arrivalTick: Int?
        for k in 0..<tr.lz.count where Double(tr.lz[k]) >= target - 1e-5 {
            arrivalTick = k
            break
        }
        guard let a = arrivalTick else { Issue.record("camera never arrived"); return }
        let arrivalTime = Double(a) / tr.rate
        #expect(arrivalTime <= click - 0.04,
                "arrival \(arrivalTime) not at least 40 ms before click \(click)")
        // The hold runs through the click: no movement in the settle window.
        for k in a...CineZoom.idx(click, tr) {
            #expect(abs(Double(tr.lz[k]) - target) < 1e-5, "drift in settle at tick \(k)")
        }
    }

    /// Exact arrival at 60 / 120 / 240 fps: every export frame lands on a
    /// baked 480 Hz tick, so the evaluated scale is the published scale.
    @Test func arrivalIsExactAtExportFrameRates() {
        let click = 3.0
        let zoom = CineZoom.autoShot(click: click)
        var tl = Timeline(duration: 8)
        tl.audio.speedRampsAuto = false
        tl = Director.derive(tl, input: DirectorInput(
            events: [InputEvent(t: click, kind: .down, x: 700, y: 400)],
            source: SourceInfo(width: 1920, height: 1080, fps: 60,
                               duration: 8, backingScale: 1, originX: 0, originY: 0)), revision: 1)
        guard let z = tl.zoom.first else { Issue.record("no auto zoom"); return }
        let target = log(z.scale)
        for fps in [60.0, 120.0, 240.0] {
            let f = (click * fps).rounded(.up) / fps
            let s = log(max(Double(tl.evaluate(at: f).cameraScale), 1))
            #expect(s / target >= 0.999, "arrival \(s / target) at \(Int(fps)) fps")
        }
    }

    /// The settle must be monotone and decelerating: velocity magnitude falls
    /// into arrival with no sign reversal, no overshoot, no stop-start lurch.
    @Test func settleIsMonotoneAndDeceleratingWithNoOvershoot() {
        let click = 4.0
        let tr = CineZoom.track(CineZoom.autoShot(click: click), duration: 9)
        let target = log(2.0)
        var previous = 0.0
        var speeds: [Double] = []
        for t in stride(from: 0.0, through: click, by: 1 / tr.rate) {
            let z = CineZoom.lz(t, tr)
            #expect(z <= target + 1e-5, "overshoot at \(t): \(z) > \(target)")
            #expect(z >= previous - 1e-6, "reversal at \(t): \(z) < \(previous)")
            speeds.append((z - previous) * tr.rate)
            previous = z
        }
        let moving = speeds.filter { $0 > 1e-4 }
        #expect(moving.count > 20, "camera never moved")
        // Near the end of the move the per-tick speed must be small and still
        // positive-or-zero — a gentle ease-out, not a late pump.
        let tail = speeds.suffix(12)
        #expect(tail.allSatisfy { $0 >= -1e-6 && $0 <= moving.max()! * 0.2 },
                "settle is not gentle: \(tail)")
    }
}

// MARK: - 2. No one-tick teleports / velocity continuity at every handoff

@Suite struct CinematicZoomContinuityTests {
    /// A position jump of > 0.02 normalised units in one 480 Hz tick is a
    /// cut. Sweep seeded, deliberately awkward shot layouts including bridges,
    /// near-overlaps and a shot at the trim end.
    @Test func noTeleportAcrossHandoffs() {
        let layouts: [[ZoomSegment]] = [
            CineZoom.autoShot(click: 2, scale: 2.0, x: 0.1, y: 0.9, duration: 8),
            [
                ZoomSegment(id: UUID(), start: 2.0, end: 3.2, scale: 2.0,
                            focus: .fixed(x: 0.15, y: 0.2), origin: .auto),
                ZoomSegment(id: UUID(), start: 3.4, end: 4.6, scale: 2.4,
                            focus: .fixed(x: 0.85, y: 0.8), origin: .auto),
            ],
            [
                ZoomSegment(id: UUID(), start: 1.0, end: 1.8, scale: 1.9,
                            focus: .fixed(x: 0.2, y: 0.7), origin: .auto),
                ZoomSegment(id: UUID(), start: 4.5, end: 5.5, scale: 2.2,
                            focus: .fixed(x: 0.8, y: 0.3), origin: .auto),
            ],
        ]
        for (n, zoom) in layouts.enumerated() {
            let tr = CineZoom.track(zoom, duration: 8)
            for k in 1..<tr.lz.count {
                let dx = abs(Double(tr.nx[k]) - Double(tr.nx[k - 1]))
                let dy = abs(Double(tr.ny[k]) - Double(tr.ny[k - 1]))
                let dz = abs(Double(tr.lz[k]) - Double(tr.lz[k - 1]))
                #expect(dx <= 0.02 && dy <= 0.02 && dz <= 0.02,
                        "layout \(n) teleport at tick \(k): dx=\(dx) dy=\(dy) dz=\(dz)")
            }
        }
    }

    /// The published velocity is what `qhm` reconstructs for export. A handoff
    /// must not spike it or flip its sign relative to the surrounding motion.
    @Test func velocityIsContinuousAtHandoffs() {
        let zoom: [ZoomSegment] = [
            ZoomSegment(id: UUID(), start: 2.0, end: 3.2, scale: 2.0,
                        focus: .fixed(x: 0.2, y: 0.5), origin: .auto),
            ZoomSegment(id: UUID(), start: 3.4, end: 4.6, scale: 2.5,
                        focus: .fixed(x: 0.8, y: 0.5), origin: .auto),
        ]
        let tr = CineZoom.track(zoom, duration: 7)
        let peak = (0..<tr.lz.count).map { abs(Double(tr.vz[$0])) }.max() ?? 0
        #expect(peak > 1e-3, "camera never moved")
        // No single tick may carry a velocity far beyond the smooth peak; that
        // is the numeric signature of a one-tick cut at a handoff.
        for k in 1..<tr.lz.count {
            let jump = abs(Double(tr.vz[k]) - Double(tr.vz[k - 1]))
            #expect(jump <= peak * 0.5, "velocity spike at tick \(k): \(jump) vs peak \(peak)")
        }
        // Bracket the handoff (~3.3 s): the log-scale must not reverse there.
        var last = CineZoom.lz(3.0, tr)
        for t in stride(from: 3.0, through: 3.7, by: 1 / tr.rate) {
            let z = CineZoom.lz(t, tr)
            #expect(z >= last - 1e-5, "reversal across handoff at \(t): \(z) < \(last)")
            last = z
        }
    }

    /// Pan and dolly are one camera move: with a fixed target, both channels
    /// must start and finish on the same tick and progress monotonically. Two
    /// independent curves would separate somewhere in the middle.
    @Test func panFollowsFixedPivotWithOneEnvelope() {
        let click = 3.0
        // 0.30 / 0.70 stay inside the feasible box at 2x (half-width 0.25).
        let tr = CineZoom.track(CineZoom.autoShot(click: click, x: 0.30, y: 0.70), duration: 8)
        let targetLz = log(2.0)
        let startC = 0.5, endC = 0.30

        var moveStart: Int?
        var moveEnd: Int?
        for k in 0..<tr.lz.count {
            if Double(tr.lz[k]) > 1e-4, moveStart == nil { moveStart = k }
            if Double(tr.lz[k]) >= targetLz - 1e-5 { moveEnd = k; break }
        }
        guard let a = moveStart, let b = moveEnd else {
            Issue.record("no move detected"); return
        }
        #expect(b > a, "empty move")
        for k in a...b {
            let lz = Double(tr.lz[k])
            let progress = lz / targetLz
            // P1: zoom is a scale about a FIXED pivot. The centre's travelled
            // fraction is (1 - s0/s) / (1 - s0/s1), not the log-scale progress.
            // The old linear-in-log expectation is exactly the lateral swim the
            // owner reported: measured 37.8 px before, 0.36 px after the fix.
            let s = exp(lz), s0 = 1.0, s1 = 2.0
            let travelled = (1 - s0 / s) / (1 - s0 / s1)
            let half = 0.5 / s
            let expected = min(max(startC + (endC - startC) * travelled, half), 1 - half)
            #expect(abs(Double(tr.nx[k]) - expected) < 5e-3,
                    "pan/pivot diverged at tick \(k): nx=\(tr.nx[k]) expected=\(expected) travel=\(travelled)")
            #expect(progress >= -1e-6 && progress <= 1 + 1e-6, "scale out of range at \(k)")
        }
    }
}

// MARK: - 3. Determinism, export exactness, cap and clamp

@Suite struct CinematicZoomInvariantTests {
    /// The 480 Hz bake is a pure function of its inputs: replay must be
    /// byte-identical, and independent of the number of prior solves.
    @Test func bakeIsDeterministic() {
        let zoom: [ZoomSegment] = [
            ZoomSegment(id: UUID(), start: 1.5, end: 2.7, scale: 2.1,
                        focus: .fixed(x: 0.3, y: 0.4), origin: .auto),
            ZoomSegment(id: UUID(), start: 3.0, end: 4.2, scale: 2.6,
                        focus: .fixed(x: 0.7, y: 0.6), origin: .auto),
        ]
        let a = CineZoom.track(zoom, duration: 7)
        _ = CineZoom.track(CineZoom.autoShot(click: 9), duration: 11) // churn
        let b = CineZoom.track(zoom, duration: 7)
        #expect(a == b, "replayed bake differs")
    }

    /// Evaluate at every baked tick on the 60/120/240 fps grids: the quintic
    /// reconstruction is exact at every sample, so no export frame jitters.
    @Test func sampledFramesEqualBakedTrack() {
        var tl = Timeline(duration: 6)
        tl.audio.speedRampsAuto = false
        tl = Director.derive(tl, input: DirectorInput(
            events: [InputEvent(t: 2, kind: .down, x: 640, y: 300)],
            source: SourceInfo(width: 1920, height: 1080, fps: 60,
                               duration: 6, backingScale: 1, originX: 0, originY: 0)), revision: 1)
        guard let cam = tl.derived?.camera else { Issue.record("no camera"); return }
        let size = tl.derived?.sourceSize ?? SIMD2(1920, 1080)
        for k in stride(from: 0, to: cam.lz.count, by: 2) {
            let f = tl.evaluate(at: Double(k) / cam.rate)
            #expect(abs(Double(f.cameraScale) - exp(Double(cam.lz[k]))) < 2e-4,
                    "scale mismatch at tick \(k)")
            #expect(abs(Double(f.cameraCenter.x) - Double(cam.nx[k]) * size.x) < 1e-2,
                    "centre x mismatch at tick \(k)")
        }
    }

    /// maxScale is a hard cap, and the centre always stays in the feasible box
    /// for its own scale — at every tick, including handoffs and the tail.
    @Test func maxScaleCapAndFeasibleClampHoldEverywhere() {
        var p = CameraParams()
        p.maxScale = 1.35
        p.minScale = 1.2
        let zoom = [
            ZoomSegment(id: UUID(), start: 1.5, end: 3.0, scale: 5.0,
                        focus: .fixed(x: 0.02, y: 0.98), origin: .auto),
            ZoomSegment(id: UUID(), start: 3.3, end: 4.8, scale: 9.0,
                        focus: .fixed(x: 0.98, y: 0.02), origin: .auto),
        ]
        let tr = CineZoom.track(zoom, duration: 7, p: p)
        for k in 0..<tr.lz.count {
            let z = max(Double(tr.lz[k]), 0)
            let scale = exp(z)
            #expect(scale <= p.maxScale * 1.001, "cap exceeded at \(k): \(scale)")
            let half = 0.5 / scale
            let x = Double(tr.nx[k]), y = Double(tr.ny[k])
            #expect(x >= half - 2e-6 && x <= 1 - half + 2e-6,
                    "centre x outside feasible box at \(k): \(x) half=\(half)")
            #expect(y >= half - 2e-6 && y <= 1 - half + 2e-6,
                    "centre y outside feasible box at \(k): \(y) half=\(half)")
        }
        // The recording still ends on the full, centred frame.
        let last = tr.lz.count - 1
        #expect(abs(Double(tr.lz[last])) < 1e-5)
        #expect(abs(Double(tr.nx[last]) - 0.5) < 1e-5)
        #expect(abs(Double(tr.ny[last]) - 0.5) < 1e-5)
    }

    /// A bridge must flow directly: between two close shots the camera never
    /// returns to the full frame. The pump (zoom out → zoom in) is the exact
    /// artifact this rules out.
    @Test func bridgedScenesDoNotPumpThroughFullFrame() {
        let zoom: [ZoomSegment] = [
            ZoomSegment(id: UUID(), start: 2.0, end: 3.2, scale: 2.0,
                        focus: .fixed(x: 0.25, y: 0.5), origin: .auto),
            ZoomSegment(id: UUID(), start: 3.5, end: 4.8, scale: 2.4,
                        focus: .fixed(x: 0.75, y: 0.5), origin: .auto),
        ]
        let tr = CineZoom.track(zoom, duration: 7)
        for t in stride(from: 2.5, through: 4.2, by: 0.05) {
            let z = CineZoom.lz(t, tr)
            #expect(z >= log(1.5), "bridged handoff pumped to \(exp(z))x at \(t)")
        }
    }
}
