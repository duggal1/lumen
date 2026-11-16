import Foundation
import Testing
import LumenCore
import LumenProject
import LumenDirector

/// Arrival accuracy of the derived camera on the 60/120 fps evaluation path.
///
/// Two separate guarantees are covered here:
///  1. The quintic reconstruction is exact at every baked camera sample, so a
///     60/120 fps export (an integer number of camera ticks per frame) reads the
///     published positions with no residual scale error or inter-tick jitter.
///  2. The derived plan actually follows the input that aims it. The plan cache
///     is keyed by `inputDigest`; if that digest omits a field the planner reads,
///     a caret edit reuses the old plan and the camera lands on the old point.
private let arrivalSource = SourceInfo(width: 1920, height: 1080, fps: 60,
                                       duration: 8, backingScale: 1,
                                       originX: 0, originY: 0)

private func singleClickTimeline() -> Timeline {
    var tl = Timeline(duration: 8)
    tl.audio.speedRampsAuto = false
    return Director.derive(tl, input: DirectorInput(
        events: [InputEvent(t: 2, kind: .down, x: 700, y: 400, button: 0)],
        source: arrivalSource), revision: 1)
}

/// The camera target is the caret rect, with the surrounding field held fixed.
/// Only `caretX` (or the sample positions) differs between the two inputs, so a
/// cache key that ignores them returns a visibly stale arrival point.
private func typingInput(caretX: Double, sampleX: Double,
                         anchor: FocusAnchor? = nil) -> DirectorInput {
    let keys: [InputEvent] = [2.0, 2.2, 2.4].enumerated().map { i, t in
        InputEvent(t: t, kind: .keyDown, keyCode: UInt16(i), axFrameIndex: 1)
    }
    var frame = AXFrame(x: 280, y: 520, w: 1400, h: 36, anchor: anchor)
    frame.caret = AXFrame.Rect(x: caretX, y: 525, w: 2, h: 24)
    let samples = [2.0, 2.2, 2.4].map {
        TypingTrace.Sample(t: $0, x: sampleX, y: 538)
    }
    let trace = TypingTrace(t0: 2.0, t1: 2.4,
                            rect: CGRect(x: 280, y: 520, width: 1400, height: 36),
                            samples: samples)
    return DirectorInput(events: keys, source: arrivalSource, ax: [frame], typing: [trace])
}

// MARK: - Quintic reconstruction

/// The quintic Hermite reconstruction must reproduce x, v and a at both ends.
/// This is the property `qhm` relies on to land exactly on a published sample.
@Test func quinticMoveHitsBothEndpointsWithPublishedDerivatives() {
    let m = QuinticMove(t0: 0.25, T: 0.4, x0: 1.2, v0: 0.7, a0: -2.3,
                        x1: 3.4, v1: -0.5, a1: 1.1)
    let start = m.sample(0.25)
    #expect(abs(start.x - 1.2) < 1e-12, "x0 \(start.x)")
    #expect(abs(start.v - 0.7) < 1e-12, "v0 \(start.v)")
    #expect(abs(start.a - (-2.3)) < 1e-12, "a0 \(start.a)")
    let end = m.sample(0.65)
    #expect(abs(end.x - 3.4) < 1e-12, "x1 \(end.x)")
    #expect(abs(end.v - (-0.5)) < 1e-12, "v1 \(end.v)")
    #expect(abs(end.a - 1.1) < 1e-12, "a1 \(end.a)")
    // Rest outside the interval; no extrapolation drift.
    #expect(abs(m.sample(0.0).x - 1.2) < 1e-12)
    #expect(abs(m.sample(1.0).x - 3.4) < 1e-12)
}

/// Evaluate at the sample grid: position must equal the published camera track
/// at every tick (not just near an arrival), in both centre and log-scale.
@Test func evaluatedCameraMatchesBakedTrackAtEverySample() {
    let tl = singleClickTimeline()
    guard let d = tl.derived else { Issue.record("no derived tracks"); return }
    let cam = d.camera, size = d.sourceSize, rate = cam.rate
    let ticks = [0, 1, 2, 100, 239, 480, 960,
                 Int(1.9 * rate), Int(2.0 * rate), Int(2.5 * rate), cam.lz.count - 1]
    for k in ticks where k >= 0 && k < cam.lz.count {
        let frame = tl.evaluate(at: Double(k) / rate)
        let expectedX = Double(cam.nx[k]) * size.x
        let expectedY = Double(cam.ny[k]) * size.y
        let expectedScale = exp(Double(cam.lz[k]))
        #expect(abs(Double(frame.cameraCenter.x) - expectedX) < 1e-3, "centre x at tick \(k)")
        #expect(abs(Double(frame.cameraCenter.y) - expectedY) < 1e-3, "centre y at tick \(k)")
        #expect(abs(Double(frame.cameraScale) - expectedScale) < 1e-4, "scale at tick \(k)")
    }
}

