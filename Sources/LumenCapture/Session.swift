import Foundation
import CoreVideo
import AVFoundation
import CoreGraphics
import AppKit
import os
import LumenCore
import LumenProject
import LumenDirector

public enum Permissions {
    public static var screen: Bool { CGPreflightScreenCaptureAccess() }
    public static func requestScreen() { _ = CGRequestScreenCaptureAccess() }
    public static var input: Bool { CGPreflightListenEventAccess() }
    public static func requestInput() { _ = CGRequestListenEventAccess() }
    public static var accessibility: Bool { AXIsProcessTrusted() }
    @MainActor public static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    public static var mic: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    public static var camera: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    public static func requestMedia() async { _ = await AVCaptureDevice.requestAccess(for: .audio); _ = await AVCaptureDevice.requestAccess(for: .video) }
    public static func open(_ pane: String) {   // ScreenCapture, ListenEvent, Accessibility, Microphone, Camera
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(u) }
    }
}

/// Webcam to its own HEVC file. PTS stays on the host clock.
final class WebcamRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let q = DispatchQueue(label: "lumen.webcam")
    private let stopQ = DispatchQueue(label: "lumen.webcam.stop", qos: .userInitiated)
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private var started = false
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private let quality: String
    let first = OSAllocatedUnfairLock<Double?>(initialState: nil)

    init(url: URL, deviceID: String?, quality: String = "auto") throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        self.quality = quality
        super.init()
        guard let dev = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .video) else { throw CaptureError.noSource }
        session.beginConfiguration()
        // macOS does not expose AVCaptureSession.Preset.inputPriority. Use the
        // highest *supported* session preset, then encode the actual buffer
        // dimensions reported by the camera, never a fictional 4K resolution.
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw CaptureError.noSource }
        session.addInput(input)
        let presets: [AVCaptureSession.Preset] = switch quality {
            case "q4k": [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
            case "q1080": [.hd1920x1080, .hd1280x720, .high]
            case "q720": [.hd1280x720, .high]
            default: [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
        }
        if let best = presets.first(where: { session.canSetSessionPreset($0) }) {
            session.sessionPreset = best
        }
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: q)
        session.addOutput(out)
        session.commitConfiguration()
    }
    func start() { stopQ.async { self.session.startRunning() } }
    func pause() { paused.withLock { $0 = true } }
    func resume() { paused.withLock { $0 = false } }
    func stop() async {
        // AVCaptureSession.stopRunning can block 100 ms+. Run it off the
        // caller's thread (never main, never the session actor's caller).
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            stopQ.async { self.session.stopRunning(); c.resume() }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in q.async { c.resume() } }
        guard started else { writer.cancelWriting(); return }
        input?.markAsFinished(); await writer.finishWriting()
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard !paused.withLock({ $0 }) else { return }
        if input == nil {
            guard let pixels = CMSampleBufferGetImageBuffer(sb) else { return }
            let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
            let fps = 30
            let bitrate = Int(Double(width * height * fps) * 0.11)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]
            ])
            i.expectsMediaDataInRealTime = true
            guard writer.canAdd(i) else { return }
            writer.add(i); input = i
        }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sb.presentationTimeStamp); started = true
            let seconds = sb.presentationTimeStamp.seconds
            first.withLock { $0 = seconds }
        }
        if input?.isReadyForMoreMediaData == true { input?.append(sb) }
    }
}

public struct CaptureStats: Sendable {
    public var elapsed: Double, micLevel: Float
    public var dropped: Int, thermal: Int
}

/// Recording lifecycle states. Every transition is logged + signposted.
/// `failed` carries a plain-language message and recovery action; a stage
/// that exceeds its timeout lands here, never spins forever.
public enum RecordingStage: Sendable, Equatable {
    case idle, preparing, countdown, recording, paused, stopping, finalizing, ready, failed(String)
}

private enum StageTimeout: Error { case timedOut(RecordingStage) }

extension RecordingStage {
    var watchdogName: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .countdown: return "countdown"
        case .recording: return "recording"
        case .paused: return "paused"
        case .stopping: return "stopping"
        case .finalizing: return "finalizing"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}

