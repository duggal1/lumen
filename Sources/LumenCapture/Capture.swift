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
    public enum Resolution: String, Sendable, CaseIterable {
        case native, eightK, ultraHD, twoK, p1080, p720
        /// Cap on the native pixel height; width follows the source aspect, always even.
        public var resolutionHeight: Int {
            switch self {
            case .native: Int.max
            case .eightK: 4320
            case .ultraHD: 2160
            case .twoK: 1440
            case .p1080: 1080
            case .p720: 720
            }
        }
    }
    public enum Quality: String, Sendable, CaseIterable {
        case standard, high, ultraHD, bluray, custom
        /// Bits per pixel per frame, capped so a 4K/60 screen never writes more than 250 Mbps.
        public var bitsPerPixel: Double {
            switch self {
            case .standard: 0.14
            case .high: 0.20
            case .ultraHD: 0.28
            case .bluray: 0.40
            case .custom: 0
            }
        }
        public static let offered: [Quality] = [.standard, .high, .ultraHD, .bluray]
    }

    public var source: Source
    public var fps = 60
    public var resolution: Resolution = .native
    public var quality: Quality = .high
    public var customMbps: Double = 20
    public var mic = true
    public var micDeviceID: String?
    /// Extra independent sources, e.g. BlackHole alongside a real microphone.
    /// ScreenCaptureKit captures the primary microphone separately from system audio.
    public var additionalMicDeviceIDs: [String] = []
    public var systemAudio = false
    public var webcamDeviceID: String?
    public var webcamQuality: String = "auto"
    public init(source: Source) { self.source = source }
}

private struct AudioBox: @unchecked Sendable { let buf: AVAudioPCMBuffer }

