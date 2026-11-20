import Foundation
import LumenCore
import LumenProject

enum CaptionPlanner {
    private struct TimedWord { var text: String; var start: Double; var end: Double }

    /// A caption never uses more than 60 % of the picture width and never more
    /// than two lines. The character budget follows from the type size: a line
    /// is 60 % of the width and a glyph is roughly half the type size.
    static func perLine(_ plan: CaptionPlan, aspect: Double) -> Int {
        let size = max(plan.style.size, 0.02)
        let chars = (0.60 * aspect) / (0.5 * size)
        return max(8, min(42, Int(chars.rounded())))
    }

    static func plan(words: [WordToken], tm: TimeMap, p: CaptionPlan, aspect: Double,
                     kindAt: (Double) -> LayoutKind, cornerAt: (Double) -> WebcamLayout.Corner?) -> [CaptionChunk] {
        guard p.enabled else { return [] }
        let timed = mappedWords(words, timeMap: tm, plan: p)
        let width = perLine(p, aspect: aspect)
        let groups = chunkWords(timed, perLine: width)
        return makeChunks(groups, perLine: width, duration: tm.outputDuration, aspect: aspect,
                          kindAt: kindAt, cornerAt: cornerAt)
    }

    private static func mappedWords(_ words: [WordToken], timeMap tm: TimeMap, plan: CaptionPlan) -> [TimedWord] {
        let vocab = Dictionary(plan.vocabulary.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let deleted = Set(plan.deletedWords)
        var out: [TimedWord] = []
        var sentenceStart = true
        for (index, word) in words.enumerated() {
            guard !deleted.contains(index), word.end > word.start,
                  word.start >= tm.trimStart, word.end <= tm.trimEnd,
                  !tm.cuts.contains(where: { $0.start < word.end && $0.end > word.start }) else { continue }
            let edited = plan.textEdits[String(index)]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = edited ?? word.text
            guard !text.isEmpty else { continue }
            let start = tm.output(atSource: word.start), end = tm.output(atSource: word.end)
            guard end > start else { continue }
            // A manual edit is the user's own words: never re-case it.
            out.append(TimedWord(text: edited ?? vocab[word.text.lowercased()] ?? sentenceCase(text, atSentenceStart: sentenceStart),
                                 start: start, end: end))
            if let last = text.last, ".?!".contains(last) { sentenceStart = true } else { sentenceStart = false }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Sentence case, and nothing else: the first word of a sentence starts
    /// with a capital, existing name casing is preserved, and "I" is always "I".
    /// A word with an inner capital ("iPhone") keeps it.
    static func sentenceCase(_ word: String, atSentenceStart: Bool) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return word }
        if trimmed.lowercased() == "i" { return "I" }
        guard atSentenceStart else { return trimmed }
        return String(trimmed.prefix(1).uppercased()) + String(trimmed.dropFirst())
    }

    private static func chunkWords(_ words: [TimedWord], perLine: Int) -> [[TimedWord]] {
        let capacity = perLine * 2
        var groups: [[TimedWord]] = [], current: [TimedWord] = []
        for word in words {
            if let first = current.first, let previous = current.last {
                let count = characterCount(current)
                let overflow = wrap(current + [word], perLine: perLine).count > 2
                let long = word.end - first.start > 4
                let pause = word.start - previous.end > 0.3 && count >= capacity * 2 / 5
                if overflow || long || pause { groups.append(current); current = [] }
            }
            current.append(word)
            if let last = word.text.last, ".?!…".contains(last) { groups.append(current); current = [] }
            else if let last = word.text.last, ",;:".contains(last), characterCount(current) >= capacity * 3 / 5 {
                groups.append(current); current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private static func makeChunks(_ groups: [[TimedWord]], perLine: Int, duration: Double, aspect: Double,
                                   kindAt: (Double) -> LayoutKind, cornerAt: (Double) -> WebcamLayout.Corner?) -> [CaptionChunk] {
        var out: [CaptionChunk] = []
        for (index, group) in groups.enumerated() where !group.isEmpty {
            let nextStart = index + 1 < groups.count ? groups[index + 1][0].start : duration
            let start = max(group[0].start - 0.05, out.last?.end ?? 0)
            let speechEnd = group.map(\.end).max() ?? start
            let end = min(speechEnd + 0.2, nextStart, duration, start + 4)
            guard end > start else { continue }
            let lines = wrap(group, perLine: perLine)
            let position = yPosition(aspect: aspect, kind: kindAt(start), corner: cornerAt(start))
            out.append(CaptionChunk(start: start, end: end, lines: lines, y: position))
        }
        return out
    }

    private static func wrap(_ words: [TimedWord], perLine: Int) -> [[CaptionWord]] {
        var lines: [[CaptionWord]] = [[]]
        for word in words {
            var current = lines[lines.count - 1]
            let addition = word.text.count + (current.isEmpty ? 0 : 1)
            if width(current) + addition > perLine, !current.isEmpty {
                let candidate = phraseBoundary(current)
                let cut = width(Array(current.suffix(from: candidate))) + addition <= perLine ? candidate : current.count
                lines[lines.count - 1] = Array(current.prefix(cut))
                current = Array(current.suffix(from: cut))
                lines.append(current)
            }
            current.append(CaptionWord(text: word.text, start: word.start, end: word.end))
            lines[lines.count - 1] = current
        }
        return lines
    }

    private static func width(_ line: [CaptionWord]) -> Int {
        line.reduce(0) { $0 + $1.text.count } + max(line.count - 1, 0)
    }

    /// Break before the last clause boundary that still fills the line, so a
    /// caption never splits a phrase when a softer break exists.
    private static func phraseBoundary(_ line: [CaptionWord]) -> Int {
        var best: Int?
        for (i, word) in line.enumerated() {
            guard i > 0 else { continue }
            let last = word.text.last.map { String($0) } ?? ""
            let joiners = ["and", "but", "or", "so", "because", "that", "which", "when", "if"]
            if ",;:—–".contains(last) || joiners.contains(word.text.lowercased()) { best = i }
        }
        guard let cut = best else { return max(line.count - 1, 1) }
        let head = line.prefix(cut).reduce(0) { $0 + $1.text.count }
        return head * 2 >= width(line) ? cut : max(line.count - 1, 1)
    }

    private static func characterCount(_ words: [TimedWord]) -> Int {
        words.reduce(0) { $0 + $1.text.count } + max(words.count - 1, 0)
    }

    /// The caption sits low enough to read as a lower third but never on the
    /// dock: roughly 10 % of the frame stays clear under it.
    private static func yPosition(aspect: Double, kind: LayoutKind, corner: WebcamLayout.Corner?) -> Double {
        if (kind == .cameraOverlay || kind == .cameraCutout), corner == .bottomLeft || corner == .bottomRight { return 0.16 }
        if kind == .split, aspect < 1 { return 0.46 }
        if aspect < 1 { return 0.84 }
        return 0.90
    }
}
