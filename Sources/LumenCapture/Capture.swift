import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import VideoToolbox
import AppKit
import os
import LumenCore
import LumenProject

public enum CaptureError: Error { case noSource, writer(String) }

public struct RecordingConfig: Sendable {
    public enum Source: Sendable { case display(CGDirectDisplayID), window(CGWindowID), region(CGDirectDisplayID, CGRect) }
    public var source: Source
    public var fps = 60
    public var mic = true
    public var micDeviceID: String?
    /// Extra independent sources, e.g. BlackHole alongside a real microphone.
    /// The primary mic remains on ScreenCaptureKit's low-overhead audio path.
    public var additionalMicDeviceIDs: [String] = []
    public var systemAudio = false
    public var webcamDeviceID: String?
    public var webcamQuality: String = "auto"
    public init(source: Source) { self.source = source }
}

private struct AudioBox: @unchecked Sendable { let buf: AVAudioPCMBuffer }

/// Float32 PCM CAF writer. Owns its file; all file IO on a private serial queue.
public final class CAFWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private let q = DispatchQueue(label: "lumen.caf")
    public let level = OSAllocatedUnfairLock<Float>(initialState: 0)
    public let first = OSAllocatedUnfairLock<Double?>(initialState: nil)
    init(url: URL) { self.url = url }

    func append(_ sb: CMSampleBuffer, hostTime: Double? = nil) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        var d = asbd.pointee
        guard let fmt = AVAudioFormat(streamDescription: &d), fmt.commonFormat == .pcmFormatFloat32 else { return }
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        buf.frameLength = n
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList) == noErr else { return }
        if let ch = buf.floatChannelData?[0] {
            var s: Float = 0; for i in 0..<Int(n) { s += ch[i] * ch[i] }
            let rms = (s / Float(n)).squareRoot()
            level.withLock { $0 = rms }
        }
        let pts = hostTime ?? sb.presentationTimeStamp.seconds, box = AudioBox(buf: buf)
        q.async { [self] in
            if file == nil {
                // File and buffer processing formats must agree. Previously
                // forcing interleaved settings while using a planar writer
                // could fail silently and discard the captured microphone.
                let format = box.buf.format
                do {
                    file = try AVAudioFile(forWriting: url, settings: format.settings,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: format.isInterleaved)
                } catch {
                    NSLog("Lumen audio writer creation failed: %@", String(describing: error))
                    return
                }
                first.withLock { $0 = pts }
            }
            do {
                try file?.write(from: box.buf)
            } catch {
                NSLog("Lumen audio buffer write failed: %@", String(describing: error))
            }
        }
    }
    func close() { q.sync { file = nil } }

    /// Writes digital silence for a paused span so the audio track stays on the
    /// same wall clock as the video track after resume.
    func appendSilence(seconds: Double) {
        guard seconds > 0.01 else { return }
        q.async { [self] in
            guard let f = file else { return }
            let fmt = f.processingFormat
            var remaining = AVAudioFrameCount((seconds * fmt.sampleRate).rounded())
            while remaining > 0 {
                let n = min(remaining, 8192)
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
                buf.frameLength = n
                if let data = buf.floatChannelData {
                    for ch in 0..<Int(fmt.channelCount) { memset(data[ch], 0, Int(n) * MemoryLayout<Float>.size) }
                }
                try? f.write(from: buf)
                remaining -= n
            }
        }
    }
}

/// frames.meta: 32-byte records (pts, status, contentRect). Written from the video queue only.
final class FrameMetaWriter {
    private let fh: FileHandle
    private var buf: [UInt8] = []
    init(url: URL) throws { FileManager.default.createFile(atPath: url.path, contents: nil); fh = try FileHandle(forWritingTo: url) }
    func write(pts: Double, status: Int, rect: CGRect) {
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { buf.append(contentsOf: $0) } }
        put(pts.bitPattern); put(UInt32(status))
        for v in [rect.minX, rect.minY, rect.width, rect.height] { put(Float(v).bitPattern) }
        put(UInt32(0))
        if buf.count >= 1 << 16 { flush() }
    }
    func flush() { if !buf.isEmpty { try? fh.write(contentsOf: Data(buf)); buf.removeAll(keepingCapacity: true) } }
    func close() { flush(); try? fh.close() }
}

