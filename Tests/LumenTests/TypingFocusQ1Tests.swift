import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - Q1 brutal typing focus probes (headless)
//
// Every assertion drives TypingFocus / ZoomPlanner / Director.derive directly.
// No window, no focus, no GUI. These probe two ways an AX frame can be mistaken
// for the field being typed into.

@Suite struct TypingFocusQ1Tests {
    private let W = 1920.0, H = 1080.0

    private func source(_ dur: Double = 10) -> SourceInfo {
        SourceInfo(width: Int(W), height: Int(H), fps: 60, duration: dur,
                   backingScale: 2, originX: 0, originY: 0)
    }

    private func keys(_ count: Int, from t0: Double, index: UInt32) -> [InputEvent] {
        (0..<count).map { InputEvent(t: t0 + Double($0) * 0.11, kind: .keyDown,
                                     keyCode: UInt16($0 % 40), axFrameIndex: index) }
    }

    /// AX capture also records the browser WINDOW as a resolved frame. A key
    /// event whose axFrameIndex points at that frame is not evidence about a
    /// text field: the whole window must never become the typing subject.
    @Test func windowSizedFrameIsNotATypingField() {
        let window = AXFrame(x: 0, y: 0, w: W, h: H,
                             label: "window|AXWindow|AXStandardWindow|Google Chrome",
                             anchor: FocusAnchor(epoch: 1, sampledAt: 2,
                                                 appName: "Google Chrome", resolved: true))
        let ev = keys(10, from: 2.0, index: 1)
        let shots = TypingFocus.shots(events: ev, ax: [window], traces: [],
                                      W: W, H: H, b: 2, trimStart: 0, trimEnd: 10)
        #expect(shots.isEmpty, "a window frame became a typing field: \(shots)")

        var tl = Timeline(duration: 10)
        tl.audio.speedRampsAuto = false
        tl = Director.derive(tl, input: DirectorInput(events: ev, source: source(), ax: [window]),
                             revision: 1)
        for s in tl.zoom {
            if case .element(let x, let y, let w, let h) = s.focus {
                let framed = CGRect(x: x * W, y: y * H, width: w * W, height: h * H)
                #expect(framed.width < 0.7 * W && framed.height < 0.5 * H,
                        "window framed as the typing field: \(framed)")
            }
        }
    }

    /// A large but plausible text editor field is still a valid subject; the
    /// guard must reject windows, not ordinary wide fields.
    @Test func wideTextFieldStillFramesWhole() {
        let rect = CGRect(x: 200, y: 120, width: 1100, height: 96)
        var f = AXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height,
                        label: "Text area",
                        anchor: FocusAnchor(epoch: 1, sampledAt: 2, resolved: true))
        f.caret = AXFrame.Rect(x: 210, y: 128, w: 2, h: 24)
        let ev = keys(8, from: 2.0, index: 1)
        let shots = TypingFocus.shots(events: ev, ax: [f], traces: [],
                                      W: W, H: H, b: 2, trimStart: 0, trimEnd: 10)
        #expect(shots.count == 1, "a real text field was rejected")
        guard let s = shots.first else { return }
        #expect(abs(s.field.minX - rect.minX) < 1e-6 && abs(s.field.width - rect.width) < 1e-6)
        #expect(abs(s.t0 - 2.0) < 1e-9, "shot did not start on the first key")
    }

    /// A large but genuine text area (a code editor) must not be thrown out by
    /// the window guard. Only window-labelled or truly full-screen frames are.
    @Test func largeTextAreaIsStillAValidField() {
        let rect = CGRect(x: 120, y: 80, width: 1600, height: 900)
        var f = AXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height,
                        label: "Source editor",
                        anchor: FocusAnchor(epoch: 1, sampledAt: 2, resolved: true))
        f.caret = AXFrame.Rect(x: 200, y: 120, w: 2, h: 24)
        let ev = keys(8, from: 2.0, index: 1)
        let shots = TypingFocus.shots(events: ev, ax: [f], traces: [],
                                      W: W, H: H, b: 2, trimStart: 0, trimEnd: 10)
        #expect(shots.count == 1, "a large real text area was rejected")
        #expect(shots.first?.t0 == 2.0)
    }
}
