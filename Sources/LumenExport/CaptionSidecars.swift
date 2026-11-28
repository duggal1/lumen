import Foundation
import LumenProject

public enum CaptionSidecarFormat: String, CaseIterable, Sendable {
    case srt, vtt

    fileprivate var decimalSeparator: String { self == .srt ? "," : "." }
}

public enum CaptionSidecarError: LocalizedError {
    case disabled, missingDerivedTrack, invalidDuration, emptyTrack, invalidDestination, destinationExists
    public var errorDescription: String? {
        switch self {
        case .disabled: "Captions are disabled for this project."
        case .missingDerivedTrack: "Derive the committed timeline before exporting captions."
        case .invalidDuration: "Invalid edited video duration."
        case .emptyTrack: "No valid caption cues are available."
        case .invalidDestination: "Choose a matching subtitle extension and a regular destination file."
        case .destinationExists: "A subtitle file already exists. Choose another name or explicitly allow replacement."
        }
    }
}

/// Plain timed-text delivery from the exact output caption chunks used by
/// the shared renderer. No independent source-time mapping or re-transcription.
public enum CaptionSidecars {
    public struct Delivery: Sendable, Equatable {
        public let text: String
        public let cueCount: Int
    }

    private struct Cue {
        let start: Int64, end: Int64
        let lines: [String]
    }

    public static func serialize(timeline: Timeline, format: CaptionSidecarFormat) throws -> Delivery {
        guard timeline.captions.enabled else { throw CaptionSidecarError.disabled }
        guard let derived = timeline.derived else { throw CaptionSidecarError.missingDerivedTrack }
        return try serialize(chunks: derived.captions, duration: timeline.compositionDuration, format: format)
    }

    public static func serialize(chunks: [CaptionChunk], duration: Double, format: CaptionSidecarFormat) throws -> Delivery {
        let milliseconds = duration * 1000
        guard milliseconds.isFinite, milliseconds >= 1, milliseconds < Double(Int64.max) else {
            throw CaptionSidecarError.invalidDuration
        }
        let limit = Int64(milliseconds.rounded(.down))
        let sorted = chunks.enumerated().filter {
            $0.element.start.isFinite && $0.element.end.isFinite && $0.element.end > $0.element.start
        }.sorted {
            if $0.element.start == $1.element.start { return $0.offset < $1.offset }
            return $0.element.start < $1.element.start
        }

        func ms(_ seconds: Double) -> Int64 {
            let clamped = min(max(seconds, 0), duration)
            return min(limit, Int64((clamped * 1000).rounded()))
        }
        var cues: [Cue] = []
        var priorEnd: Int64 = 0
        for entry in sorted {
            let chunk = entry.element
            let lines = chunk.lines.compactMap { line -> String? in
                // User-edited words may contain control/line breaks. Keep
                // authored Unicode, never allow a blank line or timestamp to
                // inject a new cue, and escape markup-sensitive characters.
                let content = line.map(\.text).joined(separator: " ")
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
                let plain = String(String.UnicodeScalarView(content))
                guard !plain.isEmpty else { return nil }
                return plain.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
            guard !lines.isEmpty else { continue }
            // Corrected output chunks are normally non-overlapping. Quantize
            // the boundary once; malformed overlap cannot create two active
            // text blocks or a duplicate zero-length cue.
            let start = max(priorEnd, ms(chunk.start)), end = ms(chunk.end)
            guard end > start else { continue }
            cues.append(Cue(start: start, end: end, lines: lines))
            priorEnd = end
        }
        guard !cues.isEmpty else { throw CaptionSidecarError.emptyTrack }
        let body = cues.enumerated().map { index, cue -> String in
            let header = format == .srt ? "\(index + 1)\n" : ""
            return header + timestamp(cue.start, format: format) + " --> " +
                timestamp(cue.end, format: format) + "\n" + cue.lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return Delivery(text: (format == .vtt ? "WEBVTT\n\n" : "") + body + "\n", cueCount: cues.count)
    }

    private static func timestamp(_ ms: Int64, format: CaptionSidecarFormat) -> String {
        let hours = ms / 3_600_000, minutes = (ms / 60_000) % 60, seconds = (ms / 1000) % 60
        return String(format: "%02lld:%02lld:%02lld%@%03lld", hours, minutes, seconds,
                      format.decimalSeparator, ms % 1000)
    }

    /// Stage in the destination directory; failed writes or cancellation
    /// never delete an existing subtitle. Replacement requires explicit intent.
    public static func write(_ delivery: Delivery, format: CaptionSidecarFormat, to url: URL,
                             overwrite: Bool = false) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == format.rawValue else {
            throw CaptionSidecarError.invalidDestination
        }
        try Task.checkCancellation()
        let files = FileManager.default
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(".lumen-caption-\(UUID().uuidString).\(format.rawValue)")
        defer { try? files.removeItem(at: staged) }
        try Data(delivery.text.utf8).write(to: staged, options: .withoutOverwriting)
        try Task.checkCancellation()
        if files.fileExists(atPath: url.path) {
            guard overwrite else { throw CaptionSidecarError.destinationExists }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CaptionSidecarError.invalidDestination
            }
            _ = try files.replaceItemAt(url, withItemAt: staged)
        } else {
            try files.moveItem(at: staged, to: url)
        }
    }
}
