import Foundation
import LumenCore
import LumenProject

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