private struct PTSRange { var first: Double?; var last = 0.0 }

/// Records raw screen video (native pixels, HEVC) + audio tracks. Frames go straight from the SCK queue into the writer; no actor hops.
public final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public let bundle: ProjectBundle
    private let liveFrameHook = OSAllocatedUnfairLock<(@Sendable (CVPixelBuffer) -> Void)?>(initialState: nil)
    public func setLiveFrameHook(_ hook: (@Sendable (CVPixelBuffer) -> Void)?) { liveFrameHook.withLock { $0 = hook } }
    private let videoQ = DispatchQueue(label: "lumen.capture.video", qos: .userInteractive)
    private let audioQ = DispatchQueue(label: "lumen.capture.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var vin: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var started = false
    private var meta: FrameMetaWriter?
    private let dropped = OSAllocatedUnfairLock(initialState: 0)
    private let ptsRange = OSAllocatedUnfairLock(initialState: PTSRange())
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private let pauseMark = OSAllocatedUnfairLock<Double?>(initialState: nil)
    private let pauseLog = OSAllocatedUnfairLock<[PauseInterval]>(initialState: [])
    private let pausedTime = OSAllocatedUnfairLock<Double>(initialState: 0)
    public private(set) var mic: CAFWriter?
    public private(set) var system: CAFWriter?
    public private(set) var info: SourceInfo?

    public init(bundle: ProjectBundle) { self.bundle = bundle }
    public var droppedFrames: Int { dropped.withLock { $0 } }
    public var firstPTS: Double? { ptsRange.withLock { $0.first } }
    /// Spans that were deliberately not recorded, in engine seconds.
    public var pauseIntervals: [PauseInterval] { pauseLog.withLock { $0 } }
    public var elapsed: Double {
        ptsRange.withLock { $0.first.map { $0 > 0 ? max(HostClock.now() - $0 - pausedTime.withLock { $0 }, 0) : 0 } ?? 0 }
    }
    public var lastPTS: Double { ptsRange.withLock { $0.last } }

    /// Stops accepting frames and audio. The gap is cut out on stop, so a paused
    /// span never reaches the timeline — important when the user pauses to hide
    /// something that should not be recorded at all.
    public func pause() {
        guard !paused.withLock({ $0 }) else { return }
        pauseMark.withLock { $0 = HostClock.now() }
        paused.withLock { $0 = true }
    }

    public func resume() {
        guard paused.withLock({ $0 }) else { return }
        let now = HostClock.now()
        let start = pauseMark.withLock { s -> Double? in let value = s; s = nil; return value }
        paused.withLock { $0 = false }
        guard let start else { return }
        let span = max(now - start, 0)
        pauseLog.withLock { $0.append(PauseInterval(start: start, end: now)) }
        pausedTime.withLock { $0 += span }
        mic?.appendSilence(seconds: span)
        system?.appendSilence(seconds: span)
    }

    public func prepare(_ cfg: RecordingConfig) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
        let sc = SCStreamConfiguration()
        let filter: SCContentFilter
        var pw = 0, ph = 0, scale = 2.0, origin = CGPoint.zero, maxFPS = 60
        switch cfg.source {
        case .display(let id), .region(let id, _):
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noSource }
            filter = SCContentFilter(display: d, excludingWindows: own)
            if let m = CGDisplayCopyDisplayMode(id) { scale = Double(m.pixelWidth) / Double(m.width) }
            let b = CGDisplayBounds(id)
            var size = b.size; origin = b.origin
            if case .region(_, let r) = cfg.source {
                sc.sourceRect = r; size = r.size; origin = CGPoint(x: b.minX + r.minX, y: b.minY + r.minY)
            }
            pw = Int((size.width * scale).rounded()) & ~1; ph = Int((size.height * scale).rounded()) & ~1
            maxFPS = await MainActor.run {
                NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }?.maximumFramesPerSecond ?? 60
            }
        case .window(let wid):
            guard let w = content.windows.first(where: { $0.windowID == wid }) else { throw CaptureError.noSource }
            filter = SCContentFilter(desktopIndependentWindow: w)
            // A window can be captured on a non-Retina or secondary screen.
            // Use the backing scale of the display containing most of the window.
            let hostDisplay = content.displays.max { lhs, rhs in
                let a = CGDisplayBounds(lhs.displayID).intersection(w.frame)
                let b = CGDisplayBounds(rhs.displayID).intersection(w.frame)
                return a.width * a.height < b.width * b.height
            }
            if let id = hostDisplay?.displayID, let mode = CGDisplayCopyDisplayMode(id) {
                scale = Double(mode.pixelWidth) / Double(mode.width)
            } else {
                scale = 1
            }
            origin = w.frame.origin
            pw = Int((w.frame.width * scale).rounded()) & ~1
            ph = Int((w.frame.height * scale).rounded()) & ~1
        }
        let fps = min(cfg.fps, maxFPS)
        sc.width = pw; sc.height = ph
        sc.pixelFormat = kCVPixelFormatType_32BGRA
        sc.colorSpaceName = CGColorSpace.displayP3
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        sc.queueDepth = 8
        // Explicitly match the offline audio mixer and export rate.
        // Device-native microphone samples remain raw until the offline mix.
        sc.sampleRate = 48_000
        sc.channelCount = 2
        sc.showsCursor = false
        sc.scalesToFit = false
        sc.captureResolution = .best
        if cfg.systemAudio { sc.capturesAudio = true; sc.excludesCurrentProcessAudio = true }
        if cfg.mic { sc.captureMicrophone = true; if let id = cfg.micDeviceID { sc.microphoneCaptureDeviceID = id } }

        let w = try AVAssetWriter(outputURL: bundle.screenURL, fileType: .mov)
        let bitrate = min(Double(pw * ph) * Double(fps) * 0.12, 250_000_000)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: pw, AVVideoHeightKey: ph,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoMaxKeyFrameIntervalDurationKey: 0.5,
                                              AVVideoAllowFrameReorderingKey: false, AVVideoExpectedSourceFrameRateKey: fps,
                                              AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String],
        ]
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vi.expectsMediaDataInRealTime = true
        guard w.canAdd(vi) else { throw CaptureError.writer("cannot add video input") }
        w.add(vi)
        writer = w; vin = vi
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: nil)
        meta = try FrameMetaWriter(url: bundle.framesMetaURL)
        if cfg.mic { mic = CAFWriter(url: bundle.micURL) }
        if cfg.systemAudio { system = CAFWriter(url: bundle.systemURL) }
        info = SourceInfo(width: pw, height: ph, fps: Double(fps), duration: 0, backingScale: scale, originX: origin.x, originY: origin.y)

        let s = SCStream(filter: filter, configuration: sc, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQ)
        if cfg.systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQ) }
        if cfg.mic { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQ) }
        stream = s
    }

    public func start() async throws { try await stream?.startCapture() }

    public func stop() async throws {
        try await stream?.stopCapture()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            videoQ.async { if self.started { self.vin?.markAsFinished() }; c.resume() }
        }
        guard started, let w = writer else { writer?.cancelWriting(); throw CaptureError.writer("no frames were captured") }
        await w.finishWriting()
        meta?.close(); mic?.close(); system?.close()
        if w.status == .failed { throw CaptureError.writer(w.error?.localizedDescription ?? "writer failed") }
    }

    public func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, !paused.withLock({ $0 }) else { return }
        switch type {
        case .screen: video(sb)
        case .audio: system?.append(sb)
        case .microphone: mic?.append(sb)
        @unknown default: break
        }
    }
    public func stream(_ s: SCStream, didStopWithError error: Error) { NSLog("SCStream stopped: \(error)") }

    private func video(_ sb: CMSampleBuffer) {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = arr.first, let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb), let w = writer, let vin, let adaptor else { return }
        let pts = sb.presentationTimeStamp
        if !started {
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: pts); started = true
            ptsRange.withLock { $0.first = pts.seconds }
        }
        guard vin.isReadyForMoreMediaData else { dropped.withLock { $0 += 1 }; return }   // never block
        if adaptor.append(pb, withPresentationTime: pts) { ptsRange.withLock { $0.last = pts.seconds }; liveFrameHook.withLock { $0 }?(pb) }
        var rect = CGRect.zero
        if let d = info[.contentRect] as? [String: Any], let r = CGRect(dictionaryRepresentation: d as CFDictionary) { rect = r }
        meta?.write(pts: pts.seconds, status: raw, rect: rect)
    }
}
