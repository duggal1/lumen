import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// A1 / R2-R3 — the real baked camera path, sampled far above output frame rate.
/// No mocks: every number comes from Director.derive + Timeline.evaluate or the
/// published (480 Hz) camera track. Bounds are deliberately tighter than a frame.
private enum A1Smooth {
    static func source(_ duration: Double) -> SourceInfo {
        SourceInfo(width: 1920, height: 1080, fps: 60, duration: duration,
                   backingScale: 1, originX: 0, originY: 0)
    }

    static func manualTimeline(_ duration: Double, zoom: [ZoomSegment]) -> Timeline {
        var tl = Timeline(duration: duration)
        tl.camera.autoZoom = false
        tl.camera.maxScale = 2.4
        tl.audio.speedRampsAuto = false
        tl.zoom = zoom
        return Director.derive(tl, input: DirectorInput(events: [], source: source(duration)), revision: 1)
    }

    static func clickTimeline(_ duration: Double, _ t: Double) -> Timeline {
        var tl = Timeline(duration: duration)
        tl.audio.speedRampsAuto = false
        return Director.derive(tl, input: DirectorInput(
            events: [InputEvent(t: t, kind: .down, x: 700, y: 420)], source: source(duration)), revision: 1)
    }

    static func frame(_ tl: Timeline, _ t: Double) -> (s: Double, c: SIMD2<Double>) {
        let f = tl.evaluate(at: t)
        return (Double(f.cameraScale), SIMD2(Double(f.cameraCenter.x), Double(f.cameraCenter.y)))
    }

    /// The pivot implied by two samples of a pure scale about a fixed point.
    static func pivot(_ a: (s: Double, c: SIMD2<Double>), _ b: (s: Double, c: SIMD2<Double>)) -> SIMD2<Double> {
        (b.c * b.s - a.c * a.s) / (b.s - a.s)
    }
}

// R3.1 — the anticipatory rise begins before the click (post-processing, so the
// camera can use the event timeline's future).
@Test func a1RiseStartsBeforeClick() {
    let tl = A1Smooth.clickTimeline(8, 2)
    var first: Double? = nil
    for i in 0..<600 where first == nil {
        let t = 1.0 + Double(i) * 0.0025
        if A1Smooth.frame(tl, t).s > 1.01 { first = t }
    }
    let start = first ?? -1
    print("A1 rise starts at \(start) (click 2.0)")
    #expect(start > 0, "camera never rose")
    #expect(start < 2.0, "rise did not anticipate the click")
}

// R3.2 — no overshoot, monotone rise, fixed pivot, no one-sample jumps.
@Test func a1NoOvershootFixedPivot() {
    let target = 2.2
    let tl = A1Smooth.manualTimeline(8, zoom: [
        ZoomSegment(start: 3, end: 4, scale: target, focus: .fixed(x: 0.34, y: 0.66), origin: .manual)
    ])
    let start = A1Smooth.frame(tl, 2.0), end = A1Smooth.frame(tl, 4.0)
    guard end.s - start.s > 0.5 else { Issue.record("no zoom happened"); return }
    let p = A1Smooth.pivot(start, end)
    var prev = start.s, maxRise = 0.0, maxAccel = 0.0, maxDrift = 0.0, lastSpeed = 0.0
    for tick in 0...1500 {
        let t = 2.0 + 2.0 * Double(tick) / 1500
        let f = A1Smooth.frame(tl, t)
        #expect(f.s >= start.s - 1e-5 && f.s <= end.s + 0.02, "overshoot at \(t): \(f.s)")
        maxRise = max(maxRise, f.s - prev)
        let speed = (f.s - prev) / (2.0 / 1500)
        if tick > 1 { maxAccel = max(maxAccel, abs(speed - lastSpeed)) }
        lastSpeed = speed
        prev = f.s
        let residual = (f.c - p) * f.s - (start.c - p) * start.s
        maxDrift = max(maxDrift, abs(residual.x), abs(residual.y))
    }
    print("A1 cam-in maxDrift=\(maxDrift) maxRise=\(maxRise) maxAccel=\(maxAccel)")
    #expect(maxDrift < 0.5, "lateral drift \(maxDrift)px")
    #expect(maxRise < 0.05, "scale rose \(maxRise) in one sample")
    #expect(maxAccel < 40, "first derivative jumped by \(maxAccel)")
}

