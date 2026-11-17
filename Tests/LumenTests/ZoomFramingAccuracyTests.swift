import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - Zoom framing accuracy (evidence from the 12 screenshots)
//
// Every auto zoom used to read exactly "2.0x Auto" regardless of subject,
// dialogs were cropped by the frame edge, typing did not re-aim, and a shot
// ran 8-10 s. All assertions drive the real planner the editor and export use.
// No window, no focus, no GUI.

@Suite struct ZoomFramingAccuracyTests {
    private let W = 1920.0, H = 1080.0

    private func source(_ dur: Double = 12) -> SourceInfo {
        SourceInfo(width: Int(W), height: Int(H), fps: 60, duration: dur,
                   backingScale: 1, originX: 0, originY: 0)
    }

    private func params() -> CameraParams {
        var p = CameraParams()
        p.preset = .balanced
        p.autoZoom = true
        p.maxScale = 2.0
        p.minScale = 1.25
        p.baseScale = 1.8
        p.hold = 0.9
        p.zoomOutGap = 2.6
        p.sensitivity = 0            // isolate from hover intents
        return p
    }

    private func plan(_ events: [InputEvent], _ ax: [AXFrame], _ dur: Double,
                      typing: [TypingTrace] = [], activity: [ActivityPoint] = [],
                      markers: [DirectorMarker] = [], p: CameraParams? = nil) -> ZoomPlanner.ZoomPlan {
        ZoomPlanner.plan(events: events, ax: ax, typing: typing, activity: activity,
                         src: source(dur), p: p ?? params(),
                         tm: TimeMap(sourceDuration: dur), avoid: [], markers: markers)
    }

    private func click(_ t: Double, _ x: Double, _ y: Double, w: Double = 90, h: Double = 44,
                       resolved: Bool = true, _ ax: inout [AXFrame]) -> [InputEvent] {
        ax.append(AXFrame(x: x - w / 2, y: y - h / 2, w: w, h: h,
                          anchor: FocusAnchor(epoch: 1, sampledAt: t, resolved: resolved)))
        let idx = UInt32(ax.count)
        return [InputEvent(t: t, kind: .down, x: Float(x), y: Float(y), button: 0, axFrameIndex: idx)]
    }

    private func rect(_ s: ZoomSegment) -> CGRect? {
        guard case .element(let x, let y, let w, let h) = s.focus else { return nil }
        return CGRect(x: x * W, y: y * H, width: w * W, height: h * H)
    }

    // MARK: Fix 1 - scale adapts to the subject

