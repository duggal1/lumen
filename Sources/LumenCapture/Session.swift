import Foundation
import CoreVideo
import AVFoundation
import CoreGraphics
import AppKit
import os
import LumenCore
import LumenProject

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
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private var started = false
    private let paused = OSAllocatedUnfairLock(initialState: false)
    let first = OSAllocatedUnfairLock<Double?>(initialState: nil)

    init(url: URL, deviceID: String?) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        super.init()
        guard let dev = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .video) else { throw CaptureError.noSource }
        session.beginConfiguration()
        // macOS does not expose AVCaptureSession.Preset.inputPriority. Use the
        // highest *supported* session preset, then encode the actual buffer
        // dimensions reported by the camera, never a fictional 4K resolution.
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { throw CaptureError.noSource }
        session.addInput(input)
        let presets: [AVCaptureSession.Preset] = [.hd4K3840x2160, .hd1920x1080, .hd1280x720, .high]
        if let best = presets.first(where: { session.canSetSessionPreset($0) }) {
            session.sessionPreset = best
        }
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: q)
        session.addOutput(out)
        session.commitConfiguration()
    }
    func start() { session.startRunning() }
    func pause() { paused.withLock { $0 = true } }
    func resume() { paused.withLock { $0 = false } }
    func stop() async {
        session.stopRunning()
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

/// Orchestrates prepare/start/stop and pause/resume. Never touches frames.
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
    private var journalStart = Date()
    public private(set) var isPaused = false
    public init() {}

    public func setLiveHooks(frame: (@Sendable (CVPixelBuffer) -> Void)?, event: (@Sendable (InputEvent) -> Void)?) {
        engine?.setLiveFrameHook(frame); input?.setLiveEventHook(event)
    }

    public func prepare(_ config: RecordingConfig, library: URL) async throws {
        cfg = config
        let name = "Recording " + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let b = try ProjectBundle.create(named: name, in: library)
        bundle = b
        let e = CaptureEngine(bundle: b)
        try await e.prepare(config)
        engine = e
        unit = ClockCalibration.eventUnit()
        if let info = e.info {
            let clock = RecordingClock(originHostSeconds: 0, eventUnit: unit)
            let i = await MainActor.run {
                InputRecorder(url: b.eventsURL, axURL: b.axURL, origin: CGPoint(x: info.originX, y: info.originY), scale: info.backingScale, clock: clock)
            }
            input = i
        }
        if config.webcamDeviceID != nil { webcam = try WebcamRecorder(url: b.webcamURL, deviceID: config.webcamDeviceID) }
        // Device IDs are unique and checked before recording starts; never
        // quietly substitute the system default if a requested device vanished.
        extraMicrophones = try Array(Set(config.additionalMicDeviceIDs))
            .sorted().enumerated().map { index, id in
                try ExtraMicrophoneRecorder(deviceID: id, file: "mic-extra-\(index + 1).caf", in: b)
            }
    }

    public func start() async throws {
        guard let engine, let input else { throw CaptureError.noSource }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                                                         reason: "Lumen recording")
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
        journalStart = Date()
        startJournal()
    }

    /// Pause keeps the capture graph alive but stops appending frames and audio.
    /// Everything recorded during the pause is cut out on stop.
    public func pause() {
        guard !isPaused else { return }
        engine?.pause(); webcam?.pause(); extraMicrophones.forEach { $0.pause() }
        isPaused = true
    }

    public func resume() {
        guard isPaused else { return }
        engine?.resume(); webcam?.resume(); extraMicrophones.forEach { $0.resume() }
        isPaused = false
    }

    public func togglePause() { isPaused ? resume() : pause() }

    /// A tiny journal is rewritten once a second. If the process dies, the next
    /// launch can rebuild the project from it instead of losing the recording.
    private func startJournal() {
        journalTask?.cancel()
        journalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.writeJournal()
            }
        }
    }

    private func writeJournal() {
        guard let b = bundle, let e = engine, let info = e.info else { return }
        let j = RecordingJournal(started: journalStart, updated: Date(), source: info,
                                 fps: Double(cfg?.fps ?? 60),
                                 mic: cfg?.mic ?? false, system: cfg?.systemAudio ?? false,
                                 webcam: cfg?.webcamDeviceID != nil,
                                 pauseIntervals: e.pauseIntervals,
                                 lastFramePTS: e.lastPTS,
                                 firstFramePTS: e.firstPTS,
                                 droppedFrames: e.droppedFrames)
        b.writeJournal(j)
    }

    public func stats() -> CaptureStats {
        CaptureStats(elapsed: engine?.elapsed ?? 0, micLevel: engine?.mic?.level.withLock { $0 } ?? 0,
                     dropped: engine?.droppedFrames ?? 0, thermal: ProcessInfo.processInfo.thermalState.rawValue)
    }

    public func stop() async throws -> ProjectBundle {
        guard let engine, let input, let b = bundle, var info = engine.info else { throw CaptureError.noSource }
        defer { if let a = activity { ProcessInfo.processInfo.endActivity(a) } }
        journalTask?.cancel(); journalTask = nil
        // Close an open pause so the recorded span has a clean end before the
        // writer is finalised.
        if isPaused { resume() }
        isPaused = false
        await input.stop()
        await webcam?.stop()
        // Always close device files, even if screen encoding fails.
        for recorder in extraMicrophones { await recorder.stop() }
        try await engine.stop()
        let origin = engine.firstPTS ?? 0
        info.duration = max(engine.lastPTS - origin, 0)
        var meta = ProjectMeta(name: b.url.deletingPathExtension().lastPathComponent, source: info,
                               clock: RecordingClock(originHostSeconds: origin, eventUnit: unit))
        meta.droppedFrames = engine.droppedFrames
        if let t = engine.mic?.first.withLock({ $0 }) { meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: t) }
        if let t = engine.system?.first.withLock({ $0 }) { meta.system = TrackMeta(file: "system.caf", startHostSeconds: t) }
        if let t = webcam?.first.withLock({ $0 }) { meta.webcam = TrackMeta(file: "webcam.mov", startHostSeconds: t) }
        meta.additionalMicrophones = extraMicrophones.compactMap(\.track)
        var tl = Timeline(duration: info.duration)
        // A pause captured nothing. Replaying it as a cut is exactly the same
        // result as if the user had stopped, saved, and started a new take.
        let pauses = engine.pauseIntervals.compactMap { p -> CutRange? in
            let a = max(p.start - origin, 0), e = min(p.end - origin, info.duration)
            return e - a > 0.05 ? CutRange(start: a, end: e, origin: .manual) : nil
        }
        tl.timeMap.cuts = pauses.sorted { $0.start < $1.start }
        if meta.webcam != nil { tl.webcam = WebcamLayout() }
        try b.save(ProjectFile(meta: meta, timeline: tl))
        b.clearJournal()
        return b
    }
}
