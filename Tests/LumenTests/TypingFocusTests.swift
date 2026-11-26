import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - Typing focus (headless)
//
// The screenshots showed one continuous address-bar typing session becoming a
// run of adjacent `2.0x Auto` blocks, with the zoom starting after the first
// key. Every test drives the real planner / Director.derive, never a mock.

@Suite struct TypingFocusTests {
    private let W = 1920.0, H = 1080.0

    private func source(_ dur: Double = 12) -> SourceInfo {
        SourceInfo(width: Int(W), height: Int(H), fps: 60, duration: dur,
                   backingScale: 2, originX: 0, originY: 0)
    }

    private func derive(_ events: [InputEvent], _ ax: [AXFrame], _ dur: Double,
                        sensitivity: Double = 0, markers: [DirectorMarker] = []) -> Timeline {
        var tl = Timeline(duration: dur)
        tl.audio.speedRampsAuto = false
        tl.camera.sensitivity = sensitivity
        return Director.derive(tl, input: DirectorInput(events: events.sorted { $0.t < $1.t },
                                                       source: source(dur), ax: ax, markers: markers),
                               revision: 1)
    }

    private func field(_ rect: CGRect, epoch: UInt32 = 1, sampledAt: Double = 0) -> AXFrame {
        var f = AXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height,
                        label: "Address and search bar",
                        anchor: FocusAnchor(epoch: epoch, sampledAt: sampledAt,
                                            appName: "Google Chrome", resolved: true))
        f.sampledAt = sampledAt
        f.caret = AXFrame.Rect(x: rect.minX + 6, y: rect.minY + 8, w: 2, h: 24)
        return f
    }

    private func keys(_ count: Int, from t0: Double, step: Double, index: UInt32) -> [InputEvent] {
        (0..<count).map { InputEvent(t: t0 + Double($0) * step, kind: .keyDown,
                                     keyCode: UInt16($0 % 40), axFrameIndex: index) }
    }

    private func elementRect(_ s: ZoomSegment) -> CGRect? {
        guard case .element(let x, let y, let w, let h) = s.focus else { return nil }
        return CGRect(x: x * W, y: y * H, width: w * W, height: h * H)
    }

    private func near(_ a: CGRect, _ b: CGRect, tol: CGFloat = 0.01) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol &&
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// The shot must begin on the FIRST key, frame the whole resolved field,
    /// and carry no follow path.
    @Test func typingShotStartsOnFirstKeystrokeAndFramesTheField() {
        let rect = CGRect(x: 600, y: 300, width: 500, height: 40)
        var ax: [AXFrame] = []
        let firstKey = 2.0
        ax.append(field(rect, sampledAt: firstKey))
        let ev = keys(10, from: firstKey, step: 0.11, index: 1)
        let shots = TypingFocus.shots(events: ev, ax: ax, traces: [], W: W, H: H, b: 2,
                                      trimStart: 0, trimEnd: 12)
        #expect(shots.count == 1)
        #expect(abs(shots[0].t0 - firstKey) < 1e-9)
        #expect(abs(shots[0].t1 - ev.last!.t) < 1e-9)
        #expect(ev.allSatisfy { shots[0].covers($0.t) })

        let tl = derive(ev, ax, 12)
        let segs = tl.zoom.sorted { $0.start < $1.start }
        #expect(segs.count == 1, "expected one shot, got \(segs.count)")
        guard let s = segs.first else { return }
        #expect(abs(s.start - firstKey) < 1e-6, "shot started at \(s.start), not the first key")
        #expect(near(elementRect(s) ?? .zero, rect), "framed \(String(describing: elementRect(s)))")
        let plan = ZoomPlanner.plan(events: ev, ax: ax, typing: [], activity: [],
                                    src: source(12), p: tl.camera,
                                    tm: TimeMap(sourceDuration: 12), avoid: [])
        #expect(plan.follow.isEmpty, "typing must not carry a caret follow path")
    }

    /// One continuous typing session is ONE shot. The old path emitted a run of
    /// adjacent 2.0x Auto blocks because 0.9 s gaps split it into many bursts.
    @Test func continuousTypingMakesOneShotNotAdjacentAutoBlocks() {
        let rect = CGRect(x: 520, y: 60, width: 700, height: 34)
        var ax: [AXFrame] = []
        ax.append(field(rect, sampledAt: 1.0))
        var ev: [InputEvent] = []
        for k in 0..<40 { ev.append(InputEvent(t: 1.0 + Double(k) * 0.12,
                                               kind: .keyDown, keyCode: UInt16(k % 40),
                                               axFrameIndex: 1)) }
        let shots = TypingFocus.shots(events: ev, ax: ax, traces: [], W: W, H: H, b: 2,
                                      trimStart: 0, trimEnd: 16)
        #expect(shots.count == 1, "typing was split into \(shots.count) shots")

        let tl = derive(ev, ax, 16)
        // Repeated 2.0x blocks in one typing window are the exact screenshot bug.
        let nearTwo = tl.zoom.filter { abs($0.scale - 2.0) < 1e-6 }
        #expect(nearTwo.count <= 1, "got \(nearTwo.count) adjacent 2.0x blocks")
        let inWindow = tl.zoom.filter { $0.start >= 0.99 && $0.start <= 5.7 }
        #expect(inWindow.count == 1, "typing window contains \(inWindow.count) shots")
        for k in 1..<tl.zoom.count {
            #expect(tl.zoom[k].start >= tl.zoom[k - 1].end - 1e-6)
        }
    }

    /// A short pause in the same field is still one interaction; a genuinely
    /// different field is a different shot.
    @Test func sameFieldPauseCoalescesDifferentFieldDoesNot() {
        let a = CGRect(x: 300, y: 200, width: 400, height: 40)
        let b = CGRect(x: 1100, y: 700, width: 300, height: 40)
        var ax: [AXFrame] = []
        ax.append(field(a, sampledAt: 1.0))
        ax.append(field(b, epoch: 2, sampledAt: 3.4))
        var ev = keys(4, from: 1.0, step: 0.1, index: 1)
        ev += keys(4, from: 3.4, step: 0.1, index: 2)
        let one = TypingFocus.shots(events: ev, ax: ax, traces: [], W: W, H: H, b: 2,
                                    trimStart: 0, trimEnd: 8)
        #expect(one.count == 2, "same-field coalescing should not merge different fields: \(one)")
        #expect(abs(one[1].t0 - 3.4) < 1e-9)

        // Same field, 0.7 s pause: one shot ending on the last key.
        var ax2: [AXFrame] = []
        ax2.append(field(a, sampledAt: 1.0))
        let ev2 = keys(4, from: 1.0, step: 0.1, index: 1) + keys(4, from: 2.6, step: 0.1, index: 1)
        let merged = TypingFocus.shots(events: ev2, ax: ax2, traces: [], W: W, H: H, b: 2,
                                       trimStart: 0, trimEnd: 8)
        #expect(merged.count == 1, "same field with a short pause became \(merged.count) shots")
        #expect(abs(merged[0].t1 - 2.9) < 1e-9)
    }

    /// No resolved field means no shot. The old synthetic last-click rect made
    /// a bogus 2.0x shot out of every keystroke burst.
    @Test func unresolvedFieldNeverInventsAShot() {
        var ax: [AXFrame] = []
        var f = AXFrame(x: 600, y: 300, w: 400, h: 40)
        f.anchor = FocusAnchor(epoch: 1, sampledAt: 2, resolved: false)
        f.caret = AXFrame.Rect(x: 606, y: 308, w: 2, h: 24)
        ax.append(f)
        let ev = keys(8, from: 2.0, step: 0.1, index: 1)
        #expect(TypingFocus.shots(events: ev, ax: ax, traces: [], W: W, H: H, b: 2,
                                  trimStart: 0, trimEnd: 10).isEmpty)
        let tl = derive(ev, ax, 10)
        #expect(tl.zoom.isEmpty, "unresolved typing invented a shot")
    }

    /// The camera centre must not chase the caret, including across a wrap.
    @Test func typingCentreIsSteadyAcrossACaretWrap() {
        let rect = CGRect(x: 560, y: 420, width: 800, height: 80)
        var ax: [AXFrame] = []
        var ev: [InputEvent] = []
        for i in 0..<20 {
            var f = field(rect, sampledAt: 3.0)
            let wrapped = i >= 14
            f.caret = AXFrame.Rect(x: 580 + Double(wrapped ? i - 14 : i) * 36,
                                   y: wrapped ? 466 : 430, w: 2, h: 28)
            ax.append(f)
            ev.append(InputEvent(t: 3.0 + Double(i) * 0.18, kind: .keyDown,
                                 keyCode: 7, axFrameIndex: UInt32(i + 1)))
        }
        let tl = derive(ev, ax, 16)
        var lo = SIMD2(Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)
        var hi = SIMD2(-Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        for k in 0...120 {
            let p = tl.evaluate(at: 3.45 + Double(k) * 0.02)
            lo = SIMD2(min(lo.x, Double(p.cameraCenter.x)), min(lo.y, Double(p.cameraCenter.y)))
            hi = SIMD2(max(hi.x, Double(p.cameraCenter.x)), max(hi.y, Double(p.cameraCenter.y)))
        }
        let drift = Double(hypot(hi.x - lo.x, hi.y - lo.y))
        #expect(drift <= 4.0, "camera wandered \(drift) source px while typing")
    }

    /// A dialog opened mid-typing is a different, first-class subject: the
    /// typing shot ends when the dialog appears and the dialog is framed whole.
    @Test func dialogStillBeatsTypingAsItsOwnShot() {
        let rect = CGRect(x: 600, y: 60, width: 700, height: 34)
        var ax: [AXFrame] = []
        ax.append(field(rect, sampledAt: 1.0))
        let ev = keys(8, from: 1.0, step: 0.1, index: 1)
        let dialog = CGRect(x: 620, y: 260, width: 680, height: 440)
        let marker = DirectorMarker(start: 3.0, end: 4.2,
                                    rect: CGRect(x: dialog.minX / W, y: dialog.minY / H,
                                                 width: dialog.width / W, height: dialog.height / H),
                                    label: "Finish")
        let tl = derive(ev, ax, 9, markers: [marker])
        let segs = tl.zoom.sorted { $0.start < $1.start }
        #expect(segs.count >= 2, "dialog must not be folded into the typing shot")
        guard segs.count >= 2 else { return }
        #expect(segs[0].end <= 3.0 + 1e-6, "typing shot ran past the dialog")
        let last = segs.last!
        #expect(abs(last.start - 3.0) < 1e-6, "dialog shot started at \(last.start)")
        #expect(near(elementRect(last) ?? .zero, dialog), "dialog framed as \(String(describing: elementRect(last)))")
    }

    /// Hover is not a subject. Even a long deliberate dwell with maximum
    /// sensitivity must not open a shot.
    @Test func hoverNeverOpensAShot() {
        var ev: [InputEvent] = []
        for i in 0..<20 {
            ev.append(InputEvent(t: 1.0 + Double(i) * 0.12, kind: .move,
                                 x: 700, y: 400))
        }
        let tl = derive(ev, [], 8, sensitivity: 1.0)
        #expect(tl.zoom.isEmpty, "hover opened \(tl.zoom.count) shots")

        // A real click still works with the same sensitivity.
        var ax: [AXFrame] = []
        let click = InputEvent(t: 2.0, kind: .down, x: 700, y: 400, button: 0, axFrameIndex: 1)
        ax.append(AXFrame(x: 680, y: 380, w: 40, h: 40,
                          anchor: FocusAnchor(epoch: 1, sampledAt: 2, resolved: true)))
        let withClick = derive(ev + [click], ax, 8, sensitivity: 1.0)
        #expect(withClick.zoom.count == 1, "a click must still earn its shot")
    }

    @Test func pixelFallbackRequiresCorroboratedCaretEvidence() {
        let rect = CGRect(x: 600, y: 300, width: 400, height: 40)
        let ev = keys(6, from: 2, step: 0.1, index: 0)
        let held = TypingTrace(t0: 2, t1: 2.5, rect: rect, samples: [
            .init(t: 2.1, x: 620, y: 320, confidence: 0.15, evidence: .held),
            .init(t: 2.3, x: 640, y: 320, confidence: 0.4, evidence: .blink)
        ], line: rect)
        let good = TypingTrace(t0: 2, t1: 2.5, rect: rect, samples: [
            .init(t: 2.1, x: 620, y: 320, confidence: 0.95, evidence: .caret),
            .init(t: 2.3, x: 640, y: 320, confidence: 0.9, evidence: .caret)
        ], line: rect)
        func shots(_ traces: [TypingTrace]) -> [TypingFocus.Shot] {
            TypingFocus.shots(events: ev, ax: [], traces: traces, W: W, H: H, b: 2,
                              trimStart: 0, trimEnd: 10)
        }
        #expect(shots([held]).isEmpty)
        #expect(shots([held, good]).first?.field == rect)
        var unrelated = good
        unrelated.samples = good.samples.map { .init(t: $0.t, x: 100, y: 100, confidence: 0.95) }
        #expect(shots([unrelated]).isEmpty)
    }

    @Test func nestedGeometryCannotMergeDifferentFocusEpochs() {
        let a = CGRect(x: 300, y: 200, width: 500, height: 100)
        let b = CGRect(x: 320, y: 220, width: 300, height: 40)
        let ax = [field(a, epoch: 1, sampledAt: 1), field(b, epoch: 2, sampledAt: 1.4)]
        let ev = keys(3, from: 1, step: 0.1, index: 1) + keys(3, from: 1.4, step: 0.1, index: 2)
        let shots = TypingFocus.shots(events: ev, ax: ax, traces: [], W: W, H: H, b: 2,
                                      trimStart: 0, trimEnd: 10)
        #expect(shots.count == 2)
        #expect(shots.map(\.field) == [a, b])
    }

    /// 200 seeded sessions: byte-identical replans, no overlapping segments,
    /// no teleport in the solved camera track.
    @Test func twoHundredSeedDeterminismNoOverlapNoTeleport() {
        var failures: [String] = []
        for seed in 1...200 {
            let (input, dur) = BrutalScenario.make(seed: UInt64(seed))
            let a = BrutalScenario.derive(input, dur)
            let b = BrutalScenario.derive(input, dur)
            if a.zoom != b.zoom { failures.append("seed \(seed): zoom differs") }
            if a.derived?.camera != b.derived?.camera { failures.append("seed \(seed): camera differs") }
            failures += BrutalCheck.camera(a, maxScale: a.camera.maxScale, label: "seed \(seed)")
            if failures.count > 6 { break }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
}