    @Test func varyingElementSizesProduceVaryingScales() {
        let sizes: [(Double, Double)] = [(50, 24), (150, 60), (400, 160), (700, 320), (1100, 520)]
        var ax: [AXFrame] = [], ev: [InputEvent] = []
        for (i, s) in sizes.enumerated() {
            let x = 400.0 + Double(i % 2) * 700
            let y = 160.0 + Double(i) * 130
            ev += click(1.0 + Double(i) * 4.0, x, y, w: s.0, h: s.1, &ax)
        }
        let out = plan(ev, ax, 24)
        let segs = out.segments.sorted { $0.start < $1.start }
        #expect(segs.count == sizes.count, "expected one shot per click, got \(segs.count)")
        let scales = segs.map(\.scale)
        #expect(Set(scales).count >= 3, "scales did not spread: \(scales)")
        #expect(!scales.allSatisfy { abs($0 - 2.0) < 1e-6 }, "every shot still pinned to maxScale: \(scales)")
        if let small = scales.first, let large = scales.last {
            #expect(small > large + 0.15, "small subject \(small) not closer than large \(large)")
        }
        #expect(scales.suffix(2).allSatisfy { $0 < 2.0 - 0.05 },
                Comment(rawValue: "large subjects still hit maxScale: \(scales)"))
    }

    @Test func tinyControlStillEarnsCloseLook() {
        var ax: [AXFrame] = [], ev: [InputEvent] = []
        ev += click(2.0, 960, 540, w: 40, h: 24, &ax)
        let out = plan(ev, ax, 6)
        #expect(out.segments.count == 1)
        #expect((out.segments.first?.scale ?? 0) >= 1.8)
    }

    // MARK: Fix 2 - a newly resolved dialog is its own subject

    @Test func newlyOpenedAXDialogOpensItsOwnShotCentredOnTheDialog() {
        var ax: [AXFrame] = [], ev: [InputEvent] = []
        ev += click(1.0, 500, 300, w: 80, h: 40, &ax)      // the Share button
        var dialog = AXFrame(x: 600, y: 250, w: 720, h: 420,
                             anchor: FocusAnchor(epoch: 2, sampledAt: 1.6, resolved: true))
        dialog.sampledAt = 1.6
        ax.append(dialog)                                  // resolved, not the clicked element
        let out = plan(ev, ax, 8)
        let segs = out.segments.sorted { $0.start < $1.start }
        #expect(segs.count >= 2, "dialog must be its own shot, got \(segs.count)")
        guard segs.count >= 2 else { return }
        #expect(segs[0].end <= 1.6 + 1e-6, "click shot should close when dialog opens: \(segs[0])")
        #expect(abs(segs[1].start - 1.6) < 1e-6, "dialog shot must start at its appearance: \(segs[1])")
        guard let framed = rect(segs[1]) else {
            Issue.record("dialog shot must frame the whole dialog, got \(segs[1].focus)"); return
        }
        for (got, want) in [(framed.minX, 600.0), (framed.minY, 250.0),
                            (framed.width, 720.0), (framed.height, 420.0)] {
            #expect(abs(got - want) < 1, "dialog rect \(framed)")
        }
        #expect(segs[1].scale < 2.0 - 0.05, "large dialog should earn a gentler scale: \(segs[1].scale)")
        #expect(720 * segs[1].scale <= W && 420 * segs[1].scale <= H,
                Comment(rawValue: "dialog would still be cropped at scale \(segs[1].scale)"))
    }

    @Test func largeDialogMarkerFramesWholePanelAndBeatsPriorTyping() {
        var ax: [AXFrame] = [], ev: [InputEvent] = []
        // A typing burst into the address bar, then a colour/finish panel opens.
        var field = AXFrame(x: 700, y: 40, w: 500, h: 40,
                            anchor: FocusAnchor(epoch: 1, sampledAt: 1.0, resolved: true))
        field.caret = AXFrame.Rect(x: 704, y: 48, w: 2, h: 24); field.sampledAt = 1.0
        ax.append(field)
        for k in 0..<6 {
            ev.append(InputEvent(t: 1.0 + Double(k) * 0.12, kind: .keyDown,
                                 keyCode: UInt16(k), axFrameIndex: 1))
        }
        let panel = CGRect(x: 640 / W, y: 180 / H, width: 640 / W, height: 520 / H)
        let marker = DirectorMarker(start: 3.0, end: 4.2, rect: panel, label: "Finish")
        let out = plan(ev, ax, 9, markers: [marker])
        let segs = out.segments.sorted { $0.start < $1.start }
        #expect(segs.count >= 2, "dialog marker must open a new shot, got \(segs.count)")
        guard segs.count >= 2 else { return }
        guard let framed = rect(segs.last!) else {
            Issue.record("panel marker shot must frame the whole panel"); return
        }
        #expect(abs(framed.minX - 640) < 1 && abs(framed.width - 640) < 1,
                Comment(rawValue: "panel rect \(framed)"))
        #expect(segs.last!.start >= 2.99, "panel shot must start at its marker")
    }

    @Test func windowLabelledDialogFrameAtClickSlotIsTheSubject() {
        // Agent 3 publishes the resolved dialog into the click's own AX slot,
        // labelled `window|...`. The click must not steal the dialog's framing.
        var ax: [AXFrame] = []
        ax.append(AXFrame(x: 640, y: 220, w: 680, h: 440,
                          label: "window|AXSheet|AXStandardSheet|Share your card",
                          anchor: FocusAnchor(epoch: 2, sampledAt: 1.0, resolved: true)))
        let click = InputEvent(t: 1.0, kind: .down, x: 910, y: 610, button: 0, axFrameIndex: 1)
        let out = plan([click], ax, 7)
        #expect(out.segments.count == 1, "one shot for the dialog, got \(out.segments.count)")
        guard let s = out.segments.first else { return }
        guard let framed = rect(s) else {
            Issue.record("window-labelled dialog must be framed whole, got \(s.focus)"); return
        }
        for (got, want) in [(framed.minX, 640.0), (framed.minY, 220.0),
                            (framed.width, 680.0), (framed.height, 440.0)] {
            #expect(abs(got - want) < 1, "dialog rect \(framed)")
        }
        #expect(s.scale < 2.0 - 0.05, "dialog should not hit maxScale: \(s.scale)")
    }

    @Test func clickedLargeFrameIsNotMistakenForADialog() {
        // A click's own AX frame is evidence about a control, never a new dialog.
        var ax: [AXFrame] = [], ev: [InputEvent] = []
        ev += click(2.0, 960, 540, w: 900, h: 500, &ax)
        let out = plan(ev, ax, 8)
        #expect(out.segments.count == 1)
        guard let s = out.segments.first else { return }
        // Its focus is either the exact click point or its rect, but it must not
        // be re-labelled as a dialog shot opening later.
        #expect(abs(s.start - 2.0) < 1e-6)
    }

    // MARK: Fix 3 - typing re-aims immediately

    @Test func typingReAimsAtResolvedFieldOnFirstKeystroke() {
        var ax: [AXFrame] = [], ev: [InputEvent] = []
        ev += click(1.0, 400, 300, &ax)                    // earlier click
        var field = AXFrame(x: 700, y: 200, w: 400, h: 44,
                            anchor: FocusAnchor(epoch: 3, sampledAt: 2.0, resolved: true))
        field.caret = AXFrame.Rect(x: 704, y: 210, w: 2, h: 24); field.sampledAt = 2.0
        ax.append(field)
        let fidx = UInt32(ax.count)
        for k in 0..<8 {
            ev.append(InputEvent(t: 2.0 + Double(k) * 0.12, kind: .keyDown,
                                 keyCode: UInt16(k), axFrameIndex: fidx))
        }
        let out = plan(ev, ax, 8)
        let segs = out.segments.sorted { $0.start < $1.start }
        #expect(segs.count == 2, "typing must be its own shot, got \(segs.count)")
        guard segs.count == 2 else { return }
        #expect(segs[0].end <= 2.0 + 1e-6, "click shot must give way at first key: \(segs[0])")
        #expect(abs(segs[1].start - 2.0) < 1e-6,
                Comment(rawValue: "typing shot must start at the first key, got \(segs[1].start)"))
        guard let framed = rect(segs[1]) else {
            Issue.record("typing shot must frame the field, got \(segs[1].focus)"); return
        }
        for (got, want) in [(framed.minX, 700.0), (framed.minY, 200.0),
                            (framed.width, 400.0), (framed.height, 44.0)] {
            #expect(abs(got - want) < 1, "typing field \(framed)")
        }
        #expect(out.follow[segs[1].id] == nil, "typing must not carry a caret follow path")
    }

    // MARK: Fix 4 - holds end with the action

    @Test func sixtySecondDenseSessionHasNoEightSecondShot() {
        var ax: [AXFrame] = [], ev: [InputEvent] = []
        var t = 0.5, i = 0
        while t < 59.5 {
            let x = (i % 2 == 0) ? 420.0 : 1500.0
            let y = 220.0 + Double(i % 4) * 150
            ev += click(t, x, y, w: 120, h: 60, &ax)
            t += 0.35; i += 1
        }
        let out = plan(ev, ax, 60)
        let segs = out.segments.sorted { $0.start < $1.start }
        #expect(!segs.isEmpty)
        let longest = segs.map { $0.end - $0.start }.max() ?? 0
        #expect(longest < 4.0, Comment(rawValue: "dense session produced a \(longest)s shot"))
        for k in 1..<max(segs.count, 1) {
            #expect(segs[k].start >= segs[k - 1].end - 1e-6,
                    Comment(rawValue: "overlap [\(segs[k-1].start),\(segs[k-1].end)] [\(segs[k].start),\(segs[k].end)]"))
        }
    }

    @Test func singleClickReturnsPromptlyAfterActivityStops() {
        var ax: [AXFrame] = [], ev: [InputEvent] = []
        ev += click(2.0, 960, 540, &ax)
        let out = plan(ev, ax, 8)
        guard let s = out.segments.first else { Issue.record("no shot"); return }
        #expect(s.end - s.start < 2.6, "a lone click held for \(s.end - s.start)s")
    }

    // MARK: Fix 5 - determinism / no overlaps under hostile input

    @Test func planIsDeterministicAcrossAllIntentKinds() {
        var ax: [AXFrame] = [], ev: [InputEvent] = []
        ev += click(1.0, 500, 300, &ax)
        var field = AXFrame(x: 700, y: 200, w: 400, h: 44,
                            anchor: FocusAnchor(epoch: 3, sampledAt: 2.0, resolved: true))
        field.caret = AXFrame.Rect(x: 704, y: 210, w: 2, h: 24); field.sampledAt = 2.0
        ax.append(field)
        for k in 0..<6 {
            ev.append(InputEvent(t: 2.0 + Double(k) * 0.12, kind: .keyDown,
                                 keyCode: UInt16(k), axFrameIndex: 2))
        }
        var d = AXFrame(x: 600, y: 250, w: 720, h: 420,
                        anchor: FocusAnchor(epoch: 4, sampledAt: 4.0, resolved: true))
        d.sampledAt = 4.0
        ax.append(d)
        let activity = (0..<3).map { ActivityPoint(t: 5.0 + Double($0) * 0.1, x: 1300, y: 700,
                                                  region: CGRect(x: 1250, y: 650, width: 180, height: 120),
                                                  coverage: 0.04) }
        let marker = DirectorMarker(start: 6.2, end: 6.8,
                                    rect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let a = plan(ev, ax, 9, activity: activity, markers: [marker])
        let b = plan(ev, ax, 9, activity: activity, markers: [marker])
        #expect(a.segments == b.segments)
        #expect(Set(a.follow.keys) == Set(b.follow.keys))
        for (k, va) in a.follow {
            guard let vb = b.follow[k] else { Issue.record("missing path \(k)"); continue }
            let pa = va.map { ($0.t, $0.p.x, $0.p.y) }
            let pb = vb.map { ($0.t, $0.p.x, $0.p.y) }
            #expect(pa.count == pb.count && zip(pa, pb).allSatisfy { x, y in x.0 == y.0 && x.1 == y.1 && x.2 == y.2 })
        }
        let segs = a.segments.sorted { $0.start < $1.start }
        for k in 1..<max(segs.count, 1) {
            #expect(segs[k].start >= segs[k - 1].end - 1e-6)
        }
    }
}