// MARK: - Arrival on the output frame grid

/// The documented arrival time of an auto zoom is the click (CameraSolver
/// bakes the last quintic sample at `s.event == click`). In log space the
/// documented threshold is 0.98 (AccuracyReport / LumenCLI); assert 0.99.
@Test func zoomArrivesAtTargetByClickAt60And120Fps() {
    let tl = singleClickTimeline()
    guard let zoom = tl.zoom.first, zoom.scale > 1.001 else {
        Issue.record("no auto zoom"); return
    }
    let target = log(zoom.scale)
    let click = tl.timeMap.output(atSource: zoom.start)
    for fps in [60.0, 120.0] {
        // First output frame at or after the click; 480 Hz camera rate is an
        // integer multiple of both, so this lands on a baked camera sample.
        let frameTime = (click * fps).rounded(.up) / fps
        let scale = max(Double(tl.evaluate(at: frameTime).cameraScale), 1)
        let arrival = log(scale) / target
        #expect(arrival >= 0.99, "arrival \(arrival) at \(Int(fps)) fps (frame \(frameTime))")
    }
}

/// No per-frame acceleration discontinuity above the existing smoothness gate.
/// Sampling at 60/120 fps lands on exact camera ticks, so the acceleration
/// sequence is the discrete second difference of a smooth baked track; its
/// peak must stay within the published acceleration bound with headroom.
@Test func noAccelerationDiscontinuityAt60And120Fps() {
    let tl = singleClickTimeline()
    guard let cam = tl.derived?.camera else { Issue.record("no camera"); return }
    let bound = Double(cam.az.map { abs($0) }.max() ?? 0) * 8 + 1
    for fps in [60.0, 120.0] {
        let n = Int(4.0 * fps)
        var lz = [Double](repeating: 0, count: n)
        for i in 0..<n { lz[i] = log(Double(tl.evaluate(at: Double(i) / fps).cameraScale)) }
        var peakAccel = 0.0, peakStep = 0.0
        for i in 2..<(n - 1) {
            let a0 = (lz[i] - 2 * lz[i - 1] + lz[i - 2]) * fps * fps
            let a1 = (lz[i + 1] - 2 * lz[i] + lz[i - 1]) * fps * fps
            peakAccel = max(peakAccel, abs(a1))
            peakStep = max(peakStep, abs(a1 - a0))
        }
        #expect(peakAccel > 1e-3, "camera never moves at \(Int(fps)) fps")
        #expect(peakAccel <= bound, "peak accel \(peakAccel) > \(bound) at \(Int(fps)) fps")
        #expect(peakStep <= bound * 4, "accel step \(peakStep) > \(bound * 4) at \(Int(fps)) fps")
    }
}

// MARK: - Cache key follows the arrival target

/// A caret move INSIDE the same field must not move the camera at all. This is
/// the typing-stability contract: the field is the subject, the caret is only
/// evidence for which field to frame. Before it was deleted, the caret path was
/// the target and every keystroke shoved the shot around.
@Test func caretMoveInsideFieldKeepsCameraSteady() {
    var base = Timeline(duration: 8)
    base.audio.speedRampsAuto = false
    let first = typingInput(caretX: 320, sampleX: 320)
    let edited = typingInput(caretX: 1300, sampleX: 320)

    var cache = DeriveCache()
    _ = Director.derive(base, input: first, revision: 1, cache: &cache)
    let warm = Director.derive(base, input: edited, revision: 1, cache: &cache)
    let cold = Director.derive(base, input: edited, revision: 1)

    #expect(warm.zoom.count == 1 && cold.zoom.count == 1, "typing must produce one shot")
    let wc = warm.evaluate(at: 3.0).cameraCenter
    let cc = cold.evaluate(at: 3.0).cameraCenter
    #expect(abs(Double(wc.x) - Double(cc.x)) < 1, "warm centre \(wc.x) vs cold \(cc.x)")
    #expect(abs(Double(wc.y) - Double(cc.y)) < 1, "warm centre \(wc.y) vs cold \(cc.y)")
    // A caret move within one field is not a new subject, so it must not
    // retarget the shot. The two plans are the same shot by construction.
    let firstTL = Director.derive(base, input: first, revision: 1)
    let fc = firstTL.evaluate(at: 3.0).cameraCenter
    #expect(abs(Double(fc.x) - Double(cc.x)) < 1, "caret moved inside the field but retargeted (\(fc.x) vs \(cc.x))")
}

