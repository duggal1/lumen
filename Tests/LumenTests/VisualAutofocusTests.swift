import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - Passive visual autofocus
//
// Synthetic 10 Hz `ActivityPoint` streams fed to the real detector. No window,
// no pixels decoded, no GUI. These are the behaviours the camera must get from
// a demo where the user never clicks and never hovers.

private struct IntentFingerprint: Equatable {
    let t: Double, tEnd: Double, x: Double, y: Double, w: Double
}

@Suite struct VisualAutofocusTests {
    private let W = 1920.0, H = 1080.0

    private func source(_ dur: Double = 20) -> SourceInfo {
        SourceInfo(width: Int(W), height: Int(H), fps: 60, duration: dur,
                   backingScale: 1, originX: 0, originY: 0)
    }

    private func tm(_ dur: Double = 20) -> TimeMap { TimeMap(sourceDuration: dur) }

    /// A stable 10 Hz changed region, the way ActivityAnalyzer emits a result
    /// that has settled (it re-checks against the pre-change frame for 0.4 s).
    private func stable(_ t0: Double, _ r: CGRect, count: Int = 5,
                        coverage: Double? = nil, dt: Double = 0.1) -> [ActivityPoint] {
        let cov = coverage ?? Double((r.width * r.height) / (W * H))
        return (0..<count).map { i in
            ActivityPoint(t: t0 + Double(i) * dt, x: r.midX, y: r.midY,
                          region: r, coverage: cov)
        }
    }

    private func analyze(_ points: [ActivityPoint],
                         events: [InputEvent] = [],
                         input: [ZoomPlanner.Intent] = [],
                         dur: Double = 20) -> VisualAutofocus.Decision {
        VisualAutofocus.analyze(points, events: events, input: input,
                                src: source(dur), tm: tm(dur))
    }

    // MARK: Positives — the five real product moments

