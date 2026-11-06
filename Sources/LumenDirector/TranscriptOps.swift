import Foundation
import LumenCore
import LumenProject

/// One sentence of transcript, addressed by sorted word index and SOURCE seconds.
struct WordSentence: Sendable, Equatable {
    var index: Int
    var wordRange: Range<Int>
    var start: Double, end: Double
    var text: String
}

enum TranscriptOps {
    private static let fillers: [String: Set<String>] = [
        "en": ["um", "uh", "er", "erm", "hmm"],
        "es": ["eh", "em", "mmm"],
        "fr": ["euh", "hein"],
        "de": ["äh", "ähm", "hm"],
    ]

    static func fillerCuts(_ transcript: Transcript, ambiguous: Set<String> = []) -> [CutRange] {
        let locale = String(transcript.locale.prefix(2)).lowercased()
        let terms = (fillers[locale] ?? fillers["en"] ?? []).union(ambiguous.map { $0.lowercased() })
        let proposed = transcript.words.compactMap { word -> CutRange? in
            guard word.confidence >= 0.4, word.end > word.start else { return nil }
            let normalized = word.text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            guard terms.contains(normalized) else { return nil }
            return CutRange(start: max(word.start - 0.04, 0), end: word.end + 0.04, origin: .transcript)
        }
        return merge(proposed)
    }

    static func pauseCuts(_ transcript: Transcript, events: [InputEvent], maxPause: Double = 0.6,
                          keepPause: Double = 0.25) -> [CutRange] {
        guard maxPause >= 0, keepPause >= 0 else { return [] }
        let words = transcript.words.sorted { $0.start < $1.start }
        guard words.count > 1 else { return [] }
        var cuts: [CutRange] = []
        for pair in zip(words, words.dropFirst()) {
            let start = pair.0.end, end = pair.1.start, gap = end - start
            guard gap > maxPause, gap < 2, end > start,
                  !events.contains(where: { $0.t > start && $0.t < end }) else { continue }
            let removed = gap - min(keepPause, gap)
            guard removed > 0 else { continue }
            let edge = removed / 2
            cuts.append(CutRange(start: start + edge, end: end - edge, origin: .transcript))
        }
        return merge(cuts)
    }

    /// Sentence segmentation over the sorted word stream. A sentence ends on
    /// terminal punctuation (`.`, `!`, `?`) or at the last word. This is the
    /// unit the transcript editor deletes: delete a sentence, get one cut.
    static func sentences(_ transcript: Transcript) -> [WordSentence] {
        let words = transcript.words.sorted { $0.start < $1.start }
        guard !words.isEmpty else { return [] }
        var out: [WordSentence] = []
        var from = 0
        func isEnd(_ w: WordToken) -> Bool {
            let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?")
        }
        for i in words.indices {
            let last = i == words.index(before: words.endIndex)
            if isEnd(words[i]) || last {
                let slice = Array(words[from...i])
                out.append(WordSentence(index: out.count, wordRange: from..<(i + 1),
                                        start: slice.first!.start, end: slice.last!.end,
                                        text: slice.map(\.text).joined(separator: " ")))
                from = i + 1
            }
        }
        return out
    }

    /// Cut covering the whole sentence at `index` (SOURCE seconds, transcript
    /// origin). Nil when the index does not exist.
    static func sentenceCut(_ transcript: Transcript, index: Int, padding: Double = 0.04) -> CutRange? {
        let list = sentences(transcript)
        guard index >= 0, index < list.count else { return nil }
        let s = list[index]
        return CutRange(start: max(s.start - padding, 0), end: s.end + padding, origin: .transcript)
    }

    static func suggestions(_ transcript: Transcript, events: [InputEvent], ambiguous: Set<String> = [],
                            maxPause: Double = 0.6, keepPause: Double = 0.25) -> [CutRange] {
        merge(fillerCuts(transcript, ambiguous: ambiguous) + pauseCuts(transcript, events: events,
                                                                        maxPause: maxPause, keepPause: keepPause))
    }

    private static func merge(_ ranges: [CutRange]) -> [CutRange] {
        let sorted = ranges.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var out: [CutRange] = []
        for next in sorted.dropFirst() {
            if next.start <= current.end {
                current.end = max(current.end, next.end)
            } else {
                out.append(current)
                current = next
            }
        }
        out.append(current)
        return out
    }
}
