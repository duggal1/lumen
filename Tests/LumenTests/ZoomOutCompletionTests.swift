import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// Regression cover for "when it zooms in, it doesn't zoom out".
///
/// The camera track must always finish its last move at exactly 1.0× and a
/// neutral (0.5, 0.5) center, even when the last shot's hold runs into the end
/// of the composition and leaves no slack for the tail. These tests read the
/// baked track directly so they measure the generated geometry, not the
/// renderer's interpolation of it.
private enum ZoomOutProbe {
    static func index(_ t: Double, _ track: CameraTrack) -> Int {
        min(max(Int((t * track.rate).rounded()), 0), track.lz.count - 1)
    }

    static func scale(_ t: Double, _ track: CameraTrack) -> Double {
        exp(Double(track.lz[index(t, track)]))
    }

    static func center(_ t: Double, _ track: CameraTrack) -> SIMD2<Double> {
        let i = index(t, track)
        return SIMD2(Double(track.nx[i]), Double(track.ny[i]))
    }

    /// The exit must be one finite descent: strictly non-increasing, never
    /// below full frame, and no second move after it has settled.
    static func expectCleanDescent(_ track: CameraTrack, from t0: Double, to t1: Double) {
        var previous = scale(t0, track)
        let step = 1 / track.rate
        var k = 1
        while t0 + Double(k) * step <= t1 + step * 0.5 {
            let s = scale(t0 + Double(k) * step, track)
            #expect(s >= 1 - 1e-6, "zoom-out dipped below 1.0: \(s)")
            #expect(s <= previous + 1e-5, "zoom-out rose: \(s) after \(previous)")
            previous = s
            k += 1
        }
        #expect(previous <= 1 + 1e-3, "zoom-out never arrived: \(previous)")
    }

    static func expectFullFrame(_ track: CameraTrack, at t: Double) {
        let s = scale(t, track)
        let c = center(t, track)
        #expect(abs(s - 1) < 1e-3, "scale at \(t) = \(s), expected 1.0")
        #expect(abs(c.x - 0.5) < 1e-3, "center x at \(t) = \(c.x)")
        #expect(abs(c.y - 0.5) < 1e-3, "center y at \(t) = \(c.y)")
    }
}

@Test func singleEarlyClickReturnsToFullFrameWithinBoundedTime() {
    let src = SIMD2<Double>(1920, 1080)
    let tm = TimeMap(sourceDuration: 12)
    let cursor = CursorTrack(count: Int(12 * gridRate) + 1)
    let zoom = [ZoomSegment(id: UUID(), start: 2, end: 3, scale: 2,
                            focus: .fixed(x: 0.5, y: 0.5), origin: .auto)]
    let track = CameraSolver.solve(zoom: zoom, tm: tm, cursor: cursor, p: CameraParams(),
                                   src: src, outDur: 12, loop: nil)

    #expect(ZoomOutProbe.scale(1.0, track) < 1.01)
    #expect(ZoomOutProbe.scale(2.5, track) > 1.5)
    // Default tail is 0.7 s; one second after the shot ends is settled.
    ZoomOutProbe.expectFullFrame(track, at: 4.0)
    ZoomOutProbe.expectCleanDescent(track, from: 3.0, to: 4.0)
    ZoomOutProbe.expectFullFrame(track, at: 11.99)
}

@Test func clickNearEndOfRecordingStillGetsCompleteZoomOut() {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 6,
                         backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 6)
    tl.audio.speedRampsAuto = false
    let click = InputEvent(t: 5.5, kind: .down, x: 900, y: 450)
    tl = Director.derive(tl, input: DirectorInput(events: [click], source: src), revision: 1)
    #expect(tl.zoom.count == 1)
    guard let shot = tl.zoom.first else { return }
    // The planner clamps the last hold to the end of the recording. This is
    // the reported case: no slack is left after the hold for the tail.
    #expect(shot.end >= 5.95, "end = \(shot.end)")

    let frame = tl.evaluate(at: 5.5)
    #expect(Double(frame.cameraScale) > 1.3, "the zoom-in must still happen")

    guard let track = tl.derived?.camera else {
        Issue.record("no derived camera track")
        return
    }
    // Exact arrival on the final sample, with a neutral center.
    ZoomOutProbe.expectFullFrame(track, at: 6.0)
    // And the same at the evaluated (interpolated) last frame.
    let last = tl.evaluate(at: 5.999)
    #expect(abs(Double(last.cameraScale) - 1) < 1e-3, "evaluate scale = \(last.cameraScale)")
    ZoomOutProbe.expectCleanDescent(track, from: 5.5, to: 6.0)
}

@Test func consecutiveBridgedScenesReturnToFullFrameAtEnd() {
    let src = SIMD2<Double>(1920, 1080)
    let tm = TimeMap(sourceDuration: 6)
    let cursor = CursorTrack(count: Int(6 * gridRate) + 1)
    let zoom = [
        ZoomSegment(id: UUID(), start: 2.0, end: 3.2, scale: 2.0,
                    focus: .fixed(x: 0.3, y: 0.5), origin: .auto),
        ZoomSegment(id: UUID(), start: 4.6, end: 6.0, scale: 2.5,
                    focus: .fixed(x: 0.7, y: 0.5), origin: .auto),
    ]
    let track = CameraSolver.solve(zoom: zoom, tm: tm, cursor: cursor, p: CameraParams(),
                                   src: src, outDur: 6, loop: nil)
    // The two shots are close enough to bridge: the handoff must stay zoomed
    // (no zoom-out-and-back-in between them), so only the final tail returns.
    #expect(ZoomOutProbe.scale(3.3, track) > 1.5, "bridged handoff should not dip to 1.0")
    #expect(ZoomOutProbe.scale(4.8, track) > 1.5)
    ZoomOutProbe.expectFullFrame(track, at: 6.0)
    ZoomOutProbe.expectCleanDescent(track, from: 4.8, to: 6.0)
}

@Test func zeroSlackTailStillArrivesInBoundedTime() {
    // Hand-built worst case: the final shot ends exactly at the composition
    // end, so the naive `fill(off, min(off + tail, outDur))` degenerates to a
    // single sample and silently leaves the camera zoomed in.
    let src = SIMD2<Double>(1920, 1080)
    let tm = TimeMap(sourceDuration: 4)
    let cursor = CursorTrack(count: Int(4 * gridRate) + 1)
    let zoom = [ZoomSegment(id: UUID(), start: 1.0, end: 4.0, scale: 2.4,
                            focus: .fixed(x: 0.42, y: 0.58), origin: .auto)]
    let track = CameraSolver.solve(zoom: zoom, tm: tm, cursor: cursor, p: CameraParams(),
                                   src: src, outDur: 4, loop: nil)
    #expect(ZoomOutProbe.scale(2.0, track) > 1.5)
    ZoomOutProbe.expectFullFrame(track, at: 4.0)
    ZoomOutProbe.expectCleanDescent(track, from: 2.0, to: 4.0)
}
