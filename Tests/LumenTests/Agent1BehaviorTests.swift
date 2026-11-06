import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

private let a1Source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 4, backingScale: 1, originX: 0, originY: 0)

@Test func glassLoupeMagnifiesAndFollowsCursor() {
    var tl = Timeline(duration: 4)
    tl.audio.speedRampsAuto = false
    tl.overlays.loupes = [Loupe(start: 1, end: 3, x: 0, y: 0, follow: true, radius: 0.12, magnification: 3, round: true, cx: 0.8, cy: 0.8)]
    let events = [InputEvent(t: 2, kind: .move, x: 700, y: 400),
                  InputEvent(t: 2.5, kind: .down, x: 700, y: 400)]
    let out = Director.derive(tl, input: DirectorInput(events: events, source: a1Source), revision: 1)
    let frame = out.evaluate(at: 2.2)
    #expect(frame.emphasis.loupes.count == 1)
    let loupe = frame.emphasis.loupes[0]
    #expect(loupe.magnification == 3)
    #expect(loupe.round)
    // Follow mode: glass target is the cursor position, not Loupe.x/y (0,0).
    #expect(abs(loupe.target.x - 700) < 30 && abs(loupe.target.y - 400) < 30)
    #expect(out.evaluate(at: 0.5).emphasis.loupes.isEmpty)
}

@Test func cursorHidesWhenIdleAndReturnsOnMove() {
    var tl = Timeline(duration: 4)
    tl.audio.speedRampsAuto = false
    tl.cursor.idleHide = 0.5
    tl.cursor.glide = 0
    let events = [InputEvent(t: 1.0, kind: .move, x: 200, y: 200),
                  InputEvent(t: 1.2, kind: .move, x: 400, y: 300)]
    let out = Director.derive(tl, input: DirectorInput(events: events, source: a1Source), revision: 1)
    guard let op = out.derived?.cursor.opacity else { Issue.record("no cursor track"); return }
    func opacity(at t: Double) -> Double { Double(op[min(Int(t * gridRate), op.count - 1)]) }
    #expect(opacity(at: 1.2) > 0.7, "cursor visible while moving, got \(opacity(at: 1.2))")
    #expect(opacity(at: 3.5) < 0.2, "cursor must fade when idle, got \(opacity(at: 3.5))")
}

@Test func loopCursorGlidesBackToStart() {
    var tl = Timeline(duration: 4)
    tl.audio.speedRampsAuto = false
    tl.cursor.glide = 0
    tl.cursor.idleHide = nil
    tl.cursor.loop = 1.0
    let events = [InputEvent(t: 0, kind: .move, x: 100, y: 100),
                  InputEvent(t: 2, kind: .move, x: 1800, y: 900)]
    let out = Director.derive(tl, input: DirectorInput(events: events, source: a1Source), revision: 1)
    guard let c = out.derived?.cursor else { Issue.record("no cursor track"); return }
    let start = (Double(c.x[0]), Double(c.y[0]))
    let end = (Double(c.x[c.x.count - 1]), Double(c.y[c.y.count - 1]))
    let distToStart = hypot(end.0 - start.0, end.1 - start.1)
    let distToFar = hypot(end.0 - 1800, end.1 - 900)
    #expect(distToStart < distToFar, "loop tail must glide toward start (\(distToStart) vs \(distToFar))")
}

@Test func webcamHidesDuringSilence() {
    var tl = Timeline(duration: 4)
    tl.webcam = WebcamLayout()
    tl.layoutSettings.cameraOverlay.hideOnSilence = true
    tl.layoutSettings.cameraOverlay.silenceHold = 0.6
    let cam = CameraTrack(count: 10)
    let cursor = CursorTrack(count: 10)
    let silent = WebcamPlacement.solve(tl, tm: tl.timeMap, cam: cam, cursor: cursor,
                                       src: SIMD2(1920, 1080), vad: [], outDur: 4)
    #expect(silent.visibility(at: 3.0) < 0.1, "silent webcam must hide, got \(silent.visibility(at: 3.0))")
    let voiced = WebcamPlacement.solve(tl, tm: tl.timeMap, cam: cam, cursor: cursor,
                                       src: SIMD2(1920, 1080), vad: [0...4], outDur: 4)
    #expect(voiced.visibility(at: 3.0) > 0.9, "voiced webcam must stay, got \(voiced.visibility(at: 3.0))")
}

