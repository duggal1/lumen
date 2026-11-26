import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// P1 acceptance: sample the real evaluated camera path at 1001+ timestamps for
/// zoom in and zoom out. No overshoot, monotone scale, fixed pivot, continuous
/// value and first derivative, and a perfectly still deterministic idle camera.
private enum CP {
    static func timeline(_ duration: Double, zoom: [ZoomSegment]) -> Timeline {
        var tl = Timeline(duration: duration)
        tl.camera.autoZoom = false
        tl.audio.speedRampsAuto = false
        tl.zoom = zoom
        let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: duration,
                                backingScale: 1, originX: 0, originY: 0)
        var derived = Director.derive(tl, input: DirectorInput(events: [], source: source), revision: 1)
        derived.derived?.camera = CameraSolver.solve(zoom: zoom, tm: tl.timeMap,
            cursor: CursorTrack(count: Int(duration * gridRate) + 1), p: tl.camera,
            src: SIMD2(1920, 1080), outDur: duration, loop: nil)
        return derived
    }

    static func frame(_ tl: Timeline, _ t: Double) -> (s: Double, c: SIMD2<Double>) {
        let f = tl.evaluate(at: t)
        return (Double(f.cameraScale), SIMD2(Double(f.cameraCenter.x), Double(f.cameraCenter.y)))
    }

    /// The pivot implied by the endpoints of a pure scale about a fixed point.
    static func pivot(_ a: (s: Double, c: SIMD2<Double>), _ b: (s: Double, c: SIMD2<Double>)) -> SIMD2<Double> {
        (b.c * b.s - a.c * a.s) / (b.s - a.s)
    }
}

@Test func zoomInFollowsFixedPivotWithNoOvershoot() {
    let tl = CP.timeline(8, zoom: [ZoomSegment(start: 3, end: 4, scale: 2.2,
                                               focus: .fixed(x: 0.34, y: 0.66), origin: .auto)])
    let start = CP.frame(tl, 2.0)        // fully full frame before the rise
    let end = CP.frame(tl, 4.0)          // settled on the target
    guard end.s - start.s > 0.5 else { Issue.record("no zoom happened"); return }
    let p = CP.pivot(start, end)
    var previous = start.s
    var maxDrift: Double = 0, maxRise: Double = 0, maxStep: Double = 0
    var lastSpeed = 0.0
    for tick in 0...1500 {
        let t = 2.0 + 2.0 * Double(tick) / 1500
        let f = CP.frame(tl, t)
        #expect(f.s >= start.s - 1e-5 && f.s <= end.s + 1e-5, "overshoot at \(t): \(f.s)")
        maxRise = max(maxRise, f.s - previous)
        let speed = (f.s - previous) / (2.0 / 1500)
        if tick > 1 { maxStep = max(maxStep, abs(speed - lastSpeed)) }
        lastSpeed = speed
        previous = f.s
        // (c - p) * s is invariant for a scale about the fixed pivot p.
        let residual = (f.c - p) * f.s - (start.c - p) * start.s
        maxDrift = max(maxDrift, abs(residual.x), abs(residual.y))
    }
    print("CAM-IN maxDrift=\(maxDrift) maxRise=\(maxRise) maxAccel=\(maxStep)")
    #expect(maxDrift < 0.5, "lateral drift \(maxDrift) px")
    #expect(maxRise < 0.05, "scale rose \(maxRise) in one sample")
    #expect(maxStep < 40, "first derivative jumped by \(maxStep)")
}

@Test func zoomOutFollowsFixedPivotWithNoOvershoot() {
    let tl = CP.timeline(8, zoom: [ZoomSegment(start: 3, end: 4, scale: 2.2,
                                               focus: .fixed(x: 0.34, y: 0.66), origin: .auto)])
    let start = CP.frame(tl, 4.0)
    let end = CP.frame(tl, 5.0)
    guard start.s - end.s > 0.5 else { Issue.record("no release happened"); return }
    let p = CP.pivot(start, end)
    var previous = start.s
    var maxDrift: Double = 0, maxRise: Double = 0
    for tick in 0...1500 {
        let t = 4.0 + 1.0 * Double(tick) / 1500
        let f = CP.frame(tl, t)
        #expect(f.s >= end.s - 1e-5 && f.s <= start.s + 1e-5, "release overshot at \(t): \(f.s)")
        maxRise = max(maxRise, f.s - previous)
        previous = f.s
        let residual = (f.c - p) * f.s - (start.c - p) * start.s
        maxDrift = max(maxDrift, abs(residual.x), abs(residual.y))
    }
    print("CAM-OUT maxDrift=\(maxDrift) maxRise=\(maxRise)")
    #expect(maxDrift < 0.5, "lateral drift \(maxDrift) px")
    #expect(maxRise < 1e-4, "release rose by \(maxRise)")
}

@Test func idleCameraIsPerfectlyStillAndBitIdentical() {
    let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 6,
                            backingScale: 1, originX: 0, originY: 0)
    let tl = Director.derive(Timeline(duration: 6),
                             input: DirectorInput(events: [], source: source), revision: 1)
    let again = Director.derive(Timeline(duration: 6),
                                input: DirectorInput(events: [], source: source), revision: 9)
    #expect(tl.derived?.camera == again.derived?.camera)
    #expect((0...1500).allSatisfy { tick in
        let f = CP.frame(tl, 6 * Double(tick) / 1500)
        return f.s == 1 && f.c == SIMD2(960, 540)
    })
}
