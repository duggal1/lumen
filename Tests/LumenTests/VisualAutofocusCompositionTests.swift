import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - Composition with the other agents
//
// Visual autofocus is the passive layer. Explicit input (Agents 1 and 3) and
// the conservative VisualZoom baseline must coexist without double shots and
// without hover ever opening a camera move.

@Suite struct VisualAutofocusCompositionTests {
    private let W = 1920.0, H = 1080.0

    private func source(_ dur: Double = 20) -> SourceInfo {
        SourceInfo(width: Int(W), height: Int(H), fps: 60, duration: dur,
                   backingScale: 1, originX: 0, originY: 0)
    }
    private func tm(_ dur: Double = 20) -> TimeMap { TimeMap(sourceDuration: dur) }

    private func stable(_ t0: Double, _ r: CGRect, count: Int = 6,
                        coverage: Double? = nil, dt: Double = 0.1) -> [ActivityPoint] {
        let cov = coverage ?? Double((r.width * r.height) / (W * H))
        return (0..<count).map { i in
            ActivityPoint(t: t0 + Double(i) * dt, x: r.midX, y: r.midY,
                          region: r, coverage: cov)
        }
    }

    @Test func clickAndTypingIntentsSuppressNearbyVisualBeats() {
        let r1 = CGRect(x: 1300, y: 600, width: 300, height: 220)
        let r2 = CGRect(x: 500, y: 500, width: 320, height: 200)
        let pts = stable(5.0, r1) + stable(6.2, r2)
        let click = ZoomPlanner.Intent(kind: .click, t: 5.1, tEnd: 5.1, x: 1400, y: 700)
        let typing = ZoomPlanner.Intent(kind: .typing, t: 6.0, tEnd: 6.9, x: 600, y: 560,
                                        rect: r2, frameRect: r2)
        let d = VisualAutofocus.analyze(pts, events: [], input: [click, typing],
                                        src: source(), tm: tm())
        #expect(d.beats.isEmpty, "explicit input outranks passive pixels: \(d.beats)")
        #expect(d.rejections.filter { $0 == .inputOverlap }.count >= 2, "got \(d.rejections)")
        let out = VisualAutofocus.intents(pts, events: [], input: [click, typing],
                                          src: source(), tm: tm())
        #expect(out.isEmpty, "no duplicate shot may be left behind: \(out)")
    }

    @Test func ownBeatWinsOverBaselineWithoutProducingTwoShots() {
        let r = CGRect(x: 1200, y: 600, width: 320, height: 240)
        let pts = stable(5.0, r, count: 6)
        let out = VisualAutofocus.intents(pts, events: [], input: [], src: source(), tm: tm())
        #expect(out.count == 1, "baseline and detector must not both fire: \(out)")
        guard let one = out.first else { return }
        #expect(one.kind == .visual)
        #expect(one.frameRect == r, "our whole-subject framing must win over the baseline centre shot")
    }

    @Test func hoverBiasIsRemovedFromTheBaseline() {
        // Two observations 0.35 s apart near the pointer. VisualZoom lowers its
        // minimum to 2 when the pointer is near; visual autofocus never does.
        let r = CGRect(x: 940, y: 520, width: 300, height: 220)
        let pts = [
            ActivityPoint(t: 5.0, x: r.midX, y: r.midY, region: r, coverage: 0.04),
            ActivityPoint(t: 5.35, x: r.midX, y: r.midY, region: r, coverage: 0.04),
        ]
        let moves = [InputEvent(t: 5.0, kind: .move, x: 1090, y: 630),
                     InputEvent(t: 5.35, kind: .move, x: 1090, y: 630)]
        let biased = VisualZoom.intents(pts, events: moves, input: [], src: source(), tm: tm())
        #expect(biased.count == 1, "precondition: pointer bias opens a baseline shot")
        let out = VisualAutofocus.intents(pts, events: moves, input: [], src: source(), tm: tm())
        #expect(out.isEmpty, "hover bias must be stripped before composition: \(out)")
    }

    @Test func cooldownPreventsCameraPumping() {
        let a = stable(5.0, CGRect(x: 1300, y: 600, width: 240, height: 180))
        let b = stable(6.6, CGRect(x: 400, y: 300, width: 240, height: 180))
        let d = VisualAutofocus.analyze(a + b, src: source(), tm: tm())
        #expect(d.beats.count == 1, "two results 1.6 s apart are one shot: \(d.beats)")
        #expect(d.rejections.contains(.cooldown), "got \(d.rejections)")
    }

    @Test func emptyAndMalformedEvidenceProducesNothing() {
        let d0 = VisualAutofocus.analyze([], src: source(), tm: tm())
        #expect(d0.beats.isEmpty)
        let bad = [
            ActivityPoint(t: Double.nan, x: 10, y: 10, region: CGRect(x: 0, y: 0, width: 100, height: 100), coverage: 0.1),
            ActivityPoint(t: 2, x: .infinity, y: 10, region: CGRect(x: 0, y: 0, width: 100, height: 100), coverage: 0.1),
            ActivityPoint(t: 3, x: 10, y: 10, region: CGRect(x: Double.nan, y: 0, width: 100, height: 100), coverage: 0.1),
            ActivityPoint(t: 4, x: 10, y: 10, region: CGRect(x: 0, y: 0, width: -5, height: 100), coverage: 0.1),
        ]
        let d1 = VisualAutofocus.analyze(bad, src: source(), tm: tm())
        #expect(d1.beats.isEmpty)
        #expect(d1.rejections.filter { $0 == .invalid }.count >= 3, "got \(d1.rejections)")
        #expect(VisualAutofocus.intents(bad, events: [], input: [], src: source(), tm: tm()).isEmpty)
    }

    @Test func trimAndCutsSuppressBeats() {
        let r = CGRect(x: 700, y: 400, width: 300, height: 200)
        var tm = TimeMap(sourceDuration: 12)
        tm.cuts = [CutRange(start: 4, end: 7)]
        let inCut = stable(5.0, r)
        #expect(VisualAutofocus.analyze(inCut, src: source(12), tm: tm).beats.isEmpty)
        let outside = stable(9.0, r)
        tm.trimEnd = 9.2
        #expect(VisualAutofocus.analyze(outside, src: source(12), tm: tm).beats.isEmpty)
    }

    @Test func heldTimeIsShortAndScalesWithSubjectSize() {
        let small = stable(5.0, CGRect(x: 1300, y: 700, width: 160, height: 120))
        let large = stable(5.0, CGRect(x: 600, y: 300, width: 900, height: 560), coverage: 0.22)
        guard let sb = VisualAutofocus.analyze(small, src: source(), tm: tm()).beats.first,
              let lb = VisualAutofocus.analyze(large, src: source(), tm: tm()).beats.first else {
            Issue.record("expected two beats"); return
        }
        let sd = sb.intent.tEnd - sb.intent.t, ld = lb.intent.tEnd - lb.intent.t
        #expect(sd > 0.5 && sd < 2.6, "small subject held \(sd)s")
        #expect(ld > 0.5 && ld < 2.6, "large subject held \(ld)s")
        #expect(ld > sd, "a larger result earns more reading time: \(sd) vs \(ld)")
    }
}
