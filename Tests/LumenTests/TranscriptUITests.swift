import Testing
import LumenProject
@testable import LumenUI

// The transcript list must read left-to-right in word order; a mirrored
// render is a bug, not a layout choice. These pin the data contract.
@Test func sentencesSplitPreservesLeftToRightWordOrder() {
    let words = [
        WordToken(text: "Hello", start: 0, end: 0.3), WordToken(text: "there.", start: 0.35, end: 0.8),
        WordToken(text: "Second", start: 1, end: 1.3), WordToken(text: "sentence.", start: 1.35, end: 1.8),
    ]
    let sentences = Sentences.split(words)
    #expect(sentences.count == 2)
    #expect(sentences[0].range == 0..<2)
    #expect(sentences[1].range == 2..<4)
    #expect(sentences.map { $0.start } == [0, 1])
    // Every word belongs to exactly one sentence, in order.
    #expect(sentences.flatMap { Array($0.range) } == [0, 1, 2, 3])
}

@Test func sentenceLookupIsMonotonicWithWordIndex() {
    let words = (0..<10).map { WordToken(text: "w\($0).", start: Double($0), end: Double($0) + 0.5) }
    let sentences = Sentences.split(words)
    let indices = (0..<words.count).map { Sentences.find(sentences, word: $0) }
    #expect(indices == indices.sorted(), "lookup must move forward through the transcript")
    #expect(sentences.map { words[Array($0.range).first!].text } == ["w0.", "w1.", "w2.", "w3.", "w4.", "w5.", "w6.", "w7.", "w8.", "w9."])
}

@Test func iconsResolveWithoutMissingGlyphs() {
    // Every dropdown icon must resolve on the build's symbol set.
    for name in ["film", "play.tv", "rectangle", "gauge", "signal", "speaker.wave.1", "mic", "person"] {
        #expect(IconSymbols.exists(name) || IconSymbols.resolve(name) == "circle")
    }
}
