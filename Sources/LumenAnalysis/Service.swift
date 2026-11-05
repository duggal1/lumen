import Foundation
import AVFoundation
import LumenProject

final class ReaderHandle: @unchecked Sendable {
    let reader: AVAssetReader
    init(_ reader: AVAssetReader) { self.reader = reader }
}

enum AnalysisError: Error, LocalizedError, Sendable {
    case noVideoTrack
    case readerConfiguration
    case readerStart
    case readerFailed
    case pixelBuffer
    case cacheWrite
    case noMaskFrames
    case maskScale(Int)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "No video track is available for analysis."
        case .readerConfiguration: "The media reader could not be configured."
        case .readerStart: "The media reader could not start."
        case .readerFailed: "Media decoding failed during analysis."
        case .pixelBuffer: "A decoded analysis frame could not be read."
        case .cacheWrite: "The analysis cache could not be created."
        case .noMaskFrames: "Person segmentation did not produce any frames."
        case .maskScale(let code): "Person mask scaling failed with code \(code)."
        }
    }
}

public struct AnalysisRequest: Sendable {
    public var screen: URL
    public var webcam: URL?
    public var mic: URL?
    public var cacheDirectory: URL
    public var webcamOffset: Double
    public var micOffset: Double
    public var projectSalt: UInt64
    public var privacy: PrivacyPlan
    public var locale: String
    public var vocabulary: [String]
    public var includeSpeech: Bool
    public var includeActivity: Bool
    public var includeFace: Bool
    public var includePersonMask: Bool

    public init(screen: URL, webcam: URL? = nil, mic: URL? = nil, cacheDirectory: URL, webcamOffset: Double = 0,
                micOffset: Double = 0, projectSalt: UInt64, privacy: PrivacyPlan = PrivacyPlan(), locale: String = "en-US",
                vocabulary: [String] = [], includeSpeech: Bool = false, includeActivity: Bool = false,
                includeFace: Bool = true, includePersonMask: Bool = false) {
        self.screen = screen; self.webcam = webcam; self.mic = mic; self.cacheDirectory = cacheDirectory
        self.webcamOffset = webcamOffset; self.micOffset = micOffset; self.projectSalt = projectSalt; self.privacy = privacy
        self.locale = locale; self.vocabulary = vocabulary; self.includeSpeech = includeSpeech; self.includeActivity = includeActivity
        self.includeFace = includeFace; self.includePersonMask = includePersonMask
    }
}

public struct AnalysisResult: Sendable {
    public var face: [FaceSample]
    public var activity: [ActivityPoint]
    public var ocr: [OCRDetection]
    public var transcript: Transcript?
    public var personMask: PersonMaskInfo?
    public var errors: [String: String]
    public init(face: [FaceSample] = [], activity: [ActivityPoint] = [], ocr: [OCRDetection] = [], transcript: Transcript? = nil,
                personMask: PersonMaskInfo? = nil, errors: [String: String] = [:]) {
        self.face = face; self.activity = activity; self.ocr = ocr; self.transcript = transcript
        self.personMask = personMask; self.errors = errors
    }
}

