import Foundation
import LumenProject
import LumenSpeech

public protocol TranscriptionEngine: Sendable {
    func transcribe(audio: URL, locale: Locale, vocabulary: [String]) async throws -> Transcript
}

public struct MoonshineSpeechEngine: TranscriptionEngine {
    public init() {}

    public func transcribe(audio: URL, locale: Locale, vocabulary: [String]) async throws -> Transcript {
        switch await FileTranscriber.run(url: audio, size: .medium) {
        case .success(let transcript): return transcript
        case .failure(let error): throw error
        }
    }
}