    @Test func resultAppearingCreatesOneHeldBeat() {
        let r = CGRect(x: 1400, y: 700, width: 200, height: 200)
        let d = analyze(stable(5.0, r))
        #expect(d.beats.count == 1, "a settled result must open one shot, got \(d.beats)")
        guard let b = d.beats.first else { return }
        #expect(b.kind == .result, "got \(b.kind)")
        #expect(b.observations >= 3)
        #expect(b.intent.kind == .visual)
        #expect(b.intent.frameRect == r, "the whole result must be framed, got \(String(describing: b.intent.frameRect))")
        #expect(b.intent.t < b.intent.tEnd)
        #expect(abs(b.intent.t - 5.0) < 1e-6,
                "shot must be marked at the first change; the camera solver supplies lead-in, t=\(b.intent.t)")
        #expect(b.intent.tEnd - b.intent.t < 2.6, "shot must not sit for 8 s")
    }

    @Test func designRevealFramesTheWholeImageWithGentleMagnification() {
        let r = CGRect(x: 700, y: 300, width: 800, height: 500)   // 17% of frame
        let d = analyze(stable(4.0, r, count: 6, coverage: 0.12))
        #expect(d.beats.count == 1)
        guard let b = d.beats.first else { return }
        #expect(b.kind == .reveal, "got \(b.kind)")
        #expect(b.intent.frameRect == r)
        #expect(b.intent.rect == r)
    }

    @Test func textChangingWithNoTypingInputCreatesAWideBeat() {
        let r = CGRect(x: 400, y: 500, width: 1000, height: 60)
        let d = analyze(stable(6.0, r, count: 5, dt: 0.1))         // no keyDown at all
        #expect(d.beats.count == 1)
        #expect(d.beats.first?.kind == .textChange, "got \(String(describing: d.beats.first?.kind))")
        #expect(d.beats.first?.intent.frameRect?.width == 1000)
    }

    @Test func cardDrawUnionsGrowingObservationsIntoOneBeat() {
        let rects = [
            CGRect(x: 900, y: 480, width: 120, height: 80),
            CGRect(x: 900, y: 470, width: 200, height: 130),
            CGRect(x: 900, y: 450, width: 300, height: 200),
            CGRect(x: 900, y: 440, width: 400, height: 260),
            CGRect(x: 900, y: 430, width: 460, height: 300),
        ]
        let pts = rects.enumerated().map { i, r in
            ActivityPoint(t: 8.0 + Double(i) * 0.1, x: r.midX, y: r.midY,
                          region: r, coverage: Double(r.width * r.height) / (W * H))
        }
        let d = analyze(pts)
        #expect(d.beats.count == 1)
        guard let b = d.beats.first else { return }
        #expect(b.kind == .cardDraw, "got \(b.kind)")
        #expect(b.intent.frameRect == CGRect(x: 900, y: 430, width: 460, height: 300),
                "union of the growing card: \(String(describing: b.intent.frameRect))")
    }

    @Test func panelOpeningWithoutAClickFramesTheWholePanel() {
        let r = CGRect(x: 640, y: 180, width: 800, height: 700)   // 27% of frame
        let d = analyze(stable(10.0, r, count: 6, coverage: 0.30))
        #expect(d.beats.count == 1)
        guard let b = d.beats.first else { return }
        #expect(b.kind == .panelOpen, "got \(b.kind)")
        #expect(b.intent.frameRect == r, "a passive panel must not be cropped at the frame edge")
    }

    // MARK: Negatives — things that must never open a shot

    @Test func hoverOnlyHighlightNeverTriggers() {
        let r = CGRect(x: 940, y: 520, width: 60, height: 20)
        let pts = stable(3.0, r, count: 6, coverage: 0.002)
        let moves = (0..<6).map { InputEvent(t: 3.0 + Double($0) * 0.1, kind: .move,
                                             x: 970, y: 530) }
        let d = analyze(pts, events: moves)
        #expect(d.beats.isEmpty, "hover must never open a zoom: \(d.beats)")
        #expect(d.rejections.contains(.hoverOnly), "got \(d.rejections)")
    }

    @Test func scrollingNearAChangeNeverTriggers() {
        let r = CGRect(x: 700, y: 400, width: 400, height: 300)
        let pts = stable(5.0, r, count: 6)
        let scroll = [InputEvent(t: 5.05, kind: .scroll, x: 900, y: 500, scrollDelta: 3),
                      InputEvent(t: 5.25, kind: .scroll, x: 900, y: 500, scrollDelta: -2)]
        let d = analyze(pts, events: scroll)
        #expect(d.beats.isEmpty)
        #expect(d.rejections.contains(.scroll), "got \(d.rejections)")
    }

    @Test func animationLoopIsRejectedEvenWhenEachPulseLooksStable() {
        var pts: [ActivityPoint] = []
        let r = CGRect(x: 800, y: 400, width: 220, height: 140)
        for pulse in 0..<4 {
            let t0 = 3.0 + Double(pulse) * 0.8
            for k in 0..<3 {
                let x = r.midX + (k == 1 ? 12 : 0)   // tiny back-and-forth jitter
                pts.append(ActivityPoint(t: t0 + Double(k) * 0.15, x: x, y: r.midY,
                                         region: r, coverage: 0.02))
            }
        }
        let d = analyze(pts)
        #expect(d.beats.isEmpty, "a pulse loop is not a product result: \(d.beats)")
        #expect(d.rejections.contains(.animationLoop), "got \(d.rejections)")
    }

    @Test func fullScreenFlashNeverTriggersAndDoesNotPoisonTheNextResult() {
        let flash = stable(2.0, CGRect(x: 0, y: 0, width: W, height: H),
                           count: 3, coverage: 0.9)
        let result = stable(6.0, CGRect(x: 1300, y: 700, width: 220, height: 180))
        let d = analyze(flash + result)
        #expect(d.rejections.contains(.fullScreen), "got \(d.rejections)")
        #expect(d.beats.count == 1, "the flash must break, not disable the detector")
        #expect(d.beats.first?.intent.t ?? 0 > 5.0)
    }

    @Test func caretBlinkIsRejected() {
        var pts: [ActivityPoint] = []
        for i in 0..<8 {
            let x = (i % 2 == 0) ? 800.0 : 802.0
            pts.append(ActivityPoint(t: 4.0 + Double(i) * 0.1, x: x, y: 300,
                                     region: CGRect(x: x - 4, y: 290, width: 8, height: 20),
                                     coverage: 0.006))
        }
        let d = analyze(pts)
        #expect(d.beats.isEmpty)
        #expect(d.rejections.contains(.tiny) || d.rejections.contains(.flicker),
                "got \(d.rejections)")
    }

    // MARK: Determinism

    @Test func analysisIsDeterministicAndInsensitiveToInputOrder() {
        let r = CGRect(x: 1200, y: 600, width: 300, height: 220)
        let pts = stable(5.0, r, count: 6)
        let input = [ZoomPlanner.Intent(kind: .click, t: 1.0, tEnd: 1.0, x: 400, y: 300)]
        let a = analyze(pts, input: input)
        let b = analyze(pts.reversed(), input: input)
        #expect(a.beats == b.beats, "same evidence must produce the same beat")
        #expect(a.rejections == b.rejections)
        func fingerprint(_ xs: [ZoomPlanner.Intent]) -> [IntentFingerprint] {
            xs.map { IntentFingerprint(t: $0.t, tEnd: $0.tEnd, x: $0.x, y: $0.y,
                                       w: Double($0.rect?.width ?? -1)) }
        }
        #expect(fingerprint(VisualAutofocus.intents(pts, events: [], input: input, src: source(), tm: tm()))
                == fingerprint(VisualAutofocus.intents(pts.reversed(), events: [], input: input, src: source(), tm: tm())))
    }
}