@Test func tiltLeanProducesYawAndRevealStartsTilted() {
    var events = (0...20).map { InputEvent(t: Double($0) * 0.1, kind: .move, x: Float(100 + $0 * 80), y: 540) }
    events.append(InputEvent(t: 0.5, kind: .down, x: 1700, y: 540))   // zoom shot so the camera actually pans
    var lean = Timeline(duration: 3)
    lean.audio.speedRampsAuto = false
    lean.camera.tilt = .lean
    let outLean = Director.derive(lean, input: DirectorInput(events: events, source: a1Source), revision: 1)
    let maxYaw = outLean.derived?.camera.yaw.map { abs(Double($0)) }.max() ?? 0
    #expect(maxYaw > 0.5, "lean tilt must yaw during pan, max \(maxYaw)")
    var reveal = Timeline(duration: 3)
    reveal.audio.speedRampsAuto = false
    reveal.camera.tilt = .reveal
    let outReveal = Director.derive(reveal, input: DirectorInput(events: events, source: a1Source), revision: 1)
    #expect(abs(Double(outReveal.derived?.camera.yaw[0] ?? 0) - 12) < 0.1)
}

@Test func zoomControlsAreLive() {
    // Sensitivity: hover-only activity only zooms when sensitivity > 0 and
    // the hover is purposeful (travel + dwell).
    let hovers = [InputEvent(t: 0.5, kind: .move, x: 200, y: 200),
                  InputEvent(t: 0.6, kind: .move, x: 900, y: 600),
                  InputEvent(t: 1.5, kind: .move, x: 900, y: 600)]
    func zoomCount(sensitivity: Double) -> Int {
        var tl = Timeline(duration: 3)
        tl.audio.speedRampsAuto = false
        tl.camera.sensitivity = sensitivity
        return Director.derive(tl, input: DirectorInput(events: hovers, source: a1Source), revision: 1).zoom.count
    }
    #expect(zoomCount(sensitivity: 1) >= zoomCount(sensitivity: 0))
    // Max scale caps every segment.
    var capped = Timeline(duration: 3)
    capped.audio.speedRampsAuto = false
    capped.camera.maxScale = 1.6
    capped.camera.minScale = 1.5
    let clicks = [InputEvent(t: 1, kind: .down, x: 960, y: 540)]
    let out = Director.derive(capped, input: DirectorInput(events: clicks, source: a1Source), revision: 1)
    #expect(out.zoom.allSatisfy { $0.scale <= 1.6 + 0.001 })
    // Center offset moves the camera (positive X offset puts cursor right
    // of center, so the camera center shifts left).
    func centerX(offset: Double) -> Double {
        var tl = Timeline(duration: 3)
        tl.audio.speedRampsAuto = false
        tl.camera.centerOffsetX = offset
        let o = Director.derive(tl, input: DirectorInput(events: clicks, source: a1Source), revision: 1)
        return Double(o.evaluate(at: 1).cameraCenter.x)
    }
    #expect(centerX(offset: 0.1) < centerX(offset: 0) - 1)
}

@Test func webcamBehindFaceHideAndFade() {
    func placement(mode: BehindFace) -> PlacementTrack {
        var tl = Timeline(duration: 4)
        tl.webcam = WebcamLayout()
        tl.layoutSettings.cameraOverlay.behindFace = mode
        tl.layoutSettings.cameraOverlay.avoidCursor = false
        var cam = CameraTrack(count: 10)
        var cursor = CursorTrack(count: 10)
        for i in cursor.x.indices { cursor.x[i] = 1700; cursor.y[i] = 950 }  // inside bottom-right bubble
        _ = cam
        return WebcamPlacement.solve(tl, tm: tl.timeMap, cam: cam, cursor: cursor,
                                     src: SIMD2(1920, 1080), vad: [0...4], outDur: 4)
    }
    #expect(placement(mode: .hide).visibility(at: 2.0) < 0.1, "hide must drop visibility")
    let fade = placement(mode: .fade).visibility(at: 2.0)
    #expect(fade > 0.05 && fade < 0.45, "fade must dim to ~0.2, got \(fade)")
    #expect(placement(mode: .move).visibility(at: 2.0) > 0.9, "move keeps camera visible")
}
