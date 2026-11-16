import Foundation
import Testing
@testable import LumenProject
@testable import LumenDirector
import LumenCore

/// Markers are explicit "this moment matters" beats. A rect from an agent
/// step frames the subject; a bare marker borrows the nearest recent click;
/// a marker with no location invents nothing.
@Suite struct ZoomMarkerTests {
    private let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 8,
                                    backingScale: 1, originX: 0, originY: 0)

    private func derive(_ markers: [DirectorMarker], events: [InputEvent] = []) throws -> Timeline {
        var tl = Timeline(duration: 8)
        tl.audio.speedRampsAuto = false
        return try Director.derive(tl, input: DirectorInput(events: events, source: source, markers: markers), revision: 1)
    }

    @Test func markerRectFramesTheMarkedControl() throws {
        // Agent step resolved a small button at 900..980 x 520..560.
        let rect = CGRect(x: 900.0 / 1920, y: 520.0 / 1080,
                          width: 80.0 / 1920, height: 40.0 / 1080)
        let out = try derive([DirectorMarker(start: 2, end: 3, rect: rect, label: "Sign in")])
        #expect(out.zoom.count == 1)
        guard let z = out.zoom.first else { return }
        guard case .element(let x, let y, let w, let h) = z.focus else {
            Issue.record("A marker rect must frame the element, got \(z.focus)")
            return
        }
        #expect(abs(x * 1920 - 900) < 1)
        #expect(abs(y * 1080 - 520) < 1)
        #expect(abs(w * 1920 - 80) < 1)
        #expect(abs(h * 1080 - 40) < 1)
        #expect(z.scale > 1.5)
        let frame = out.evaluate(at: 2.6)
        #expect(abs(Double(frame.cameraCenter.x) - 940) < 8)
        #expect(abs(Double(frame.cameraCenter.y) - 540) < 8)
    }

    @Test func bareMarkerBorrowsRecentClick() throws {
        let click = InputEvent(t: 1.8, kind: .down, x: 700, y: 400)
        let out = try derive([DirectorMarker(start: 2, end: 2.5, label: "Checkout")], events: [click])
        #expect(out.zoom.count == 1)
        guard let z = out.zoom.first else { return }
        if case .fixed(let x, let y) = z.focus {
            #expect(abs(x * 1920 - 700) < 1)
            #expect(abs(y * 1080 - 400) < 1)
        } else {
            Issue.record("A bare marker should inherit the recent click point")
        }
    }

    @Test func markerWithoutLocationCreatesNoZoom() throws {
        let out = try derive([DirectorMarker(start: 2, end: 3, label: "Thinking")])
        #expect(out.zoom.isEmpty)
    }

    @Test func centredClickFramesItsControl() throws {
        let ax = AXFrame(x: 850, y: 425, w: 120, h: 80)
        let click = InputEvent(t: 2, kind: .down, x: 910, y: 465, axFrameIndex: 1)
        var tl = Timeline(duration: 8)
        tl.audio.speedRampsAuto = false
        let out = try Director.derive(tl, input: DirectorInput(events: [click], source: source, ax: [ax]), revision: 1)
        #expect(out.zoom.count == 1)
        guard case .element(let x, let y, _, _) = out.zoom.first?.focus else {
            Issue.record("A centred click should frame the control")
            return
        }
        #expect(abs(x * 1920 - 850) < 1)
        #expect(abs(y * 1080 - 425) < 1)
    }
}
