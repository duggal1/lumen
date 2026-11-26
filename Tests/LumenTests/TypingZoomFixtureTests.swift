import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
@testable import LumenDirector

/// A4 — typing zoom fixtures: typing session enter/exit timing + caret tracking
/// (TypingFocus), and the Director derive path (camera zoom in on typing, back
/// out after it stops). Pure, deterministic, no wall clock.
@Suite struct TypingZoomFixtureTests {
    static let W = 1920.0, H = 1080.0

    /// Text field at (100, 400, 800, 40). `caretX` places the caret inside it.
    static func fieldFrame(x: Double = 100, y: Double = 400, w: Double = 800, h: Double = 40,
                           caretX: Double = 140) -> AXFrame {
        var f = AXFrame(x: x, y: y, w: w, h: h, secure: false, label: "Email", anchor: nil)
        f.caret = AXFrame.Rect(x: caretX, y: y + 12, w: 2, h: 20)
        f.sampledAt = 0
        return f
    }

    /// Typing enters on the first keystroke; the shot extends `exitDebounce`
    /// past the last key (typing stops → zoom back out), and every keystroke's
    /// caret rect is carried on the shot.
    @Test func typingShotCoversKeysAndCarriesCaretPath() {
        let events = [
            InputEvent(t: 1.0, kind: .keyDown, keyCode: 40, axFrameIndex: 1),
            InputEvent(t: 1.2, kind: .keyDown, keyCode: 41, axFrameIndex: 1),
            InputEvent(t: 1.4, kind: .keyDown, keyCode: 42, axFrameIndex: 1),
        ]
        let ax = [TypingZoomFixtureTests.fieldFrame()]
        let shots = TypingFocus.shots(events: events, ax: ax, traces: [],
                                      W: TypingZoomFixtureTests.W, H: TypingZoomFixtureTests.H, b: 1,
                                      trimStart: 0, trimEnd: 10)
        #expect(shots.count == 1, "shots: \(shots)")
        let shot = shots[0]
        #expect(abs(shot.t0 - 1.0) < 1e-9, "shot start \(shot.t0)")
        #expect(abs(shot.t1 - (1.4 + TypingFocus.exitDebounce)) < 1e-9, "shot end \(shot.t1)")
        #expect(shot.carets.count == 3, "carets: \(shot.carets)")
        #expect(abs(shot.carets[2].t - 1.4) < 1e-9, "last caret at last key")
    }

    /// A long idle gap ends the run (idle timeout), each run debounced.
    @Test func typingIdleTimeoutEndsRun() {
        let events = [
            InputEvent(t: 1.0, kind: .keyDown, keyCode: 40, axFrameIndex: 1),
            InputEvent(t: 3.0, kind: .keyDown, keyCode: 41, axFrameIndex: 1),
        ]
        let ax = [TypingZoomFixtureTests.fieldFrame()]
        let shots = TypingFocus.shots(events: events, ax: ax, traces: [],
                                      W: TypingZoomFixtureTests.W, H: TypingZoomFixtureTests.H, b: 1,
                                      trimStart: 0, trimEnd: 10)
        #expect(shots.count == 2, "shots: \(shots)")
        #expect(abs(shots[0].t0 - 1.0) < 1e-9)
        #expect(abs(shots[0].t1 - (1.0 + TypingFocus.exitDebounce)) < 1e-9, "shot end \(shots[0].t1)")
    }

    /// Director.derive: a typing burst produces a typing shot; the camera is
    /// zoomed while typing and returns to the full frame after the burst stops
    /// (typing zoom — enter on keys, exit on typing stop).
    @Test func directorTypingZoomsInAndBackOut() {
        var tl = Timeline(duration: 10)
        tl.audio.speedRampsAuto = false
        let ax = [
            TypingZoomFixtureTests.fieldFrame(caretX: 140),
            TypingZoomFixtureTests.fieldFrame(caretX: 180),
            TypingZoomFixtureTests.fieldFrame(caretX: 220),
        ]
        let events = [
            InputEvent(t: 2.0, kind: .keyDown, keyCode: 40, axFrameIndex: 1),
            InputEvent(t: 2.2, kind: .keyDown, keyCode: 41, axFrameIndex: 2),
            InputEvent(t: 2.4, kind: .keyDown, keyCode: 42, axFrameIndex: 3),
        ]
        let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 10,
                                backingScale: 1, originX: 0, originY: 0)
        let t = Director.derive(tl, input: DirectorInput(events: events, source: source, ax: ax),
                                revision: 1)
        let typingShots = t.zoom.filter { s in
            s.origin == .auto && t.derived?.camera != nil
        }
        #expect(!typingShots.isEmpty, "no auto zoom segments: \(t.zoom)")
        let scale = { t.evaluate(at: $0).cameraScale }
        #expect(Double(scale(2.9)) > 1.05, "camera should be zoomed during typing: \(scale(2.9))")
        #expect(Double(scale(5.5)) <= 1.05, "camera should return to full frame after typing stops: \(scale(5.5))")
        #expect(Double(scale(5.5)) >= 0.95, "camera should settle near 1: \(scale(5.5))")
    }
}
