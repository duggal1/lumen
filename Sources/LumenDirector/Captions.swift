import Foundation
import LumenCore
import LumenProject

enum CaptionPlanner {
    private struct TimedWord { var text: String; var start: Double; var end: Double }

    static func perLine(_ plan: CaptionPlan, aspect: Double) -> Int {
        if let count = plan.maxCharsPerLine { return max(count, 8) }
        let u = clamp((aspect - 9.0 / 16) / (16.0 / 9 - 9.0 / 16), 0, 1)
        return Int((24 + 18 * u).rounded())
    }

    static func plan(words: [WordToken], tm: TimeMap, p: CaptionPlan, aspect: Double,
                     kindAt: (Double) -> LayoutKind, cornerAt: (Double) -> WebcamLayout.Corner?) -> [CaptionChunk] {
        guard p.enabled else { return [] }
        let timed = mappedWords(words, timeMap: tm, plan: p)
        let groups = chunkWords(timed, perLine: perLine(p, aspect: aspect), maxLines: p.maxLines)
        return makeChunks(groups, perLine: perLine(p, aspect: aspect), plan: p, aspect: aspect,
                          kindAt: kindAt, cornerAt: cornerAt)
    }

    private static func mappedWords(_ words: [WordToken], timeMap tm: TimeMap, plan: CaptionPlan) -> [TimedWord] {
        let deleted = Set(plan.deletedWords)
        return words.enumerated().compactMap { index, word in
            guard !deleted.contains(index), word.end > word.start,
                  word.start >= tm.trimStart, word.end <= tm.trimEnd,
                  !tm.cuts.contains(where: { $0.start < word.end && $0.end > word.start }) else { return nil }
            let text = (plan.textEdits[String(index)] ?? word.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = tm.output(atSource: word.start), end = tm.output(atSource: word.end)
            guard end > start else { return nil }
            return TimedWord(text: text, start: start, end: end)
        }
    }

    private static func chunkWords(_ words: [TimedWord], perLine: Int, maxLines: Int) -> [[TimedWord]] {
        let capacity = perLine * max(maxLines, 1)
        var groups: [[TimedWord]] = [], current: [TimedWord] = []
        for word in words {
            if let first = current.first, let previous = current.last {
                let count = characterCount(current)
                let overflow = count + word.text.count + 1 > capacity
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

    private static func makeChunks(_ groups: [[TimedWord]], perLine: Int, plan: CaptionPlan, aspect: Double,
                                   kindAt: (Double) -> LayoutKind, cornerAt: (Double) -> WebcamLayout.Corner?) -> [CaptionChunk] {
        var out: [CaptionChunk] = []
        for (index, group) in groups.enumerated() where !group.isEmpty {
            let nextStart = index + 1 < groups.count ? groups[index + 1][0].start : Double.infinity
            let start = max(group[0].start - 0.05, out.last?.end ?? 0)
            let desiredEnd = min(group[group.count - 1].end + 0.2, nextStart - 0.02)
            let end = max(group[group.count - 1].end, min(desiredEnd, start + 4.0))
            guard end > start else { continue }
            let lines = wrap(group, perLine: perLine)
            let position = yPosition(plan.style.position, aspect: aspect, kind: kindAt(start), corner: cornerAt(start))
            out.append(CaptionChunk(start: start, end: end, lines: lines, y: position))
        }
        return out
    }

    private static func wrap(_ words: [TimedWord], perLine: Int) -> [[CaptionWord]] {
        var lines: [[CaptionWord]] = [[]], count = 0
        for word in words {
            let addition = word.text.count + (lines[lines.count - 1].isEmpty ? 0 : 1)
            if count + addition > perLine, !lines[lines.count - 1].isEmpty { lines.append([]); count = 0 }
            lines[lines.count - 1].append(CaptionWord(text: word.text, start: word.start, end: word.end))
            count += word.text.count + (lines[lines.count - 1].count == 1 ? 0 : 1)
        }
        return lines
    }

    private static func characterCount(_ words: [TimedWord]) -> Int {
        words.reduce(0) { $0 + $1.text.count } + max(words.count - 1, 0)
    }

    private static func yPosition(_ preference: CaptionPosition, aspect: Double, kind: LayoutKind,
                                  corner: WebcamLayout.Corner?) -> Double {
        if preference == .top { return 0.12 }
        if preference == .bottom { return aspect < 1 ? 0.79 : 0.88 }
        if aspect < 1 { return 0.79 }
        if kind == .cameraOverlay, corner == .bottomLeft || corner == .bottomRight { return 0.16 }
        return 0.88
    }
}
