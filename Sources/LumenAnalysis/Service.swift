import Foundation
import AVFoundation
import os
import LumenCore
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

/// What context a trace was allowed to use. Part of the cache key: a trace
/// produced with AX anchors is not interchangeable with one produced without.
public struct TypingContextPolicy: Codable, Sendable, Equatable {
    public var usesAXAnchors: Bool
    /// A missing anchor is unknown, never "public page" or screen centre.
    public var treatsMissingAnchorAsUnknown: Bool
    public static let current = TypingContextPolicy(usesAXAnchors: true, treatsMissingAnchorAsUnknown: true)
    public init(usesAXAnchors: Bool, treatsMissingAnchorAsUnknown: Bool) {
        self.usesAXAnchors = usesAXAnchors; self.treatsMissingAnchorAsUnknown = treatsMissingAnchorAsUnknown
    }
}

/// Measured work counters, shared by every analyzer. Tests read these to prove
/// the decode pass merged bursts instead of trusting a comment.
public final class AnalysisMetrics: @unchecked Sendable {
    public struct Counters: Sendable, Equatable {
        public var typingWindows: Int = 0
        public var typingReaderOpens: Int = 0
        public var typingFrames: Int = 0
        public var typingTiles: Int = 0
        public var lumaCalls: Int = 0
        public var lumaMicroseconds: Int64 = 0
    }
    public static let shared = AnalysisMetrics()
    public init() {}
    private let lock = OSAllocatedUnfairLock(initialState: Counters())
    public func add(windows: Int = 0, readerOpens: Int = 0, frames: Int = 0, tiles: Int = 0) {
        lock.withLock { state in
            state.typingWindows += windows
            state.typingReaderOpens += readerOpens
            state.typingFrames += frames
            state.typingTiles += tiles
        }
    }
    public func add(luma: Int) {
        lock.withLock { state in state.lumaCalls += 1; state.lumaMicroseconds += Int64(luma) }
    }
    public func snapshot() -> Counters { lock.withLock { $0 } }
    public func reset() { lock.withLock { state in state = Counters() } }
}

/// One unit of analysis work. Lower `priority` starts first.
public struct AnalysisJob: Sendable {
    public var name: String
    public var priority: Int
    private let body: @Sendable () async -> Void
    public init(name: String, priority: Int, body: @escaping @Sendable () async -> Void) {
        self.name = name; self.priority = priority; self.body = body
    }
    public func run() async { await body() }
}

/// What the scheduler actually did. Measured, never asserted on hope.
public struct AnalysisScheduleReport: Sendable, Equatable {
    public var capacity: Int = 0
    public var peakConcurrency: Int = 0
    public var order: [String] = []
    public var seconds: [String: Double] = [:]
}

/// Bounded, priority-ordered runner for analysis stages.
///
/// "At most two analyzers" used to be a comment; this is the mechanism. Jobs
/// start in priority order and never exceed `capacity` at once, so the typing
/// pass and the privacy first frame are never queued behind the long OCR scan.
public enum AnalysisScheduler {
    public static let defaultCapacity = 2

    public static func run(_ jobs: [AnalysisJob], capacity: Int) async -> AnalysisScheduleReport {
        let ordered = jobs.enumerated()
            .sorted { a, b in a.element.priority != b.element.priority ? a.element.priority < b.element.priority : a.offset < b.offset }
            .map(\.element)
        let cap = max(capacity, 1)
        let state = ScheduleState()
        await withTaskGroup(of: Void.self) { group in
            var next = 0, running = 0
            while next < ordered.count || running > 0 {
                if Task.isCancelled {
                    // Do not admit a new decoder or Vision job from a stale
                    // editor revision. Drain only the already-admitted work.
                    group.cancelAll()
                    next = ordered.count
                }
                while !Task.isCancelled, running < cap, next < ordered.count {
                    let job = ordered[next]
                    next += 1; running += 1
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        state.enter(job.name)
                        let at = DispatchTime.now().uptimeNanoseconds
                        await job.run()
                        state.leave(job.name, seconds: Double(DispatchTime.now().uptimeNanoseconds - at) / 1_000_000_000)
                    }
                }
                guard running > 0 else { break }
                _ = await group.next()
                running -= 1
            }
        }
        let snapshot = state.snapshot()
        return AnalysisScheduleReport(capacity: cap, peakConcurrency: snapshot.peak,
                                      order: snapshot.order, seconds: snapshot.seconds)
    }
}