/// The caret still decides WHICH field is framed: it selects the smallest AX
/// field containing it. Frames and events are identical between the two inputs
/// — only the first caret position differs — so this is a pure test of the
/// digest covering the caret, and of the pipe that aims at the chosen field.
@Test func caretSelectsTheSmallestContainingField() {
    var base = Timeline(duration: 8)
    base.audio.speedRampsAuto = false

    // One wide container and one narrow field inside it. A caret at x = 250 is
    // inside both; a caret at x = 1200 is inside the container only.
    func input(caretX: Double) -> DirectorInput {
        var outer = AXFrame(x: 100, y: 400, w: 1700, h: 60)
        outer.caret = AXFrame.Rect(x: caretX, y: 405, w: 2, h: 24)
        var inner = AXFrame(x: 200, y: 405, w: 400, h: 50)
        inner.caret = AXFrame.Rect(x: 250, y: 405, w: 2, h: 24)
        let keys: [InputEvent] = [
            InputEvent(t: 2.0, kind: .keyDown, keyCode: 0, axFrameIndex: 1),
            InputEvent(t: 2.2, kind: .keyDown, keyCode: 1, axFrameIndex: 1),
            InputEvent(t: 2.4, kind: .keyDown, keyCode: 2, axFrameIndex: 2),
        ]
        return DirectorInput(events: keys, source: arrivalSource, ax: [outer, inner])
    }

    let near = input(caretX: 250)
    let far = input(caretX: 1200)

    var cache = DeriveCache()
    _ = Director.derive(base, input: near, revision: 1, cache: &cache)
    let warm = Director.derive(base, input: far, revision: 1, cache: &cache)
    let cold = Director.derive(base, input: far, revision: 1)

    #expect(warm.zoom.count == 1 && cold.zoom.count == 1, "both inputs frame one field")
    let wc = warm.evaluate(at: 3.0).cameraCenter
    let cc = cold.evaluate(at: 3.0).cameraCenter
    #expect(abs(Double(wc.x) - Double(cc.x)) < 1, "stale cached plan: warm \(wc.x) vs cold \(cc.x)")
    #expect(abs(Double(wc.y) - Double(cc.y)) < 1, "stale cached plan: warm \(wc.y) vs cold \(cc.y)")

    // The caret crossing out of the narrow field must genuinely change the shot.
    let nearTL = Director.derive(base, input: near, revision: 1)
    let nc = nearTL.evaluate(at: 3.0).cameraCenter
    #expect(abs(Double(nc.x) - Double(cc.x)) > 50,
            "caret left the inner field but the frame did not change (\(nc.x) vs \(cc.x))")
}

/// AX anchor freshness decides whether a caret is trusted at all. A change
/// from unresolved to resolved must change the plan, not reuse a stale one.
@Test func anchorFreshnessInvalidatesCachedZoomPlan() {
    var base = Timeline(duration: 8)
    base.audio.speedRampsAuto = false
    let unresolved = FocusAnchor(epoch: 0, sampledAt: 2.0, resolved: false)
    let resolved = FocusAnchor(epoch: 0, sampledAt: 2.0, resolved: true)
    let first = typingInput(caretX: 320, sampleX: 320, anchor: unresolved)
    let edited = typingInput(caretX: 320, sampleX: 320, anchor: resolved)

    var cache = DeriveCache()
    _ = Director.derive(base, input: first, revision: 1, cache: &cache)
    let warm = Director.derive(base, input: edited, revision: 1, cache: &cache)
    let cold = Director.derive(base, input: edited, revision: 1)

    let wc = warm.evaluate(at: 3.0).cameraCenter
    let cc = cold.evaluate(at: 3.0).cameraCenter
    #expect(abs(Double(wc.x) - Double(cc.x)) < 1, "warm anchor centre \(wc.x) vs cold \(cc.x)")
    #expect(abs(Double(wc.y) - Double(cc.y)) < 1, "warm anchor centre \(wc.y) vs cold \(cc.y)")
}