/// Orchestrates prepare/start/stop and pause/resume. Never touches frames.
/// Threading: actor; all engines are started/stopped concurrently off main.
public actor RecordingSession {
    private var engine: CaptureEngine?
    private var input: InputRecorder?
    private var webcam: WebcamRecorder?
    private var extraMicrophones: [ExtraMicrophoneRecorder] = []
    private var bundle: ProjectBundle?
    private var cfg: RecordingConfig?
    private var unit = EventTimeUnit.machTicks
    private var activity: NSObjectProtocol?
    private var journalTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var journalStart = Date()
    public private(set) var isPaused = false
    public private(set) var stage: RecordingStage = .idle
    private let logger = Logger(subsystem: "com.lumen.studio", category: "capture")
    public init() {}

    private func transition(to next: RecordingStage) {
        let prev = stage
        stage = next
        MainThreadWatchdog.shared.setStage(next.watchdogName)
        logger.info("recording \(String(describing: prev)) -> \(String(describing: next), privacy: .public)")
        os_log("stage %@ -> %@", log: .default, type: .info, String(describing: prev), String(describing: next))
    }

    /// Stage timeout is a failure path only (never a fix for a hang).
    /// Implementation: the watchdog + stage log surface a stall; if the stage
    /// has not advanced within `seconds`, `timeoutHandler` marks `failed`.
    /// The stopwatch runs detached so it never blocks the stage itself.
    private func armStageTimeout(_ stage: RecordingStage, seconds: Double) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await self.timeoutIfStillIn(stage: stage)
        }
    }

    private func timeoutIfStillIn(stage: RecordingStage) {
        // Called on the actor. Only mark failed if we are still in the timed stage.
        if self.stage == stage {
            transition(to: .failed("Stage \(String(describing: stage)) exceeded \(secondsHint) s."))
        }
    }

    private var secondsHint: Int { 10 }

    public func setLiveHooks(frame: (@Sendable (CVPixelBuffer) -> Void)?, event: (@Sendable (InputEvent) -> Void)?, focus: (@Sendable (InputEvent, AXFrame) -> Void)? = nil) {
        engine?.setLiveFrameHook(frame); input?.setLiveEventHook(event); input?.setLiveFocusHook(focus)
    }

    // AGENT: process-targeted virtual input must reach the active recording's event stream as well as the app.
    public func injectInput(kind: InputEvent.Kind, screenPoint: CGPoint, button: UInt8,
                            keyCode: UInt16, flags: UInt16, scrollDelta: Float) {
        guard stage == .recording else { return }
        input?.injectPointer(kind: kind, screenPoint: screenPoint, button: button,
                             keyCode: keyCode, flags: flags, scrollDelta: scrollDelta)
    }

    public func prepare(_ config: RecordingConfig, library: URL) async throws {
        MainThreadWatchdog.shared.start()
        transition(to: .preparing)
        let timeoutTask = armStageTimeout(.preparing, seconds: 15)
        defer { timeoutTask.cancel() }
        do {
            cfg = config
            let name = "Recording " + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            let b = try ProjectBundle.create(named: name, in: library)
            bundle = b
            let e = CaptureEngine(bundle: b)
            // Permissions, SCShareableContent, device discovery, writers,
            // Metal warm-up run concurrently off main (engine.prepare).
            try await e.prepare(config)
            engine = e
            unit = ClockCalibration.eventUnit()
            if let info = e.info {
                let clock = RecordingClock(originHostSeconds: 0, eventUnit: unit)
                let windowID: CGWindowID? = if case .window(let id) = config.source { id } else { nil }
                let i = await MainActor.run {
                    InputRecorder(url: b.eventsURL, axURL: b.axURL, origin: CGPoint(x: info.originX, y: info.originY),
                                  scale: info.backingScale, clock: clock, windowID: windowID)
                }
                input = i
                e.setInputScaleHook { [weak i] scale in i?.setSourceScale(scale) }
            }
            if config.webcamDeviceID != nil { webcam = try WebcamRecorder(url: b.webcamURL, deviceID: config.webcamDeviceID, quality: config.webcamQuality) }
            // Device IDs are unique and checked before recording starts; never
            // quietly substitute the system default if a requested device vanished.
            extraMicrophones = try Array(Set(config.additionalMicDeviceIDs))
                .sorted().enumerated().map { index, id in
                    try ExtraMicrophoneRecorder(deviceID: id, file: "mic-extra-\(index + 1).caf", in: b)
                }
        } catch {
            transition(to: .failed("Preparing stalled. \(error)"))
            throw error
        }
    }

    public func markCountdown() { transition(to: .countdown) }

    public func start() async throws {
        guard let engine, let input else { transition(to: .failed("No capture source.")); throw CaptureError.noSource }
        // Input Monitoring is checked here (at Start), not after the fact.
        if !Permissions.input {
            Permissions.requestInput()
            transition(to: .failed("Input Monitoring is off. Grant it, then relaunch Lumen."))
            throw CaptureError.writer("Input Monitoring is off. Grant it, then relaunch Lumen.")
        }
        let timeoutTask = armStageTimeout(.recording, seconds: 10)
        defer { timeoutTask.cancel() }
        RecordingGate.recordingStarted()
        do {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                                                             reason: "Lumen recording")
            journalStart = Date()
            try await writeJournal()
            try await MainActor.run { try input.start() }
            for recorder in extraMicrophones { recorder.start() }
            webcam?.start()
            do {
                try await engine.start()
            } catch {
                for recorder in extraMicrophones { await recorder.stop() }
                await webcam?.stop()
                await input.stop()
                throw error
            }
            startJournal()
            startWatchdog()
            transition(to: .recording)
        } catch {
            if let bundle, case .failure(let clearError) = bundle.clearJournal() {
                logger.error("could not clear failed-start journal: \(clearError.localizedDescription, privacy: .public)")
            }
            RecordingGate.recordingStopped()
            transition(to: .failed("Starting stalled. \(error)"))
            throw error
        }
    }

    /// Pause keeps the capture graph alive but stops appending frames and audio.
    /// Everything recorded during the pause is cut out on stop.
    public func pause() {
        guard !isPaused else { return }
        engine?.pause(); webcam?.pause(); extraMicrophones.forEach { $0.pause() }
        isPaused = true
        transition(to: .paused)
    }

    public func resume() {
        guard isPaused else { return }
        engine?.resume(); webcam?.resume(); extraMicrophones.forEach { $0.resume() }
        isPaused = false
        transition(to: .recording)
    }

    public func togglePause() { isPaused ? resume() : pause() }

    /// A tiny journal is rewritten once a second. If the process dies, the next
    /// launch can rebuild the project from it instead of losing the recording.
    private func startJournal() {
        journalTask?.cancel()
        journalTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.writeJournal()
                } catch {
                    self.logger.error("recording journal checkpoint failed: \(error.localizedDescription, privacy: .public)")
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func writeJournal() async throws {
        guard let b = bundle, let e = engine, let info = e.info else { return }
        let j = RecordingJournal(started: journalStart, updated: Date(), source: info,
                                 fps: Double(cfg?.fps ?? 60),
                                 mic: cfg?.mic ?? false, system: cfg?.systemAudio ?? false,
                                 webcam: cfg?.webcamDeviceID != nil,
                                 pauseIntervals: e.pauseIntervals,
                                 lastFramePTS: e.lastPTS,
                                 firstFramePTS: e.firstPTS,
                                 droppedFrames: e.droppedFrames)
        try await Task.detached(priority: .utility) {
            try b.writeJournal(j).get()
        }.value
    }

    /// Free-space watchdog + sleep/terminate finalize. Thresholds are
    /// parameters (50 MB hard stop). Process death is bounded by the last
    /// atomic checkpoint (~1 s) and the writer's last flushed fragment (~2 s).
    /// Power loss may also discard filesystem-cached writes.
    private func startWatchdog() {
        watchdogTask?.cancel()
        sleepObserver = NotificationCenter.default.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.finalizeCleanly(reason: "sleep") }
        }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.finalizeCleanly(reason: "terminate") }
        }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                let bundleURL = await self.currentBundleURL()
                guard let url = bundleURL else { return }
                if let vals = try? FileManager.default.attributesOfFileSystem(forPath: url),
                   let free = vals[.systemFreeSize] as? NSNumber, free.int64Value < 50_000_000 {
                    await self.finalizeCleanly(reason: "disk-full")
                    return
                }
            }
        }
    }

    private func currentBundleURL() -> String? {
        bundle?.url.deletingLastPathComponent().path
    }

    private func stopWatchdog() {
        watchdogTask?.cancel(); watchdogTask = nil
        if let s = sleepObserver { NotificationCenter.default.removeObserver(s) }
        if let s = terminateObserver { NotificationCenter.default.removeObserver(s) }
        sleepObserver = nil; terminateObserver = nil
    }

    private func finalizeCleanly(reason: String) async {
        guard stage == .recording || stage == .paused else { return }
        logger.info("finalizing on \(reason, privacy: .public)")
        try? await stopCapture()
        try? await finalize()
    }

    public func stats() -> CaptureStats {
        CaptureStats(elapsed: engine?.elapsed ?? 0, micLevel: engine?.mic?.level.withLock { $0 } ?? 0,
                     dropped: engine?.droppedFrames ?? 0, thermal: ProcessInfo.processInfo.thermalState.rawValue)
    }

    /// Fast stop: stops capture, drains, ends session, finishes audio writers.
    /// Returns within the stop budget; heavy finalization is separate.
    /// Shutdown order: input stop → webcam/extra mics → engine stop
    /// (stopCapture, drain sample queue, endSession, mark inputs finished,
    ///  `await finishWriting` off main).
    public func stopCapture() async throws {
        transition(to: .stopping)
        let timeoutTask = armStageTimeout(.stopping, seconds: 10)
        defer { timeoutTask.cancel() }
        do {
            guard let engine, let input else { throw CaptureError.noSource }
            let pendingJournal = journalTask
            journalTask = nil
            pendingJournal?.cancel()
            await pendingJournal?.value
            stopWatchdog()
            if isPaused { resume() }
            isPaused = false
            async let inputStop: Void = input.stop()
            async let webcamStop: Void = webcam?.stop() ?? ()
            async let engineStop: Void = engine.stop()
            for recorder in extraMicrophones { await recorder.stop() }
            _ = try await (inputStop, webcamStop, engineStop)
        } catch {
            transition(to: .failed("Stopping stalled. \(error)"))
            throw error
        }
    }

    /// Slow finalization: wrap audio journals, finalize events, publish project.
    /// Runs at `.utility` QoS off main; UI shows "Finishing…" with real progress.
    /// Heavy analysis starts only after this returns.
    public func finalize(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ProjectBundle {
        progress(0)
        transition(to: .finalizing)
        // Snapshot actor state first (cheap), then run heavy IO off-actor.
        guard let engine, let b = bundle, var info = engine.info else {
            transition(to: .failed("No bundle to finalize."))
            throw CaptureError.noSource
        }
        let activityToken = activity
        let origin = engine.firstPTS ?? 0
        let stopHostSeconds = HostClock.now()
        info.duration = max(engine.lastPTS - origin, stopHostSeconds - origin, 0)
        var meta = ProjectMeta(name: b.url.deletingPathExtension().lastPathComponent, source: info,
                               clock: RecordingClock(originHostSeconds: origin, eventUnit: unit))
        meta.droppedFrames = engine.droppedFrames
        if let c = cfg {
            meta.captureResolution = c.resolution.rawValue
            meta.captureQuality = c.quality.rawValue
            meta.captureMbps = c.customMbps
        }
        if let t = engine.mic?.first.withLock({ $0 }) { meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: t) }
        if let t = engine.system?.first.withLock({ $0 }) { meta.system = TrackMeta(file: "system.caf", startHostSeconds: t) }
        if let t = webcam?.first.withLock({ $0 }) { meta.webcam = TrackMeta(file: "webcam.mov", startHostSeconds: t) }
        meta.additionalMicrophones = extraMicrophones.compactMap(\.track)
        var tl = Timeline(duration: info.duration)
        let pauses = engine.pauseIntervals.compactMap { p -> CutRange? in
            let a = max(p.start - origin, 0), e = min(p.end - origin, info.duration)
            return e - a > 0.05 ? CutRange(start: a, end: e, origin: .manual) : nil
        }
        tl.timeMap.cuts = pauses.sorted { $0.start < $1.start }
        if meta.webcam != nil { tl.webcam = WebcamLayout() }
        // AGENT: an agent recording asked for auto-masking; enable the plan here.
        if cfg?.privacyAutoMask == true {
            tl.overlays.privacy.enabled = true
            tl.overlays.privacy.autoDetect = true
        }
        let infoCopy = info
        let baseTimeline = tl
        let finalMeta = meta
        do {
            try await Task.detached(priority: .utility) {
                var working = baseTimeline
                progress(0.1)
                do {
                    let recordedEvents = try b.events(origin: origin)
                    let ax = (try? JSONDecoder().decode([AXFrame].self, from: Data(contentsOf: b.axURL))) ?? []
                    progress(0.4)
                    if !recordedEvents.isEmpty {
                        working.zoom = Director.planRecordingZoom(events: recordedEvents, ax: ax,
                                                                  source: infoCopy, timeline: working)
                    }
                } catch {
                    os_log("finalize: event sidecar unreadable: %@", log: .default, type: .error, String(describing: error))
                }
                progress(0.8)
                guard finalMeta.source.duration.isFinite, finalMeta.source.duration > 0,
                      working.timeMap.trimEnd > working.timeMap.trimStart else {
                    throw CaptureError.writer("Recording has no usable duration.")
                }
                try b.save(ProjectFile(meta: finalMeta, timeline: working))
                try b.clearJournal().get()
                progress(1)
            }.value
        } catch {
            RecordingGate.recordingStopped()
            transition(to: .failed("Finalizing stalled. \(error)"))
            throw error
        }
        if let a = activityToken { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
        RecordingGate.recordingStopped()
        MainThreadWatchdog.shared.stop()
        return b
    }

    public func stop() async throws -> ProjectBundle {
        try await stopCapture()
        let b = try await finalize()
        transition(to: .ready)
        return b
    }
}