private final class ScheduleState: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (order: [String], seconds: [String: Double], running: Int, peak: Int) = ([], [:], 0, 0)
    func enter(_ name: String) {
        lock.lock()
        storage.order.append(name)
        storage.running += 1
        storage.peak = max(storage.peak, storage.running)
        lock.unlock()
    }
    func leave(_ name: String, seconds: Double) {
        lock.lock()
        storage.running -= 1
        storage.seconds[name] = seconds
        lock.unlock()
    }
    func snapshot() -> (order: [String], seconds: [String: Double], running: Int, peak: Int) {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// Measured schedule plus the analyzer counters for one run.
public struct AnalysisDiagnostics: Sendable, Equatable {
    public var capacity: Int = 0
    public var peakConcurrency: Int = 0
    public var stageOrder: [String] = []
    public var stageSeconds: [String: Double] = [:]
    public var typingWindows: Int = 0
    public var typingReaderOpens: Int = 0
    public var typingFrames: Int = 0
    public var lumaCalls: Int = 0
    public var lumaMicroseconds: Int64 = 0
    public init() {}
}

public struct AnalysisRequest: Sendable {
    public var sourceDuration = 0.0
    public var privacyProgress: @Sendable (Double) -> Void = { _ in }
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
    public var includeTyping: Bool
    public var events: [InputEvent]
    public var ax: [AXFrame] = []
    /// Concurrent analyzer cap. `nil` uses the measured default (2).
    public var maxConcurrentAnalyzers: Int? = nil
    /// Typing sample target; clamped to the source frame rate by the decoder.
    public var typingSampleHz: Double = 30

    public init(screen: URL, webcam: URL? = nil, mic: URL? = nil, cacheDirectory: URL, webcamOffset: Double = 0,
                micOffset: Double = 0, projectSalt: UInt64, privacy: PrivacyPlan = PrivacyPlan(), locale: String = "en-US",
                vocabulary: [String] = [], includeSpeech: Bool = false, includeActivity: Bool = false,
                includeFace: Bool = true, includePersonMask: Bool = false, includeTyping: Bool = false,
                events: [InputEvent] = []) {
        self.screen = screen; self.webcam = webcam; self.mic = mic; self.cacheDirectory = cacheDirectory
        self.webcamOffset = webcamOffset; self.micOffset = micOffset; self.projectSalt = projectSalt; self.privacy = privacy
        self.locale = locale; self.vocabulary = vocabulary; self.includeSpeech = includeSpeech; self.includeActivity = includeActivity
        self.includeFace = includeFace; self.includePersonMask = includePersonMask
        self.includeTyping = includeTyping; self.events = events
    }
}

public struct AnalysisResult: Sendable {
    public var face: [FaceSample]
    public var activity: [ActivityPoint]
    /// 48x27 energy grids at 10 Hz for every screen (desktop) recording.
    public var activityGrids: ActivityCache?
    public var ocr: [OCRDetection]
    public var transcript: Transcript?
    public var personMask: PersonMaskInfo?
    public var typing: [TypingTrace]
    public var errors: [String: String]
    public var diagnostics: AnalysisDiagnostics
    public init(face: [FaceSample] = [], activity: [ActivityPoint] = [], activityGrids: ActivityCache? = nil,
                ocr: [OCRDetection] = [], transcript: Transcript? = nil,
                personMask: PersonMaskInfo? = nil, typing: [TypingTrace] = [], errors: [String: String] = [:],
                diagnostics: AnalysisDiagnostics = AnalysisDiagnostics()) {
        self.face = face; self.activity = activity; self.activityGrids = activityGrids
        self.ocr = ocr; self.transcript = transcript
        self.personMask = personMask; self.typing = typing; self.errors = errors; self.diagnostics = diagnostics
    }
}

/// Every stage writes its slot here, so jobs stay independent of each other.
private actor AnalysisCollector {
    private(set) var ocr: [OCRDetection] = []
    private(set) var ocrError: String?
    private var ocrFinished = false
    private(set) var face: [FaceSample] = []
    private(set) var faceError: String?
    private(set) var activity: [ActivityPoint] = []
    private(set) var activityGrids: ActivityCache?
    private(set) var activityError: String?
    private(set) var transcript: Transcript?
    private(set) var transcriptError: String?
    private(set) var personMask: PersonMaskInfo?
    private(set) var personMaskError: String?
    private(set) var typing: [TypingTrace] = []
    private(set) var typingError: String?

    func setOCR(_ value: [OCRDetection], error: String?) {
        ocr = value; ocrError = error; ocrFinished = true
    }
    /// A first-frame result is only provisional, even when it is empty.
    func setOCRIfEmpty(_ value: [OCRDetection]) -> Bool {
        guard !ocrFinished, ocr.isEmpty else { return false }
        ocr = value
        return true
    }
    func setFace(_ value: [FaceSample], error: String?) { face = value; faceError = error }
    func setActivity(_ value: [ActivityPoint], grids: ActivityCache?, error: String?) {
        activity = value; activityGrids = grids; activityError = error
    }
    func setTranscript(_ value: Transcript?, error: String?) { transcript = value; transcriptError = error }
    func setPersonMask(_ value: PersonMaskInfo?, error: String?) { personMask = value; personMaskError = error }
    func setTyping(_ value: [TypingTrace], error: String?) { typing = value; typingError = error }
}

public actor AnalysisService {
    public static let shared = AnalysisService()
    private let speech = MoonshineSpeechEngine()
    public init() {}

    public func run(_ request: AnalysisRequest, onTyping: @escaping @Sendable (AnalysisResult) -> Void = { _ in },
                    onPrivacy: @escaping @Sendable (AnalysisResult) -> Void = { _ in },
                    onPrivacyPartial: @escaping @Sendable (AnalysisResult) -> Void = { _ in },
                    onPrivacyStart: @escaping @Sendable () -> Void = {},
                    onActivity: @escaping @Sendable (AnalysisResult) -> Void = { _ in }) async -> AnalysisResult {
        // The privacy gate must always resolve: whatever ends this run — a
        // finished scan, a failure, a cancellation or a disabled plan — the
        // progress reaches 1 so the editor stops waiting for the masks.
        defer { request.privacyProgress(1) }
        // Capture never shares the CPU with analysis.
        while RecordingGate.isRecordingActive {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return AnalysisResult(errors: ["cancelled": "analysis paused during recording"]) }
        }
        let before = AnalysisMetrics.shared.snapshot()
        let collector = AnalysisCollector()
        onPrivacyStart()

        var jobs: [AnalysisJob] = []
        // Priority 0: the evidence the editor and the camera need first. The
        // first privacy frame publishes masks for what is on screen now, and
        // typing produces the zoom anchors.
        if request.privacy.enabled, request.privacy.autoDetect {
            jobs.append(AnalysisJob(name: "privacy-first-frame", priority: 0) {
                await self.firstPrivacyFrame(request, collector: collector, onPrivacy: onPrivacyPartial)
            })
        }
        if request.includeTyping, !request.events.isEmpty {
            jobs.append(AnalysisJob(name: "typing", priority: 0) {
                let (traces, error) = await self.typing(request)
                await collector.setTyping(traces, error: error)
                guard error == nil else { return }
                onTyping(AnalysisResult(typing: traces))
            })
        }
        // Priority 1: the rest of the picture.
        if request.includeFace, request.webcam != nil {
            jobs.append(AnalysisJob(name: "face", priority: 1) {
                let (samples, error) = await self.face(request)
                await collector.setFace(samples, error: error)
            })
        }
        // Activity runs for ALL desktop recordings: `screen` is always a screen
        // capture, and the grid pass is the input to activity-driven auto-zoom.
        // `includeActivity` is kept for API compatibility and no longer gates it.
        jobs.append(AnalysisJob(name: "activity", priority: 1) {
            let (points, grids, error) = await self.activity(request)
            await collector.setActivity(points, grids: grids, error: error)
            if error == nil { onActivity(AnalysisResult(activity: points, activityGrids: grids)) }
        })
        if request.includeSpeech, request.mic != nil {
            jobs.append(AnalysisJob(name: "transcript", priority: 1) {
                let (words, error) = await self.transcript(request)
                await collector.setTranscript(words, error: error)
            })
        }
        // Priority 2: the long scan that gates export, never first paint.
        if request.privacy.enabled, request.privacy.autoDetect {
            jobs.append(AnalysisJob(name: "privacy-scan", priority: 2) {
                let (detections, error) = await self.ocr(request)
                await collector.setOCR(detections, error: error)
                onPrivacy(AnalysisResult(ocr: detections, errors: error.map { ["ocr": $0] } ?? [:]))
            })
        }
        if request.includePersonMask, request.webcam != nil {
            jobs.append(AnalysisJob(name: "person-mask", priority: 3) {
                let (mask, error) = await self.personMask(request)
                await collector.setPersonMask(mask, error: error)
            })
        }

        let report = await AnalysisScheduler.run(jobs, capacity: request.maxConcurrentAnalyzers ?? AnalysisScheduler.defaultCapacity)
        let after = AnalysisMetrics.shared.snapshot()
        // A cancelled scan still knows what it found: partial results travel
        // with the error so the privacy gate fails closed instead of silently
        // dropping masks that were already computed.
        var errors: [String: String] = [:]
        func put(_ key: String, _ value: String?) { if let value { errors[key] = value } }
        put("face", await collector.faceError)
        put("activity", await collector.activityError)
        put("ocr", await collector.ocrError)
        put("speech", await collector.transcriptError)
        put("personMask", await collector.personMaskError)
        put("typing", await collector.typingError)
        if Task.isCancelled {
            errors["cancelled"] = "analysis cancelled"
            if request.privacy.enabled, request.privacy.autoDetect,
               !report.order.contains("privacy-scan") {
                // A cancelled queued scan never got its normal completion
                // callback. Publish what was found and an explicit failure,
                // rather than pretending automatic privacy verification ran.
                onPrivacy(AnalysisResult(ocr: await collector.ocr, errors: errors))
            }
        }
        return AnalysisResult(face: await collector.face, activity: await collector.activity,
                              activityGrids: await collector.activityGrids,
                              ocr: await collector.ocr, transcript: await collector.transcript,
                              personMask: await collector.personMask, typing: await collector.typing,
                              errors: errors,
                              diagnostics: diagnostics(report: report, before: before, after: after))
    }

    private func diagnostics(report: AnalysisScheduleReport, before: AnalysisMetrics.Counters,
                             after: AnalysisMetrics.Counters = AnalysisMetrics.shared.snapshot()) -> AnalysisDiagnostics {
        var out = AnalysisDiagnostics()
        out.capacity = report.capacity
        out.peakConcurrency = report.peakConcurrency
        out.stageOrder = report.order
        out.stageSeconds = report.seconds
        out.typingWindows = after.typingWindows - before.typingWindows
        out.typingReaderOpens = after.typingReaderOpens - before.typingReaderOpens
        out.typingFrames = after.typingFrames - before.typingFrames
        out.lumaCalls = after.lumaCalls - before.lumaCalls
        out.lumaMicroseconds = after.lumaMicroseconds - before.lumaMicroseconds
        return out
    }

    public func runTyping(_ request: AnalysisRequest) async -> AnalysisResult {
        let (traces, error) = await typing(request)
        return AnalysisResult(typing: traces, errors: error.map { ["typing": $0] } ?? [:])
    }

    public func runPrivacy(_ request: AnalysisRequest) async -> AnalysisResult {
        let (detections, error) = await ocr(request)
        return AnalysisResult(ocr: detections, errors: error.map { ["ocr": $0] } ?? [:])
    }

    /// One decoded frame of masks, so the editor is not unprotected while the
    /// full scan runs. It publishes and returns; it never completes the gate.
    private func firstPrivacyFrame(_ request: AnalysisRequest, collector: AnalysisCollector,
                                   onPrivacy: @Sendable (AnalysisResult) -> Void) async {
        guard ProcessInfo.processInfo.environment["LUMEN_NO_OCR"] != "1" else { return }
        let (detections, error) = await ocr(request, firstFrameOnly: true)
        if error == nil, !detections.isEmpty, await collector.setOCRIfEmpty(detections) {
            onPrivacy(AnalysisResult(ocr: detections))
        }
    }

    private func face(_ r: AnalysisRequest) async -> ([FaceSample], String?) {
        guard r.includeFace, let webcam = r.webcam else { return ([], nil) }
        let (samples, error) = await cached(url: webcam, directory: analysisDirectory(r), analyzer: "face", version: 1,
                                            parameters: FaceParameters(offset: r.webcamOffset, fps: 12)) {
            try await FaceAnalyzer.analyze(url: webcam, startOffset: r.webcamOffset)
        }
        return (samples ?? [], error)
    }

    private func activity(_ r: AnalysisRequest) async -> ([ActivityPoint], ActivityCache?, String?) {
        let (cache, error) = await ActivityFetch.cached(url: r.screen, directory: analysisDirectory(r), hz: 10) {
            // Warm-cache reopen does not allocate a Metal pipeline or reader.
            let analyzer = try ActivityAnalyzer()
            return try await analyzer.analyze(screen: r.screen, hz: 10)
        }
        guard let cache else { return ([], nil, error) }
        return (ActivityPointBridge.points(from: cache), cache, nil)
    }

    private func ocr(_ r: AnalysisRequest, firstFrameOnly: Bool = false) async -> ([OCRDetection], String?) {
        if firstFrameOnly {
            do {
                return (try await OCRAnalyzer.analyze(url: r.screen, projectSalt: r.projectSalt,
                                                      customPatterns: r.privacy.customPatterns,
                                                      entropyThreshold: r.privacy.entropyThreshold,
                                                      firstFrameOnly: true), nil)
            } catch { return ([], "\(error)") }
        }
        defer { r.privacyProgress(1) }
        guard r.privacy.enabled, r.privacy.autoDetect else { return ([], nil) }
        guard ProcessInfo.processInfo.environment["LUMEN_NO_OCR"] != "1" else {
            return ([], "Automatic text scanning is disabled by LUMEN_NO_OCR.")
        }
        let params = OCRParameters(salt: r.projectSalt, patterns: r.privacy.customPatterns,
                                   entropyThreshold: r.privacy.entropyThreshold, fps: 4)
        do {
            let directory = analysisDirectory(r)
            let key = try await AnalysisCache.key(media: r.screen, analyzer: "sensitive-text", version: 8, parameters: params)
            if let detections = AnalysisCache.load([OCRDetection].self, key: key, directory: directory) { return (detections, nil) }
            let detections = try await OCRAnalyzer.analyze(url: r.screen, projectSalt: r.projectSalt,
                customPatterns: r.privacy.customPatterns, entropyThreshold: r.privacy.entropyThreshold,
                duration: r.sourceDuration, progress: r.privacyProgress)
            try AnalysisCache.save(detections, key: key, directory: directory)
            return (detections, nil)
        } catch let partial as PartialScan {
            return (partial.detections, "Scan cut short — masks cover what was found. Retry scanning before sharing.")
        } catch { return ([], error.localizedDescription) }
    }

    private func transcript(_ r: AnalysisRequest) async -> (Transcript?, String?) {
        guard r.includeSpeech, let mic = r.mic else { return (nil, nil) }
        let params = SpeechParameters(locale: r.locale, vocabulary: r.vocabulary, offset: r.micOffset)
        let engine = speech
        return await cached(url: mic, directory: analysisDirectory(r), analyzer: "transcript-medium", version: 2,
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

    private func typing(_ r: AnalysisRequest) async -> ([TypingTrace], String?) {
        guard r.includeTyping, !r.events.isEmpty else { return ([], nil) }
        let bursts = r.events.typingBursts()
        guard !bursts.isEmpty else { return ([], nil) }
        let anchors = TypingAnchorIndex.resolve(events: r.events, ax: r.ax, bursts: bursts)
        let settings = TypingTraceSettings(sampleHz: min(max(r.typingSampleHz, 2), 30))
        let policy = TypingContextPolicy(usesAXAnchors: anchors.contains { $0 != nil }, treatsMissingAnchorAsUnknown: true)
        let params = TypingParameters(bursts: bursts.map { [$0.t0, $0.t1] },
                                      anchors: anchors.map { $0.map { [$0.x, $0.y] } ?? [-1, -1] },
                                      sampleHz: settings.sampleHz, lead: 0.20, tail: 0.50, mergeGap: 0.35,
                                      format: 2, contextPolicy: policy)
        let (traces, error) = await cached(url: r.screen, directory: analysisDirectory(r), analyzer: "typing", version: 5,
                                           parameters: params) {
            try await TypingAnalyzer.analyze(url: r.screen, bursts: bursts, anchors: anchors, settings: settings)
        }
        return (traces ?? [], error)
    }

    private func cached<Value: Codable & Sendable, Parameters: Encodable & Sendable>(url: URL, directory: URL, analyzer: String, version: Int,
                                                                           parameters: Parameters,
                                                                           produce: () async throws -> Value) async -> (Value?, String?) {
        do {
            try Task.checkCancellation()
            let key = try await AnalysisCache.key(media: url, analyzer: analyzer, version: version, parameters: parameters)
            try Task.checkCancellation()
            if let cached = AnalysisCache.load(Value.self, key: key, directory: directory) { return (cached, nil) }
            let value = try await produce()
            try Task.checkCancellation()
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
private struct OCRParameters: Codable { var salt: UInt64; var patterns: [String]; var entropyThreshold: Double; var fps: Double }
private struct SpeechParameters: Codable { var locale: String; var vocabulary: [String]; var offset: Double }
private struct PersonMaskParameters: Codable { var offset: Double; var fps: Double; var maxDimension: Int }
/// `format` is the trace shape; a format change must never reuse an old entry.
private struct TypingParameters: Codable, Sendable {
    var bursts: [[Double]]
    var anchors: [[Double]]
    var sampleHz: Double
    var lead: Double
    var tail: Double
    var mergeGap: Double
    var format: Int
    var contextPolicy: TypingContextPolicy
}