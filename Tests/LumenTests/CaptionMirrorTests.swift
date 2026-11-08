import Testing
@testable import LumenProject
import LumenCore
@testable import LumenDirector

@Test func captionsNotMirroredAtAnyAspect() throws {
    let words = [WordToken(text: "hello", start: 1, end: 1.2), WordToken(text: "world", start: 1.25, end: 1.5)]
    for aspect in [16.0/9, 1.0, 9.0/16] {
        let tm = TimeMap(sourceDuration: 5, trimStart: 0, trimEnd: 5, ramps: [], cuts: [])
        let day = { (_: Double) -> LayoutKind in .screenOnly }
        let chunks = CaptionPlanner.plan(words: words, tm: tm, p: CaptionPlan(), aspect: aspect, kindAt: day, cornerAt: { _ in nil })
        let text = chunks.flatMap { $0.lines }.flatMap { $0 }.map { $0.text }.joined(separator: " ")
        #expect(text == "hello world", "aspect \(aspect): \(text)")
    }
}
