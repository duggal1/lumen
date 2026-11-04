import XCTest
import LumenCore
import LumenProject
@testable import LumenDirector

final class Part23Tests: XCTestCase {
    private let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 12, backingScale: 2, originX: 0, originY: 0)

    func testSensitivePatternsClassifyApiKeysAndEmail() {
        let apiKey = "sk-ant-api03-" + String(repeating: "A", count: 36)
        let hits = SensitivePatterns.scan("token \(apiKey) me@example.com")

        XCTAssertEqual(hits.map(\.category), [.apiKey, .email])
        XCTAssertEqual(hits.count, 2)
    }

    func testMaskTracksAreStableApprovedAndRespectRejection() {
        let plan = PrivacyPlan()
        let detections = [
            OCRDetection(t: 1, x: 0.2, y: 0.3, w: 0.2, h: 0.04, category: .apiKey, hash: 42, confidence: 0.99),
            OCRDetection(t: 1.5, x: 0.21, y: 0.3, w: 0.2, h: 0.04, category: .apiKey, hash: 42, confidence: 0.99),
        ]
        let first = MaskTracks.build(detections, plan: plan, src: source)
        let second = MaskTracks.build(detections, plan: plan, src: source)

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.id, second.first?.id)
        XCTAssertEqual(first.first?.origin, .auto)
        XCTAssertEqual(first.first?.approved, true)
        XCTAssertEqual(first.first?.keys.count, 2)

        var rejected = plan
        rejected.decisions[first[0].id.uuidString] = false
        XCTAssertTrue(MaskTracks.build(detections, plan: rejected, src: source).isEmpty)
    }

    func testCaptionPlannerKeepsSourceWordsOnOutputTimeline() {
        var timeline = Timeline(duration: 10)
        timeline.captions.enabled = true
        let words = [WordToken(text: "Hello", start: 1, end: 1.3), WordToken(text: "world.", start: 1.35, end: 1.8)]

        let chunks = CaptionPlanner.plan(words: words, tm: timeline.timeMap, p: timeline.captions, aspect: 16.0 / 9,
                                         kindAt: { _ in .screenOnly }, cornerAt: { _ in nil })

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, "Hello world.")
        XCTAssertLessThanOrEqual(chunks[0].start, 1)
        XCTAssertGreaterThanOrEqual(chunks[0].end, 1.8)
    }

    func testFillerCutsUseSourceWordTiming() {
        let transcript = Transcript(words: [
            WordToken(text: "We", start: 0.2, end: 0.4),
            WordToken(text: "um", start: 0.45, end: 0.7),
            WordToken(text: "ship", start: 0.75, end: 1.1),
        ], locale: "en-US")

        let cuts = TranscriptOps.fillerCuts(transcript)

        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].origin, .transcript)
        XCTAssertLessThanOrEqual(cuts[0].start, 0.45)
        XCTAssertGreaterThanOrEqual(cuts[0].end, 0.7)
    }

    func testLayoutContentRespectsAsymmetricInsets() {
        let rect = LayoutResolver.contentRect(aspect: 16.0 / 9, srcAspect: 16.0 / 10,
                                             insets: EdgeInsetsN(top: 0.08, right: 0.12, bottom: 0.06, left: 0.1))

        XCTAssertGreaterThanOrEqual(rect.x, 0.1)
        XCTAssertGreaterThanOrEqual(rect.y, 0.08 * 16.0 / 9)
        XCTAssertLessThanOrEqual(rect.x + rect.z, 0.88)
        XCTAssertLessThanOrEqual(rect.y + rect.w, 1 - 0.06 * 16.0 / 9)
    }
}
