import Foundation
import Speech
import LumenProject

public enum SpeechAnalysisError: Error, Sendable {
    case permissionDenied
    case recognizerUnavailable
}

public protocol TranscriptionEngine: Sendable {
    func transcribe(audio: URL, locale: Locale, vocabulary: [String]) async throws -> Transcript
}

public struct AppleSpeechEngine: TranscriptionEngine {
    public init() {}

    public func transcribe(audio: URL, locale: Locale, vocabulary: [String]) async throws -> Transcript {
        guard await authorized() else { throw SpeechAnalysisError.permissionDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechAnalysisError.recognizerUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.contextualStrings = Array(vocabulary.prefix(100))
        let job = SpeechJob()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.install(continuation)
                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error { job.finish(.failure(error)); return }
                    guard let result, result.isFinal else { return }
                    let words = result.bestTranscription.segments.map {
                        WordToken(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration, confidence: $0.confidence)
                    }
                    job.finish(.success(Transcript(words: words, locale: locale.identifier)))
                }
                job.set(task)
            }
        } onCancel: {
            job.cancel()
        }
    }

    private func authorized() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
    }
}

private final class SpeechJob: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Transcript, Error>?
    private var task: SFSpeechRecognitionTask?
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Transcript, Error>) {
        lock.lock()
        let cancelled = resolved
        if !cancelled { self.continuation = continuation }
        lock.unlock()
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }

    func set(_ task: SFSpeechRecognitionTask) {
        lock.lock(); defer { lock.unlock() }
        if resolved { task.cancel() } else { self.task = task }
    }

    func finish(_ result: Result<Transcript, Error>) {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        resolved = true
        let continuation = self.continuation
        self.continuation = nil; task = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }
}
