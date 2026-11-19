import Foundation
import LumenCore

/// Pure transcript-edit math shared by the editor and its tests.
///
/// A transcript edit is not a caption-only cosmetic change: removing a word,
/// sentence, filler or long pause must remove the matching PICTURE. Everything
/// here produces the same `CutRange` the timeline already understands, in
/// SOURCE seconds, so the existing TimeMap, anchored-content trim and caption
/// mapping all apply without a second timeline concept.
public enum TranscriptEdits {
    public static let defaultPadding = 0.04

    /// Locale-keyed filler vocabulary. English is the fallback for every
    /// locale we do not have a dedicated list for.
    public static let fillerTerms: [String: Set<String>] = [
        "en": ["um", "uh", "er", "erm", "hmm", "like", "basically", "actually",
               "you know", "i mean", "sort of", "kind of"],
        "es": ["eh", "em", "mmm"],
        "fr": ["euh", "hein"],
        "de": ["äh", "ähm", "hm"],
    ]

    public static func terms(forLocale locale: String) -> Set<String> {
        fillerTerms[String(locale.prefix(2)).lowercased()] ?? fillerTerms["en"]!
    }

    /// Lowercased and stripped of surrounding punctuation/whitespace, so
    /// `"Um,"`, `"UM"` and `" um "` all normalize to the same filler.
    public static func normalized(_ text: String) -> String {
        // Canonical composition first, so "u" + combining diaeresis and "ü"
        // are one term in every locale. Internal hyphens/dashes are word
        // separators in ASR ("you-know" == "you know"), not punctuation to
        // keep; outer punctuation is stripped after that.
        let composed = text.precomposedStringWithCanonicalMapping.lowercased()
        let separated = composed.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "\u{2013}", with: " ")
            .replacingOccurrences(of: "\u{2014}", with: " ")
        let trimmed = separated.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        return trimmed.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Word indices the UI masks as fillers. This is the single definition
    /// shared with `cleanupCuts`, so the caption mask and the picture cut can
    /// never disagree. Confidence is not a factor: a low-confidence "um" is
    /// still a filler the viewer does not want to read or watch.
    public static func fillerIndices(in transcript: Transcript) -> [Int] {
        let terms = terms(forLocale: transcript.locale)
        return transcript.words.indices.filter { terms.contains(normalized(transcript.words[$0].text)) }
    }

    /// The cut that removes one word, padded on both sides by `padding`.
    /// Nil for a zero/negative-length word or a non-finite time.
    public static func span(for word: WordToken, padding: Double = defaultPadding) -> CutRange? {
        guard word.start.isFinite, word.end.isFinite, word.end > word.start else { return nil }
        let p = max(padding, 0)
        let a = max(word.start - p, 0)
        let b = word.end + p
        guard b > a else { return nil }
        return CutRange(start: a, end: b, origin: .transcript)
    }

    /// Cuts for a set of word indices. Unknown indices are ignored, duplicates
    /// collapse, and overlapping words merge into a single cut.
    public static func spans(for words: [WordToken], at indices: [Int],
                             padding: Double = defaultPadding) -> [CutRange] {
        let unique = Set(indices).sorted()
        return merge(unique.compactMap { i in
            words.indices.contains(i) ? span(for: words[i], padding: padding) : nil
        })
    }

    /// The cut covering a whole sentence (a half-open range of word indices).
    public static func sentenceSpan(for words: [WordToken], range: Range<Int>,
                                    padding: Double = defaultPadding) -> CutRange? {
        guard range.lowerBound >= 0, range.upperBound <= words.count, !range.isEmpty else { return nil }
        let slice = words[range]
        // Overlapping windows can re-emit a word with a SHORTER end or place
        // bursts out of order. first/last would then shrink the cut and leave
        // part of the sentence in the picture; use the full extent instead.
        let starts = slice.map(\.start), ends = slice.map(\.end)
        guard let lo = starts.min(), let hi = ends.max(),
              starts.allSatisfy(\.isFinite), ends.allSatisfy(\.isFinite) else { return nil }
        let a = max(lo - max(padding, 0), 0)
        let b = hi + max(padding, 0)
        guard b > a else { return nil }
        return CutRange(start: a, end: b, origin: .transcript)
    }

    /// One-pass cleanup: every recognized filler plus every long pause with no
    /// input activity inside it. Both become `.transcript` cuts. `keepPause`
    /// leaves a natural breath so speech does not sound machine-edited.
    public static func cleanupCuts(transcript: Transcript, events: [InputEvent] = [],
                                   maxPause: Double = 0.6, keepPause: Double = 0.25,
                                   padding: Double = defaultPadding) -> [CutRange] {
        var cuts: [CutRange] = []
        for i in fillerIndices(in: transcript) {
            if let cut = span(for: transcript.words[i], padding: padding) { cuts.append(cut) }
        }
        guard maxPause >= 0, keepPause >= 0 else { return merge(cuts) }
        let ordered = transcript.words.sorted { $0.start < $1.start }
        for pair in zip(ordered, ordered.dropFirst()) {
            let start = pair.0.end, end = pair.1.start, gap = end - start
            guard start.isFinite, end.isFinite, gap > maxPause, gap < 2 else { continue }
            // A click/key inside the gap means the speaker was doing something:
            // never silently delete that part of the recording.
            guard !events.contains(where: { $0.t > start && $0.t < end }) else { continue }
            let kept = min(keepPause, gap)
            let removed = gap - kept
            guard removed > 0 else { continue }
            // Keep `kept` seconds centered in the gap, remove the rest. Using
            // kept/2 (not removed/2) is what actually removes `removed` seconds.
            let edge = kept / 2
            cuts.append(CutRange(start: start + edge, end: end - edge, origin: .transcript))
        }
        return merge(cuts)
    }

    /// Merge overlapping/adjacent cuts. Identity comes from the first cut;
    /// `.transcript` wins the origin so restored words can always find their cut.
    public static func merge(_ cuts: [CutRange]) -> [CutRange] {
        let sorted = cuts.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return [] }
        var out: [CutRange] = []
        for next in sorted.dropFirst() {
            if next.start <= current.end + 0.0005 {
                let origin: CutOrigin = (current.origin == .transcript || next.origin == .transcript)
                    ? .transcript : current.origin
                current = CutRange(id: current.id, start: current.start,
                                   end: max(current.end, next.end), origin: origin)
            } else {
                out.append(current)
                current = next
            }
        }
        out.append(current)
        return out
    }

    /// Subtract `spans` from every cut, splitting a cut into survivors around
    /// each removed span. Used when a deleted word is restored: only the word's
    /// own time comes back, not every word that shared the merged cut.
    public static func subtract(_ spans: [CutRange], from cuts: [CutRange],
                                epsilon: Double = 0.0005) -> [CutRange] {
        var result: [CutRange] = []
        for cut in cuts where cut.end > cut.start {
            var pieces = [(cut.start, cut.end)]
            for span in spans where span.end > span.start {
                var next: [(Double, Double)] = []
                for (a, b) in pieces {
                    if span.end <= a + epsilon || span.start >= b - epsilon {
                        next.append((a, b)); continue
                    }
                    if span.start > a + epsilon { next.append((a, min(span.start, b))) }
                    if span.end < b - epsilon { next.append((max(span.end, a), b)) }
                }
                pieces = next
            }
            for (a, b) in pieces where b - a > epsilon {
                result.append(CutRange(id: UUID(), start: a, end: b, origin: cut.origin))
            }
        }
        return result
    }
}
