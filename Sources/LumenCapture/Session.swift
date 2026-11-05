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
    let first = OSAllocatedUnfairLock<Double?>(initialState: nil)

    init(url: URL, deviceID: String?) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        super.init()
        guard let dev = deviceID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .video) else { throw CaptureError.noSource }
        session.beginConfiguration()
        // Camera hardware resolution is chosen before starting the session.
        // The former fixed 720p preset threw away pixels from 1080p/4K devices.
        let native = dev.formats.compactMap { format -> (format: AVCaptureDevice.Format, area: Int, fps: Double)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width >= 640, dimensions.height >= 480,
                  dimensions.width <= 4096, dimensions.height <= 2160,
                  format.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= 29.97 }) else { return nil }
            return (format, Int(dimensions.width) * Int(dimensions.height),
                    format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }.max { lhs, rhs in lhs.area == rhs.area ? lhs.fps < rhs.fps : lhs.area < rhs.area }
        if let native {
            try dev.lockForConfiguration()
            dev.activeFormat = native.format
            let fps = native.fps >= 59.9 && native.area <= 1920 * 1080 ? 60 : 30
            let interval = CMTime(value: 1, timescale: CMTimeScale(fps))
            dev.activeVideoMinFrameDuration = interval
            dev.activeVideoMaxFrameDuration = interval
            dev.unlockForConfiguration()
            session.sessionPreset = .inputPriority
        } else {
            session.sessionPreset = .high
        }
        session.addInput(try AVCaptureDeviceInput(device: dev))
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: q)
        session.addOutput(out)
        session.commitConfiguration()
    }
    func start() { session.startRunning() }
    func stop() async {
        session.stopRunning()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in q.async { c.resume() } }
        guard started else { writer.cancelWriting(); return }
        input?.markAsFinished(); await writer.finishWriting()
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
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

/// Orchestrates prepare/start/stop. Never touches frames. (Pause/resume intentionally not implemented: needs PTS re-basing.)
public actor RecordingSession {
    private var engine: CaptureEngine?
    private var input: InputRecorder?
    private var webcam: WebcamRecorder?
    private var bundle: ProjectBundle?
    private var cfg: RecordingConfig?
    private var unit = EventTimeUnit.machTicks
    private var activity: NSObjectProtocol?
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
    }

    public func start() async throws {
        guard let engine, let input else { throw CaptureError.noSource }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                                                         reason: "Lumen recording")
        try await MainActor.run { try input.start() }
        webcam?.start()
        try await engine.start()
    }

    public func stats() -> CaptureStats {
        CaptureStats(elapsed: engine?.elapsed ?? 0, micLevel: engine?.mic?.level.withLock { $0 } ?? 0,
                     dropped: engine?.droppedFrames ?? 0, thermal: ProcessInfo.processInfo.thermalState.rawValue)
    }

    public func stop() async throws -> ProjectBundle {
        guard let engine, let input, let b = bundle, var info = engine.info else { throw CaptureError.noSource }
        defer { if let a = activity { ProcessInfo.processInfo.endActivity(a) } }
        await input.stop()
        await webcam?.stop()
        try await engine.stop()
        let origin = engine.firstPTS ?? 0
        info.duration = max(engine.lastPTS - origin, 0)
        var meta = ProjectMeta(name: b.url.deletingPathExtension().lastPathComponent, source: info,
                               clock: RecordingClock(originHostSeconds: origin, eventUnit: unit))
        meta.droppedFrames = engine.droppedFrames
        if let t = engine.mic?.first.withLock({ $0 }) { meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: t) }
        if let t = engine.system?.first.withLock({ $0 }) { meta.system = TrackMeta(file: "system.caf", startHostSeconds: t) }
        if let t = webcam?.first.withLock({ $0 }) { meta.webcam = TrackMeta(file: "webcam.mov", startHostSeconds: t) }
        var tl = Timeline(duration: info.duration)
        if meta.webcam != nil { tl.webcam = WebcamLayout() }
        try b.save(ProjectFile(meta: meta, timeline: tl))
        return b
    }
}
