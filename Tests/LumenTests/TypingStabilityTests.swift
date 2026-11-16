import Testing
import Foundation
import CoreGraphics
import LumenCore
import LumenProject
@testable import LumenDirector

/// Regression oracle for "the camera floats around when I type".
///
/// The camera must frame the resolved text field as a STEADY subject: one
/// zoom, a fixed centre through the burst, no per-keystroke oscillation and
/// no trailing after the last key. The caret still has to stay inside the
/// evaluated viewport — that is the contract the old caret-follow path
/// existed to satisfy, and framing the field whole satisfies it better.
private enum TypingStability {
    static let W = 1920.0, H = 1080.0
    static let field = CGRect(x: 560, y: 420, width: 800, height: 80)
    static let t0 = 3.0
    static let step = 0.18
    static let count = 20

    static func source(duration: Double = 16) -> SourceInfo {
        SourceInfo(width: Int(W), height: Int(H), fps: 60, duration: duration,
                   backingScale: 2, originX: 0, originY: 0)
    }

    /// One caret per key. The first 14 walk right along line 1; the last 6
    /// wrap to line 2. The wrap is a large jump — exactly the kind of step
    /// the old 30 Hz hold-then-jump path turned into vertical wander.
    static func carets() -> [(t: Double, x: Double, y: Double)] {
        (0..<count).map { i in
            let wrapped = i >= 14
            return (t0 + Double(i) * step,
                    580 + Double(wrapped ? i - 14 : i) * 36,
                    wrapped ? 466 : 430)
        }
    }

    static func derive() -> (timeline: Timeline, carets: [(t: Double, x: Double, y: Double)]) {
        let carets = self.carets()
        var ax: [AXFrame] = []
        var events: [InputEvent] = []
        for (i, c) in carets.enumerated() {
            var f = AXFrame(x: field.minX, y: field.minY, w: field.width, h: field.height)
            f.caret = AXFrame.Rect(x: c.x, y: c.y, w: 2, h: 28)
            ax.append(f)
            events.append(InputEvent(t: c.t, kind: .keyDown, keyCode: 7, axFrameIndex: UInt32(i + 1)))
        }
        var tl = Timeline(duration: 16)
        tl.audio.speedRampsAuto = false
        tl.camera.sensitivity = 0                 // isolate typing from hover intents
        let out = Director.derive(tl, input: DirectorInput(events: events, source: source(), ax: ax), revision: 1)
        return (out, carets)
    }

    static func center(_ tl: Timeline, _ t: Double) -> SIMD2<Double> {
        let f = tl.evaluate(at: t)
        return SIMD2(Double(f.cameraCenter.x), Double(f.cameraCenter.y))
    }

    /// Max pairwise distance of centres sampled on [from, to].
    static func centerDrift(_ tl: Timeline, from: Double, to: Double, step: Double = 0.05) -> Double {
        var lo = SIMD2(Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)
        var hi = SIMD2(-Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        var t = from
        while t <= to + 1e-9 {
            let c = center(tl, t)
            lo = SIMD2(min(lo.x, c.x), min(lo.y, c.y))
            hi = SIMD2(max(hi.x, c.x), max(hi.y, c.y))
            t += step
        }
        return Double(hypot(hi.x - lo.x, hi.y - lo.y))
    }
}

@Test func typingCameraCenterStaysStationaryDuringBurst() {
    let (tl, _) = TypingStability.derive()
    // Measure inside the hold, after the lead-in has settled on the field.
    let drift = TypingStability.centerDrift(tl, from: TypingStability.t0 + 0.45, to: 6.3)
    print("typing centre drift during burst: \(String(format: "%.2f", drift)) px")
    #expect(drift <= 4.0, "camera wandered \(String(format: "%.2f", drift)) px while typing")
}

@Test func typingCaretStaysInsideViewportThroughoutBurst() {
    let (tl, carets) = TypingStability.derive()
    for c in carets where c.t >= TypingStability.t0 {
        let f = tl.evaluate(at: c.t)
        let scale = Double(f.cameraScale)
        let halfX = TypingStability.W / (2 * scale)
        let halfY = TypingStability.H / (2 * scale)
        let dx = (c.x - Double(f.cameraCenter.x)) / halfX
        let dy = (c.y - Double(f.cameraCenter.y)) / halfY
        #expect(abs(dx) < 1.0, "caret left the viewport horizontally: dx=\(dx) at \(c.t)")
        #expect(abs(dy) <= 0.62, "caret left the viewport vertically: dy=\(dy) at \(c.t)")
    }
}

@Test func typingBurstCreatesExactlyOneZoomScene() {
    let (tl, _) = TypingStability.derive()
    let scenes = tl.zoom.filter { $0.end >= TypingStability.t0 && $0.start <= 6.3 }
    print("typing scenes: \(scenes.count)")
    #expect(scenes.count == 1, "typing burst created \(scenes.count) zoom scenes, expected one steady scene")
}

@Test func typingCameraSettlesAfterBurst() {
    let (tl, _) = TypingStability.derive()
    // The scene ends at t1 + hold (~7.4 s) and the intentional zoom-out tail
    // is 0.7 s, so from 8.5 s the camera must be at rest — not still ringing
    // from the last keystroke.
    let drift = TypingStability.centerDrift(tl, from: 8.5, to: 10.0)
    print("typing centre drift after settle: \(String(format: "%.3f", drift)) px")
    #expect(drift <= 1.0, "camera kept moving after typing stopped: \(String(format: "%.3f", drift)) px")
}