public actor AnalysisService {
    public static let shared = AnalysisService()
    private let speech = AppleSpeechEngine()
    public init() {}

    public func run(_ request: AnalysisRequest) async -> AnalysisResult {
        async let faceResult = face(request)
        async let activityResult = activity(request)
        async let ocrResult = ocr(request)
        async let transcriptResult = transcript(request)
        async let personMaskResult = personMask(request)
        let (faces, faceError) = await faceResult
        let (activities, activityError) = await activityResult
        let (detections, ocrError) = await ocrResult
        let (words, transcriptError) = await transcriptResult
        let (mask, maskError) = await personMaskResult
        var errors: [String: String] = [:]
        if let faceError { errors["face"] = faceError }
        if let activityError { errors["activity"] = activityError }
        if let ocrError { errors["ocr"] = ocrError }
        if let transcriptError { errors["speech"] = transcriptError }
        if let maskError { errors["personMask"] = maskError }
        return AnalysisResult(face: faces, activity: activities, ocr: detections, transcript: words,
                              personMask: mask, errors: errors)
    }

    private func face(_ r: AnalysisRequest) async -> ([FaceSample], String?) {
        guard r.includeFace, let webcam = r.webcam else { return ([], nil) }
        let (samples, error) = await cached(url: webcam, directory: analysisDirectory(r), analyzer: "face", version: 1,
                                            parameters: FaceParameters(offset: r.webcamOffset, fps: 12)) {
            try await FaceAnalyzer.analyze(url: webcam, startOffset: r.webcamOffset)
        }
        return (samples ?? [], error)
    }

    private func activity(_ r: AnalysisRequest) async -> ([ActivityPoint], String?) {
        guard r.includeActivity else { return ([], nil) }
        let (points, error) = await cached(url: r.screen, directory: analysisDirectory(r), analyzer: "activity", version: 1,
                                           parameters: ActivityParameters(offset: 0, fps: 10)) {
            try await ActivityAnalyzer.analyze(url: r.screen, fps: 10)
        }
        return (points ?? [], error)
    }

    private func ocr(_ r: AnalysisRequest) async -> ([OCRDetection], String?) {
        guard r.privacy.enabled, r.privacy.autoDetect else { return ([], nil) }
        guard ProcessInfo.processInfo.environment["LUMEN_NO_OCR"] != "1" else {
            return ([], "Automatic text scanning is disabled by LUMEN_NO_OCR.")
        }
        let params = OCRParameters(salt: r.projectSalt, patterns: r.privacy.customPatterns,
                                   entropyThreshold: r.privacy.entropyThreshold, fps: 2)
        let (detections, error) = await cached(url: r.screen, directory: analysisDirectory(r), analyzer: "sensitive-text", version: 1,
                                               parameters: params) {
            try await OCRAnalyzer.analyze(url: r.screen, projectSalt: r.projectSalt, customPatterns: r.privacy.customPatterns,
                                          entropyThreshold: r.privacy.entropyThreshold)
        }
        return (detections ?? [], error)
    }

    private func transcript(_ r: AnalysisRequest) async -> (Transcript?, String?) {
        guard r.includeSpeech, let mic = r.mic else { return (nil, nil) }
        let params = SpeechParameters(locale: r.locale, vocabulary: r.vocabulary, offset: r.micOffset)
        let engine = speech
        return await cached(url: mic, directory: analysisDirectory(r), analyzer: "transcript", version: 1,
                            parameters: params) {
            var result = try await engine.transcribe(audio: mic, locale: Locale(identifier: r.locale), vocabulary: r.vocabulary)
            for i in result.words.indices { result.words[i].start += r.micOffset; result.words[i].end += r.micOffset }
            return result
        }
    }

    private func personMask(_ r: AnalysisRequest) async -> (PersonMaskInfo?, String?) {
        guard r.includePersonMask, let webcam = r.webcam else { return (nil, nil) }
        let directory = analysisDirectory(r)
        let params = PersonMaskParameters(offset: r.webcamOffset, fps: 30, maxDimension: 720)
        do {
            let key = try await AnalysisCache.key(media: webcam, analyzer: "person-mask", version: 1, parameters: params)
            if let cached = AnalysisCache.load(PersonMaskInfo.self, key: key, directory: directory),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(cached.file).path) { return (cached, nil) }
            let output = directory.appendingPathComponent("\(key).lmask")
            let info = try await PersonMaskAnalyzer.analyze(url: webcam, output: output, offset: r.webcamOffset)
            try AnalysisCache.save(info, key: key, directory: directory)
            return (info, nil)
        } catch { return (nil, error.localizedDescription) }
    }

    private func cached<Value: Codable & Sendable, Parameters: Encodable & Sendable>(url: URL, directory: URL, analyzer: String, version: Int,
                                                                           parameters: Parameters,
                                                                           produce: () async throws -> Value) async -> (Value?, String?) {
        do {
            let key = try await AnalysisCache.key(media: url, analyzer: analyzer, version: version, parameters: parameters)
            if let cached = AnalysisCache.load(Value.self, key: key, directory: directory) { return (cached, nil) }
            let value = try await produce()
            try AnalysisCache.save(value, key: key, directory: directory)
            return (value, nil)
        } catch is CancellationError {
            return (nil, "Cancelled")
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func analysisDirectory(_ request: AnalysisRequest) -> URL {
        request.cacheDirectory.appendingPathComponent("analysis", isDirectory: true)
    }
}

private struct FaceParameters: Codable, Sendable { var offset: Double; var fps: Double }
private struct ActivityParameters: Codable, Sendable { var offset: Double; var fps: Double }
private struct OCRParameters: Codable { var salt: UInt64; var patterns: [String]; var entropyThreshold: Double; var fps: Double }
private struct SpeechParameters: Codable { var locale: String; var vocabulary: [String]; var offset: Double }
private struct PersonMaskParameters: Codable { var offset: Double; var fps: Double; var maxDimension: Int }
