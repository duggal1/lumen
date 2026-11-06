import Foundation

/// transcript.json. Word times are MIC-FILE time; add `micOffset` (meta.mic.startHostSeconds - clock origin) to get source time.
public struct TranscriptFile: Codable, Sendable {
    public var version = 1
    public var engine: String
    public var complete: Bool
    public var transcript: Transcript
    public init(engine: String, complete: Bool, transcript: Transcript) { self.engine = engine; self.complete = complete; self.transcript = transcript }
}

extension ProjectBundle {
    public var transcriptURL: URL { url.appendingPathComponent("transcript.json") }
    public func saveTranscript(_ f: TranscriptFile) throws {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        try e.encode(f).write(to: transcriptURL, options: .atomic)
    }
    public func loadTranscript() -> TranscriptFile? {
        guard let d = try? Data(contentsOf: transcriptURL) else { return nil }
        return try? JSONDecoder().decode(TranscriptFile.self, from: d)
    }
}

extension Transcript {
    public func shifted(by dt: Double) -> Transcript {
        Transcript(words: words.map { WordToken(text: $0.text, start: $0.start + dt, end: $0.end + dt, confidence: $0.confidence) }, locale: locale)
    }
}
