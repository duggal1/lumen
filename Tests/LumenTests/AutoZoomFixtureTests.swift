import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// The eight synthetic auto-zoom sessions from the handoff. Each derives a
/// real Director timeline and reads the baked camera, not a mock. The two
/// owner-reported symptoms get their own named regressions.
private enum AZ {
    static func source(_ duration: Double) -> SourceInfo {
        SourceInfo(width: 1920, height: 1080, fps: 60, duration: duration,
                   backingScale: 1, originX: 0, originY: 0)
    }

    static func derive(_ duration: Double, events: [InputEvent] = [],
                       activity: [ActivityPoint] = []) -> Timeline {
        var tl = Timeline(duration: duration)
        tl.audio.speedRampsAuto = false
        return Director.derive(tl, input: DirectorInput(events: events, source: source(duration),
                                                        activity: activity), revision: 1)
    }

    static func scale(_ tl: Timeline, _ t: Double) -> Double { Double(tl.evaluate(at: t).cameraScale) }

    static func endsFullFrame(_ tl: Timeline, at t: Double) {
        let f = tl.evaluate(at: t)
        #expect(abs(Double(f.cameraScale) - 1) < 1e-3, "scale \(f.cameraScale) at \(t)")
        #expect(abs(Double(f.cameraCenter.x) - 960) < 1, "center x \(f.cameraCenter.x) at \(t)")
        #expect(abs(Double(f.cameraCenter.y) - 540) < 1, "center y \(f.cameraCenter.y) at \(t)")
    }
}

// 1. A fully idle page produces no zoom at all.
@Test func idlePageProducesNoZoom() {
    let tl = AZ.derive(8)
    #expect(tl.zoom.isEmpty)
    for t in stride(from: 0.0, through: 7.9, by: 0.1) { #expect(AZ.scale(tl, t) == 1) }
    AZ.endsFullFrame(tl, at: 7.99)
}

// 2. One click, then idle: one zoom in and one zoom out.
@Test func singleClickThenIdleZoomsInAndOut() {
    let tl = AZ.derive(8, events: [InputEvent(t: 2, kind: .down, x: 700, y: 420)])
    #expect(tl.zoom.count == 1)
    #expect(AZ.scale(tl, 2.05) > 1.3, "must be zoomed at the click")
    AZ.endsFullFrame(tl, at: 7.99)
}

// 3. A burst in one area merges into one shot, not many small ones.
@Test func clickBurstInOneAreaMergesIntoOneShot() {
    let events: [InputEvent] = (0..<8).map { (i: Int) in
        let x: Float = 700 + Float((i * 7) % 24)
        let y: Float = 420 + Float((i * 11) % 18)
        return InputEvent(t: 2 + Double(i) * 0.12, kind: .down, x: x, y: y)
    }
    let tl = AZ.derive(9, events: events)
    #expect(tl.zoom.count == 1, "burst made \(tl.zoom.count) shots")
    AZ.endsFullFrame(tl, at: 8.99)
}

// 4. Two distant clicks re-aim instead of welding into one shot.
@Test func twoDistantClicksReaimOrRelease() {
    let events = [InputEvent(t: 2, kind: .down, x: 300, y: 300),
                  InputEvent(t: 6, kind: .down, x: 1650, y: 850)]
    let tl = AZ.derive(10, events: events)
    #expect(tl.zoom.count == 2, "distant clicks made \(tl.zoom.count) shots")
    AZ.endsFullFrame(tl, at: 9.99)
}

// 5. Typing in a field produces a shot that outlives a single keystroke.
@Test func typingBurstProducesOneShot() {
    let events = (0..<14).map { i in
        InputEvent(t: 2 + Double(i) * 0.08, kind: .keyDown,
                   x: 900, y: 500, axFrameIndex: 1)
    }
    let field = AXFrame(x: 760, y: 460, w: 400, h: 90)
    let tl = AZ.derive(9, events: events, activity: [])
    let withField = Director.derive({
        var t = Timeline(duration: 9); t.audio.speedRampsAuto = false; return t
    }(), input: DirectorInput(events: events, source: AZ.source(9), ax: [field]), revision: 1)
    #expect(!tl.zoom.isEmpty || !withField.zoom.isEmpty)
    AZ.endsFullFrame(tl, at: 8.99)
}

// 6. A drag produces a follow shot inside the zoomed frame.
@Test func dragProducesAFollowShot() {
    var events = [InputEvent(t: 2, kind: .down, x: 700, y: 420)]
    for i in 0..<12 {
        events.append(InputEvent(t: 2.05 + Double(i) * 0.05, kind: .drag,
                                 x: 700 + Float(i * 14), y: 420 + Float(i * 6)))
    }
    let tl = AZ.derive(9, events: events)
    #expect(tl.zoom.count == 1)
    #expect(AZ.scale(tl, 2.4) > 1.2)
    AZ.endsFullFrame(tl, at: 8.99)
}

// 7. A wandering cursor with no clicks never zooms.
@Test func wanderingCursorWithoutClicksNeverZooms() {
    let events: [InputEvent] = (0..<120).map { (i: Int) in
        let x: Float = Float(200 + (i * 137) % 1500)
        let y: Float = Float(120 + (i * 91) % 800)
        return InputEvent(t: 0.2 + Double(i) * 0.05, kind: .move, x: x, y: y)
    }
    let tl = AZ.derive(8, events: events)
    #expect(tl.zoom.isEmpty, "cursor wander made \(tl.zoom.count) shots")
}

// 8. A long sparse session keeps shots bounded and always ends at full frame.
@Test func longSparseSessionEndsAtFullFrame() {
    let events = [2.0, 18.0, 37.0, 55.0].map { InputEvent(t: $0, kind: .down, x: 500, y: 400) }
    let tl = AZ.derive(60, events: events)
    #expect(tl.zoom.count <= 4)
    for z in tl.zoom { #expect(z.end - z.start <= 6.7, "unbounded shot \(z)") }
    AZ.endsFullFrame(tl, at: 59.99)
}

// Owner symptom P4: ambient on-screen animation must not invent a zoom.
@Test func ambientAnimationOnIdlePageNeverZooms() {
    let activity = (0..<40).map { i in
        ActivityPoint(t: 1 + Double(i) * 0.1, x: 1500, y: 900,
                      region: CGRect(x: 1480, y: 880, width: 40, height: 40), coverage: 0.002)
    }
    let tl = AZ.derive(8, activity: activity)
    #expect(tl.zoom.isEmpty, "ambient animation made \(tl.zoom.count) shots")
}

// Owner symptom P5: a click in the last second still releases before the end.
@Test func lastSecondClickReleasesBeforeEnd() {
    let tl = AZ.derive(6, events: [InputEvent(t: 5.4, kind: .down, x: 900, y: 450)])
    #expect(tl.zoom.count == 1)
    #expect(AZ.scale(tl, 5.45) > 1.2)
    AZ.endsFullFrame(tl, at: 5.999)
}
