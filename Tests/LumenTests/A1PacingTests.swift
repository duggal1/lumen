import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// A1 / R4 — stable 60 fps output pacing. The renderer interpolates the baked
/// camera at each OUTPUT timestamp, so the pacing contract is on
/// `Timeline.evaluate` sampled at 60 Hz, not on the 480 Hz bake grid.
private enum A1Pace {
    static func source(_ duration: Double) -> SourceInfo {
        SourceInfo(width: 1920, height: 1080, fps: 60, duration: duration,
                   backingScale: 1, originX: 0, originY: 0)
    }

    static func derive(_ duration: Double, events: [InputEvent] = []) -> Timeline {
        var tl = Timeline(duration: duration)
        tl.audio.speedRampsAuto = false
        return Director.derive(tl, input: DirectorInput(events: events, source: source(duration)), revision: 1)
    }
}

@Test func a1EvaluateAt60HzFrameDeltaBounded() {
    let events: [InputEvent] = [
        InputEvent(t: 2, kind: .down, x: 700, y: 420),
        InputEvent(t: 2.6, kind: .drag, x: 800, y: 440),
        InputEvent(t: 4, kind: .down, x: 1200, y: 600),
    ]
    let tl = A1Pace.derive(9, events: events)
    var prev = Double(tl.evaluate(at: 0).cameraScale)
    var maxDelta = 0.0, maxAt = 0.0, nonFinite = 0
    var frame = 1
    while frame <= 8 * 60 {
        let t = Double(frame) / 60
        let s = Double(tl.evaluate(at: t).cameraScale)
        if !s.isFinite { nonFinite += 1 }
        let d = abs(s - prev)
        if d > maxDelta { maxDelta = d; maxAt = t }
        prev = s
        frame += 1
    }
    print("A1 60fps maxDelta=\(maxDelta) at \(maxAt) nonFinite=\(nonFinite)")
    #expect(nonFinite == 0, "non-finite camera scale")
    // 0.02 is the BAKE-GRID (480 Hz) per-tick budget; the camera is baked at
    // 480 Hz and sampled here at 60 Hz, so one output frame spans 480/60 = 8
    // bake ticks. The equivalent output-frame bound is 0.02 * 8 = 0.16.
    // The 480 Hz gate itself stays at 0.02 in a1EvaluateAt480HzIsPaced.
    #expect(maxDelta <= 0.16, "per-frame scale jump \(maxDelta) at \(maxAt)")
}

@Test func a1EvaluateAt480HzIsPaced() {
    let tl = A1Pace.derive(6, events: [InputEvent(t: 2, kind: .down, x: 700, y: 420)])
    var prev = Double(tl.evaluate(at: 0).cameraScale), maxDelta = 0.0
    for tick in 1..<(6 * 480) {
        let s = Double(tl.evaluate(at: Double(tick) / 480).cameraScale)
        maxDelta = max(maxDelta, abs(s - prev)); prev = s
    }
    print("A1 480Hz maxDelta=\(maxDelta)")
    #expect(maxDelta <= 0.02, "sub-tick scale jump \(maxDelta)")
}

// R4.2 — same input, same output, bit for bit (no clock, no unordered state).
@Test func a1EvaluateDeterministic() {
    let a = A1Pace.derive(8, events: [InputEvent(t: 2, kind: .down, x: 700, y: 420)])
    let b = A1Pace.derive(8, events: [InputEvent(t: 2, kind: .down, x: 700, y: 420)])
    #expect(a.zoom == b.zoom, "derive produced different segments")
    for i in 0..<137 {
        let t = Double(i) * 0.0581
        let x = a.evaluate(at: t), y = b.evaluate(at: t)
        #expect(x.cameraScale == y.cameraScale, "scale differs at \(t)")
        #expect(x.cameraCenter == y.cameraCenter, "center differs at \(t)")
    }
}