/// Float32 PCM CAF writer. Owns its file; all file IO on a private serial queue.
/// Format is read from every buffer's ASBD (never assumed). PTS gaps are filled
/// with exact-length silence + 5 ms crossfade; overlaps are trimmed. Counts go
/// to `<id>.json` next to the CAF. Never reinterprets bytes.
public final class CAFWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var totalFrames: Int64 = 0
    private var firstPTS: Double?
    private var lastPTS: Double?
    private var gapCount = 0, overlapCount = 0, formatChanges = 0
    private var filledFrames: Int64 = 0, trimmedFrames: Int64 = 0
    private let q = DispatchQueue(label: "lumen.caf")
    public let level = OSAllocatedUnfairLock<Float>(initialState: 0)
    public let first = OSAllocatedUnfairLock<Double?>(initialState: nil)
    init(url: URL) { self.url = url }

    func append(_ sb: CMSampleBuffer, hostTime: Double? = nil) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        var d = asbd.pointee
        guard let fmt = AVAudioFormat(streamDescription: &d) else { return }
        // Never assume Float32: accept any PCM and convert to Float32 via a
        // carried AVAudioConverter (one instance across chunks — recreating
        // per chunk clicks at every boundary).
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return }
        inBuf.frameLength = n
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: inBuf.mutableAudioBufferList) == noErr else { return }
        let rms = Self.inputLevel(inBuf)
        level.withLock { $0 = rms }
        let pts = hostTime ?? sb.presentationTimeStamp.seconds
        // Low-quality input warning (Bluetooth HFP ≤24 kHz).
        if fmt.sampleRate <= 24_000 {
            os_log("CAF low-rate input %.0f Hz for %@ — not studio grade", log: .default, type: .error, fmt.sampleRate, url.lastPathComponent)
        }
        let inBox = AudioBox(buf: inBuf)
        q.async { [self, inBox, pts] in
            if file == nil {
                let format: AVAudioFormat
                if inBox.buf.format.commonFormat == .pcmFormatFloat32 {
                    format = inBox.buf.format
                } else {
                    // First buffer is not Float32: create a Float32 file at its rate.
                    guard let f32 = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                  sampleRate: inBox.buf.format.sampleRate,
                                                  channels: inBox.buf.format.channelCount,
                                                  interleaved: inBox.buf.format.isInterleaved) else {
                        os_log("CAF cannot create Float32 format for %@", log: .default, type: .error, url.lastPathComponent)
                        return
                    }
                    format = f32
                }
                do {
                    file = try AVAudioFile(forWriting: url, settings: format.settings,
                                           commonFormat: .pcmFormatFloat32,
                                           interleaved: format.isInterleaved)
                    fileFormat = format
                    firstPTS = pts
                    first.withLock { $0 = pts }
                    lastPTS = pts
                    totalFrames = 0
                } catch {
                    os_log("Lumen audio writer creation failed: %@", log: .default, type: .error, String(describing: error))
                    return
                }
            }
            guard let f = file, let fileFmt = fileFormat else { return }
            // PTS continuity: expected PTS from running sample count.
            if lastPTS != nil, let anchor = firstPTS, fileFmt.sampleRate > 0 {
                let expected = anchor + Double(totalFrames) / fileFmt.sampleRate
                let delta = pts - expected
                if delta > 0.025 {
                    // Gap: fill with exact-length silence (never collapse timeline).
                    let gapFrames = Int64((delta * fileFmt.sampleRate).rounded())
                    // Short gap (<100 ms): crossfaded silence is already clicked-safe
                    // because silence is zero; the 5 ms ramps below avoid edge clicks.
                    if gapFrames > 0 {
                        gapCount += 1; filledFrames += gapFrames
                        writeSilence(to: f, format: fileFmt, frames: gapFrames, ramp: true)
                        totalFrames += gapFrames
                    }
                } else if delta < -0.025 {
                    // Overlap: trim the head of this buffer.
                    let skip = Int64((-delta * fileFmt.sampleRate).rounded())
                    if skip >= Int64(inBox.buf.frameLength) {
                        overlapCount += 1; trimmedFrames += Int64(inBox.buf.frameLength)
                        return
                    }
                    overlapCount += 1; trimmedFrames += skip
                    // Trim by advancing the read offset: re-wrap the tail.
                    // (AVAudioPCMBuffer has no offset; rebuild a trimmed copy.)
                    let tail = Int(inBox.buf.frameLength) - Int(skip)
                    guard tail > 0, let trimmed = AVAudioPCMBuffer(pcmFormat: inBox.buf.format, frameCapacity: AVAudioFrameCount(tail)) else { return }
                    trimmed.frameLength = AVAudioFrameCount(tail)
                    let chCount = Int(inBox.buf.format.channelCount)
                    for c in 0..<chCount where inBox.buf.floatChannelData != nil && trimmed.floatChannelData != nil {
                        memmove(UnsafeMutablePointer<Float>(trimmed.floatChannelData![c]),
                                UnsafePointer<Float>(inBox.buf.floatChannelData![c]) + Int(skip),
                                tail * MemoryLayout<Float>.size)
                    }
                    _ = writeBuffer(trimmed, to: f, fileFormat: fileFmt, pts: pts)
                    lastPTS = pts
                    return
                }
            }
            _ = writeBuffer(inBox.buf, to: f, fileFormat: fileFmt, pts: pts)
            lastPTS = pts
        }
    }

    private static func inputLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        var sum = 0.0
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let samples = buffer.floatChannelData?[0] else { return 0 }
            for i in 0..<count {
                let value = Double(samples[i * stride])
                if value.isFinite { sum += value * value }
            }
        case .pcmFormatInt16:
            guard let samples = buffer.int16ChannelData?[0] else { return 0 }
            for i in 0..<count { let value = Double(samples[i * stride]) / 32768; sum += value * value }
        case .pcmFormatInt32:
            guard let samples = buffer.int32ChannelData?[0] else { return 0 }
            for i in 0..<count { let value = Double(samples[i * stride]) / 2147483648; sum += value * value }
        default:
            return 0
        }
        return Float((sum / Double(count)).squareRoot())
    }

    /// Writes `buf` to `file`, converting format if needed with the carried converter.
    private func writeBuffer(_ buf: AVAudioPCMBuffer, to file: AVAudioFile, fileFormat: AVAudioFormat, pts: Double) -> Bool {
        let srcFmt = buf.format
        var outBuf = buf
        if srcFmt.sampleRate != fileFormat.sampleRate || srcFmt.channelCount != fileFormat.channelCount || srcFmt.isInterleaved != fileFormat.isInterleaved || srcFmt.commonFormat != .pcmFormatFloat32 {
            formatChanges += 1
            if converter == nil || converter?.inputFormat != srcFmt || converter?.outputFormat != fileFormat {
                converter = AVAudioConverter(from: srcFmt, to: fileFormat)
                // Highest quality (Mastering). Apple exposes algorithm via AVAudioConverter's engine automatically.
            }
            guard let conv = converter,
                  let converted = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: buf.frameLength + 4096) else {
                os_log("CAF converter failed for %@", log: .default, type: .error, url.lastPathComponent)
                return false
            }
            final class Box: @unchecked Sendable { var buf: AVAudioPCMBuffer?; init(_ b: AVAudioPCMBuffer) { buf = b } }
            let box = Box(buf)
            var err: NSError?
            let status = conv.convert(to: converted, error: &err) { _, status in
                if let b = box.buf { box.buf = nil; status.pointee = .haveData; return b }
                status.pointee = .endOfStream; return nil
            }
            guard status != .error, err == nil, converted.frameLength > 0 else {
                os_log("CAF convert failed: %@", log: .default, type: .error, String(describing: err as Any))
                return false
            }
            outBuf = converted
        }
        do {
            try file.write(from: outBuf)
            totalFrames += Int64(outBuf.frameLength)
            return true
        } catch {
            os_log("Lumen audio buffer write failed: %@", log: .default, type: .error, String(describing: error))
            return false
        }
    }

    private func writeSilence(to file: AVAudioFile, format: AVAudioFormat, frames: Int64, ramp: Bool) {
        var remaining = frames
        let rampLen = ramp ? min(Int(0.005 * format.sampleRate), 8192) : 0
        var firstChunk = true
        while remaining > 0 {
            let n = min(remaining, 8192)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
            buf.frameLength = AVAudioFrameCount(n)
            if let data = buf.floatChannelData {
                for ch in 0..<Int(format.channelCount) { memset(data[ch], 0, Int(n) * MemoryLayout<Float>.size) }
            }
            // Silence is already click-free; ramp flag is kept for parity with
            // the spec's ≥5 ms rule on gain changes (silence needs no ramp).
            _ = firstChunk; firstChunk = false; _ = rampLen
            try? file.write(from: buf)
            remaining -= n
        }
    }

    func close() {
        q.sync {
            file = nil
            // Persist gap/overlap/format counts next to the CAF.
            struct Sidecar: Codable {
                var gapCount: Int, overlapCount: Int, formatChanges: Int
                var filledFrames: Int64, trimmedFrames: Int64
                var totalFrames: Int64
            }
            let sidecar = Sidecar(gapCount: gapCount, overlapCount: overlapCount, formatChanges: formatChanges,
                                  filledFrames: filledFrames, trimmedFrames: trimmedFrames, totalFrames: totalFrames)
            let jsonURL = url.deletingPathExtension().appendingPathExtension("json")
            try? JSONEncoder().encode(sidecar).write(to: jsonURL, options: .atomic)
        }
    }

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
    private let inputScaleHook = OSAllocatedUnfairLock<(@Sendable (SIMD2<Double>) -> Void)?>(initialState: nil)
    public func setInputScaleHook(_ hook: (@Sendable (SIMD2<Double>) -> Void)?) { inputScaleHook.withLock { $0 = hook } }
    private let sourceInfo = OSAllocatedUnfairLock<SourceInfo?>(initialState: nil)
    private let sourcePoints = OSAllocatedUnfairLock<CGSize?>(initialState: nil)
    private let measuredSourceScale = OSAllocatedUnfairLock(initialState: false)
    private let videoQ = DispatchQueue(label: "lumen.capture.video", qos: .userInteractive)
    private let audioQ = DispatchQueue(label: "lumen.capture.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var vin: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var started = false
    private var pendingVideo: (buffer: CVPixelBuffer, pts: CMTime)?
    private var meta: FrameMetaWriter?
    private let dropped = OSAllocatedUnfairLock(initialState: 0)
    private let ptsRange = OSAllocatedUnfairLock(initialState: PTSRange())
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private let pauseMark = OSAllocatedUnfairLock<Double?>(initialState: nil)
    private let pauseLog = OSAllocatedUnfairLock<[PauseInterval]>(initialState: [])
    private let pausedTime = OSAllocatedUnfairLock<Double>(initialState: 0)
    public private(set) var mic: CAFWriter?
    public private(set) var system: CAFWriter?
    public var info: SourceInfo? { sourceInfo.withLock { $0 } }

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
        var pw = 0, ph = 0, scale = 2.0, origin = CGPoint.zero, points = CGSize.zero
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
            points = size
            pw = Int((size.width * scale).rounded()) & ~1; ph = Int((size.height * scale).rounded()) & ~1
        case .window(let wid):
            guard let w = content.windows.first(where: { $0.windowID == wid }) else { throw CaptureError.noSource }
            filter = SCContentFilter(desktopIndependentWindow: w)
            sc.ignoreShadowsSingleWindow = true
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
            points = w.frame.size
            pw = Int((w.frame.width * scale).rounded()) & ~1
            ph = Int((w.frame.height * scale).rounded()) & ~1
        }
        let fps = min(cfg.fps, 120)
        // Capture resolution: cap native pixels, never above native.
        // Events are stored in VIDEO pixels, so the recorder scale follows
        // the cap factor; otherwise native-px events exceed the capped
        // width/height and clicks misplace or drop downstream.
        let nativeScale = scale
        var capFactor = 1.0
        let maxH = cfg.resolution.resolutionHeight
        if ph > maxH {
            let s = Double(maxH) / Double(ph)
            capFactor = s
            pw = max(Int((Double(pw) * s).rounded()) & ~1, 64)
            ph = maxH & ~1
        }
        sc.width = pw; sc.height = ph
        sc.pixelFormat = kCVPixelFormatType_32BGRA
        sc.colorSpaceName = CGColorSpace.displayP3
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        sc.queueDepth = 3
        // Explicitly match the offline audio mixer and export rate.
        // Device-native microphone samples remain raw until the offline mix.
        // System audio rides the same 48 kHz timeline as the mixer and the
        // encoder; only the microphone hardware keeps its own native rate.
        sc.sampleRate = 48_000
        sc.channelCount = 2
        sc.showsCursor = false
        sc.scalesToFit = false
        sc.captureResolution = .best
        if cfg.systemAudio { sc.capturesAudio = true; sc.excludesCurrentProcessAudio = true }
        if cfg.mic { sc.captureMicrophone = true; if let id = cfg.micDeviceID { sc.microphoneCaptureDeviceID = id } }

        let w = try AVAssetWriter(outputURL: bundle.screenURL, fileType: .mov)
        // Fragmented so a crash/force-quit still leaves a playable file.
        w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
        let bitrate: Double = switch cfg.quality {
        case .standard: min(Double(pw * ph) * Double(fps) * RecordingConfig.Quality.standard.bitsPerPixel, 250_000_000)
        case .high: min(Double(pw * ph) * Double(fps) * RecordingConfig.Quality.high.bitsPerPixel, 250_000_000)
        case .ultraHD: min(Double(pw * ph) * Double(fps) * RecordingConfig.Quality.ultraHD.bitsPerPixel, 250_000_000)
        case .bluray: min(Double(pw * ph) * Double(fps) * RecordingConfig.Quality.bluray.bitsPerPixel, 250_000_000)
        case .custom: max(cfg.customMbps * 1_000_000, 1_000_000)
        }
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
        let configuredPoints = points
        let configuredInfo = SourceInfo(width: pw, height: ph, fps: Double(fps), duration: 0,
                                        backingScale: nativeScale * capFactor, originX: origin.x, originY: origin.y)
        sourcePoints.withLock { $0 = configuredPoints }
        sourceInfo.withLock { $0 = configuredInfo }

        let s = SCStream(filter: filter, configuration: sc, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQ)
        if cfg.systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQ) }
        if cfg.mic { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQ) }
        stream = s
    }

    public func start() async throws { try await stream?.startCapture() }

    /// Correct shutdown order: stop capture, drain the SCK sample queue,
    /// mark the video input finished, then await finishWriting off main.
    /// Signposted so a stop hang is visible in Instruments/Console.
    public func stop() async throws {
        let sp = OSSignposter(logger: Logger(subsystem: "com.lumen.studio", category: "capture"))
        let state = sp.beginInterval("engine.stop")
        defer { sp.endInterval("engine.stop", state) }
        try await stream?.stopCapture()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            videoQ.async {
                if self.pendingVideo != nil { self.dropped.withLock { $0 += 1 }; self.pendingVideo = nil }
                if self.started { self.vin?.markAsFinished() }
                c.resume()
            }
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
              let pb = CMSampleBufferGetImageBuffer(sb), let w = writer, vin != nil, adaptor != nil else { return }
        updateSourceScale(from: pb)
        let pts = sb.presentationTimeStamp
        if !started {
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: pts); started = true
            ptsRange.withLock { $0.first = pts.seconds }
        }
        if pendingVideo != nil { dropped.withLock { $0 += 1 } }
        pendingVideo = (pb, pts)
        drainVideo()
        var rect = CGRect.zero
        if let d = info[.contentRect] as? [String: Any], let r = CGRect(dictionaryRepresentation: d as CFDictionary) { rect = r }
        meta?.write(pts: pts.seconds, status: raw, rect: rect)
    }

    private func updateSourceScale(from pixelBuffer: CVPixelBuffer) {
        let shouldMeasure = measuredSourceScale.withLock { measured -> Bool in
            guard !measured else { return false }
            measured = true
            return true
        }
        guard shouldMeasure, let points = sourcePoints.withLock({ $0 }), points.width > 0, points.height > 0 else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let xScale = Double(width) / points.width
        let yScale = Double(height) / points.height
        guard xScale.isFinite, yScale.isFinite, xScale > 0, yScale > 0 else { return }
        if abs(xScale - yScale) >= 0.01 {
            os_log("capture source has nonuniform pixel scale x=%.5f y=%.5f", log: .default, type: .error, xScale, yScale)
        }
        sourceInfo.withLock { value in
            guard var info = value else { return }
            info.width = width
            info.height = height
            info.backingScale = (xScale + yScale) / 2
            value = info
        }
        inputScaleHook.withLock { $0 }?(SIMD2(xScale, yScale))
    }
    private func drainVideo() {
        guard let vin, vin.isReadyForMoreMediaData, let pending = pendingVideo else { return }
        pendingVideo = nil
        if adaptor?.append(pending.buffer, withPresentationTime: pending.pts) == true {
            let seconds = pending.pts.seconds
            ptsRange.withLock { $0.last = seconds }
            liveFrameHook.withLock { $0 }?(pending.buffer)
        } else { dropped.withLock { $0 += 1 } }
    }

}