// R2.1 — once the shot has arrived it holds; the scale never sinks mid-action.
@Test func a1DuringHoldScaleNeverDrops() {
    let target = 2.2
    let tl = A1Smooth.manualTimeline(8, zoom: [
        ZoomSegment(start: 3, end: 4, scale: target, focus: .fixed(x: 0.34, y: 0.66), origin: .manual)
    ])
    var settled = 4.0
    for i in 0...400 {
        let t = 3.0 + Double(i) * 0.0025
        if A1Smooth.frame(tl, t).s >= target - 0.02 { settled = t; break }
    }
    var lowest = Double.infinity
    var t = settled
    while t <= 3.98 {
        lowest = min(lowest, A1Smooth.frame(tl, t).s)
        t += 0.0025
    }
    print("A1 hold settled=\(settled) lowest=\(lowest)")
    #expect(settled < 3.9, "shot never settled")
    #expect(lowest >= target - 0.02, "zoom-out mid-action: \(lowest)")
}

// R2.2 — after the action ends the camera returns to full frame and stays there.
@Test func a1ZoomOutAfterActivityEnds() {
    let tl = A1Smooth.clickTimeline(9, 2)
    #expect(A1Smooth.frame(tl, 2.2).s > 1.3, "no shot at the click")
    for t in stride(from: 6.0, through: 8.95, by: 0.05) {
        let f = A1Smooth.frame(tl, t)
        #expect(f.s <= 1.01, "still zoomed on dead space at \(t): \(f.s)")
        #expect(hypot(f.c.x - 960, f.c.y - 540) < 2, "center did not return at \(t)")
    }
}

// R3.3/R3.4 — the published velocity is the derivative of the baked position
// (C1), and the per-tick velocity change (jerk proxy) stays bounded across a
// two-shot sequence, including the leg boundary.
@Test func a1BakedVelocityC1AndJerkBounded() {
    let tl = A1Smooth.manualTimeline(9, zoom: [
        ZoomSegment(start: 2, end: 3, scale: 1.8, focus: .fixed(x: 0.3, y: 0.65), origin: .manual),
        ZoomSegment(start: 3.3, end: 4.4, scale: 2.2, focus: .fixed(x: 0.7, y: 0.4), origin: .manual),
    ])
    guard let track = tl.derived?.camera else { Issue.record("no derived camera"); return }
    let rate = track.rate, n = track.lz.count
    var maxDerivError = 0.0, maxJerk = 0.0, maxSpeed = 0.0
    var worstK = 1, speedK = 1
    for k in 1..<(n - 1) {
        let numeric = (Double(track.lz[k + 1]) - Double(track.lz[k - 1])) * rate / 2
        let err = abs(numeric - Double(track.vz[k]))
        if err > maxDerivError { maxDerivError = err; worstK = k }
        if abs(Double(track.vz[k])) > maxSpeed { maxSpeed = abs(Double(track.vz[k])); speedK = k }
        if k > 1 { maxJerk = max(maxJerk, abs(Double(track.vz[k + 1] - track.vz[k])) * rate) }
    }
    print("A1 derivative worst k=\(worstK) speed k=\(speedK) lz=\(track.lz[speedK]) vz=\(track.vz[speedK])")
    print("A1 baked n=\(n) maxDerivError=\(maxDerivError) maxSpeed=\(maxSpeed) maxJerk=\(maxJerk)")
    #expect(n > 1000, "camera track too short")
    #expect(maxDerivError < 0.02, "published velocity disagrees with position (C1 broken)")
    // Physical ceiling from the 0.02-per-tick bake budget at 480 Hz:
    // 0.02 * 480 = 9.6 scale-units/s. 10 leaves a little headroom.
    #expect(maxSpeed < 10, "camera scale velocity spike")
    #expect(maxJerk < 1200, "camera jerk spike")
}
