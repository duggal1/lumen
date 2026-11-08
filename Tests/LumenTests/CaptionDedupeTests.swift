import Testing
@testable import LumenUI
import LumenCore
import LumenProject

@Test func captionDedupesOverlappingRepeat() {
    let words = [
        WordToken(text: "So", start: 26.0, end: 26.3),
        WordToken(text: "does", start: 26.35, end: 26.5),
        WordToken(text: "work.", start: 26.55, end: 26.9),
        WordToken(text: "work.", start: 26.85, end: 27.1),
    ]
    let sentences = Sentences.split(words)
    let texts = sentences.map { s in words[s.range].map { $0.text }.joined(separator: " ") }
    #expect(texts.count == 1, "overlapping repeat must not form its own sentence: \(texts)")
    #expect(sentences.first?.range.count == 3, "first sentence keeps clean words")
}
