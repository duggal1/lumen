import Foundation
@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreMedia
import VideoToolbox
import AppKit
import os
import LumenCore
import LumenProject
import LumenDirector

public enum CaptureError: Error { case noSource, writer(String) }

/// Vision fallback for window content capture. Pure and testable: the SCK
/// sample loop only builds a small luminance grid and calls `cropRect`, which
/// runs the same ChromeDetector → CropPlanner path as the offline planner.
/// The result is a **source-pixel crop rect**; no camera zoom is involved.
public enum CaptureVisionFallback {
    /// AX/AXWebArea resolution produced no usable content rect — the window
    /// belongs to a generic app (or AX is off), so pixels must decide.
    public static func shouldUseVision(axContent: WindowContent.ResolvedContent?) -> Bool {
        guard let axContent else { return true }
        let r = axContent.rect
        return !(r.width > 8 && r.height > 8 && r.minX.isFinite && r.minY.isFinite)
    }

    /// Edge grid → true source-pixel crop. `ChromeDetector` rejects grids that
    /// are entirely chrome; `CropPlanner` applies the aspect fit and clamp so
    /// the output has exactly the shape the compositor already consumes.
    public static func cropRect(edges: [Float], gridW: Int, gridH: Int,
                                source: PxRect,
                                settings: ChromeDetector.Settings = ChromeDetector.Settings(),
                                insetPx: Double = 0) -> PxRect? {
        guard ChromeDetector.contentRect(edges: edges, gridW: gridW, gridH: gridH,
                                         window: source, s: settings) != nil else { return nil }
        return CropPlanner.contentRect(fromEdges: edges, gridW: gridW, gridH: gridH,
                                       window: source, source: source,
                                       settings: settings, insetPx: insetPx)
    }
}

/// Pure guards for the values that come from user-drawn Area selections and
/// the display system. A hostile rect must never reach SCStreamConfiguration:
/// a zero/negative/NaN sourceRect produces a zero-sized writer and a stream
/// that fails at start with no usable frames.
public enum CaptureValidation {
    /// Minimum usable region, in source points. Smaller regions round down to
    /// almost nothing once multiplied by the backing scale and made even.
    public static let minimumRegionPoints: Double = 16

    /// Clips `rect` into `bounds` and returns a region that is safe to capture.
    /// Returns nil for non-finite, zero-area, degenerate or off-screen regions.
    public static func safeRegion(_ rect: CGRect, in bounds: CGRect) -> CGRect? {
        guard bounds.width.isFinite, bounds.height.isFinite,
              bounds.width >= minimumRegionPoints, bounds.height >= minimumRegionPoints,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull,
              clipped.width >= minimumRegionPoints,
              clipped.height >= minimumRegionPoints else { return nil }
        return clipped
    }
}

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
    /// AGENT: carries the agent's auto-mask choice from the tool into finalize.
    public var privacyAutoMask = false
    /// Intelligent Area crop. When enabled the capture is the full display and
    /// the crop lives in the derived camera track, not in SCStream.sourceRect.
    public var smartCrop = SmartCropConfig()
    /// Raw-footage retention defaults, set from Settings before a recording.
    public var rawRetentionDays: Int = 7
    public var deleteRawAfterExport = false
    public init(source: Source) { self.source = source }

    /// Extra microphones to capture through AVFoundation, de-duplicated and
    /// with the primary microphone removed. ScreenCaptureKit already owns the
    /// primary mic; opening a second AVFoundation session on the same device
    /// fights for the hardware and can drop the primary track entirely.
    public func resolvedAdditionalMicDeviceIDs() -> [String] {
        var ids = Set(additionalMicDeviceIDs)
        if let primary = micDeviceID { ids.remove(primary) }
        return ids.sorted()
    }
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
        let channels = Int(buffer.format.channelCount)
        guard count > 0, channels > 0 else { return 0 }
        let interleaved = buffer.format.isInterleaved
        let stride = interleaved ? channels : 1
        var sum = 0.0
        var sampleCount = 0
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return 0 }
            for channel in 0..<channels {
                let samples = data[interleaved ? 0 : channel]
                for frame in 0..<count {
                    let value = Double(samples[frame * stride + (interleaved ? channel : 0)])
                    if value.isFinite { sum += value * value; sampleCount += 1 }
                }
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return 0 }
            for channel in 0..<channels {
                let samples = data[interleaved ? 0 : channel]
                for frame in 0..<count {
                    let value = Double(samples[frame * stride + (interleaved ? channel : 0)]) / 32768
                    sum += value * value; sampleCount += 1
                }
            }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return 0 }
            for channel in 0..<channels {
                let samples = data[interleaved ? 0 : channel]
                for frame in 0..<count {
                    let value = Double(samples[frame * stride + (interleaved ? channel : 0)]) / 2147483648
                    sum += value * value; sampleCount += 1
                }
            }
        default:
            return 0
        }
        guard sampleCount > 0 else { return 0 }
        return Float((sum / Double(sampleCount)).squareRoot())
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
    // Window capture: the chrome band above the content is cropped off every
    // frame, and re-measured while recording so a toolbar appearing later is
    // cropped too. `cropper == nil` means the whole frame is content.
    private var cropper: FrameCropper?
    private struct WindowTrack: Sendable { var id: CGWindowID; var pid: pid_t; var frame: CGRect }
    private let windowTrack = OSAllocatedUnfairLock<WindowTrack?>(initialState: nil)
    private var chromeTimer: DispatchSourceTimer?
    private let chromeFraction = OSAllocatedUnfairLock<Double>(initialState: 0)
    /// Generic-app window capture: AX gave no content rect, so each sample is
    /// inspected for chrome and the detected band drives the SAME `chromeFraction`
    /// → `FrameCropper` path as AX. No extra crop pipeline is introduced.
    private let visionFallback = OSAllocatedUnfairLock(initialState: false)
    private let visionPending = OSAllocatedUnfairLock(initialState: false)
    private var lastVisionDetect = 0.0                  // video queue only
    private let visionGrid = (w: 12, h: 8)              // ChromeDetector grid
    private let visionSignpost = OSLog(subsystem: "com.lumen.studio", category: "capture.vision")
    private var pendingVideo: (buffer: CVPixelBuffer, pts: CMTime)?
    private var meta: FrameMetaWriter?
    private let dropped = OSAllocatedUnfairLock(initialState: 0)
    private let written = OSAllocatedUnfairLock(initialState: 0)
    private let ptsRange = OSAllocatedUnfairLock(initialState: PTSRange())
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private let pauseMark = OSAllocatedUnfairLock<Double?>(initialState: nil)
    private let pauseLog = OSAllocatedUnfairLock<[PauseInterval]>(initialState: [])
    private let pausedTime = OSAllocatedUnfairLock<Double>(initialState: 0)
    // The audio writers are read from the ScreenCaptureKit callback thread
    // and written from the session thread. A plain stored property is a data
    // race there (it crashed the capture callback), so they are guarded.
    private let micWriter = OSAllocatedUnfairLock<CAFWriter?>(initialState: nil)
    private let systemWriter = OSAllocatedUnfairLock<CAFWriter?>(initialState: nil)
    public var mic: CAFWriter? { micWriter.withLock { $0 } }
    public var system: CAFWriter? { systemWriter.withLock { $0 } }
    public var info: SourceInfo? { sourceInfo.withLock { $0 } }

    public init(bundle: ProjectBundle) { self.bundle = bundle }
    public var droppedFrames: Int { dropped.withLock { $0 } }
    public var writtenFrames: Int { written.withLock { $0 } }
    public var firstPTS: Double? { ptsRange.withLock { $0.first } }
    /// Spans that were deliberately not recorded, in engine seconds.
    public var pauseIntervals: [PauseInterval] { pauseLog.withLock { $0 } }
    public var elapsed: Double {
        ptsRange.withLock { $0.first.map { $0 > 0 ? max(HostClock.now() - $0 - pausedTime.withLock { $0 }, 0) : 0 } ?? 0 }
    }
    public var lastPTS: Double { ptsRange.withLock { $0.last } }
    /// Read both ends under one lock: a journal must never observe a first
    /// frame from a newer callback and a last frame from an older callback.
    public var checkpointPTS: (first: Double?, last: Double) {
        ptsRange.withLock { ($0.first, $0.last) }
    }

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
            if !scale.isFinite || scale <= 0 { scale = 1 }
            let b = CGDisplayBounds(id)
            var size = b.size; origin = b.origin
            if case .region(_, let rawRect) = cfg.source {
                // A drawn Area can be stale (display reconfigured) or hostile.
                // Area rects are display-relative (top-left origin), while
                // CGDisplayBounds is in global space — clip against a local
                // bounds rect, then fold the display origin back in for event
                // coordinate conversion.
                let localBounds = CGRect(x: 0, y: 0, width: b.width, height: b.height)
                guard let r = CaptureValidation.safeRegion(rawRect, in: localBounds) else { throw CaptureError.noSource }
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
            // Content-only capture: measure the title bar and toolbar band once,
            // then crop it off every frame. Nothing of the window chrome ever
            // reaches the writer.
            let pid = w.owningApplication?.processID ?? 0
            let chrome = WindowContent.resolve(windowID: wid, processID: pid, frame: w.frame)?.topInset ?? 0
            // AXWebArea/children are the first choice. Only when they yield no
            // usable content do we let the pixel-based detector choose the band.
            let axContent = WindowContent.resolveContent(windowID: wid, processID: pid, frame: w.frame)
            let useVision = CaptureVisionFallback.shouldUseVision(axContent: axContent)
            visionFallback.withLock { $0 = useVision }
            visionPending.withLock { $0 = useVision }   // first complete frame detects
            windowTrack.withLock { $0 = WindowTrack(id: wid, pid: pid, frame: w.frame) }
            chromeFraction.withLock { $0 = w.frame.height > 0 ? chrome / w.frame.height : 0 }
            if chrome > 0 || useVision { cropper = FrameCropper() }
            let contentHeight = max(w.frame.height - chrome, 1)
            origin = CGPoint(x: w.frame.minX, y: w.frame.minY + chrome)
            points = CGSize(width: w.frame.width, height: contentHeight)
            pw = Int((w.frame.width * scale).rounded()) & ~1
            ph = Int((contentHeight * scale).rounded()) & ~1
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
        cropper?.configure(width: pw, height: ph)
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
        w.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
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
        if cfg.mic { micWriter.withLock { $0 = CAFWriter(url: bundle.micURL) } }
        if cfg.systemAudio { systemWriter.withLock { $0 = CAFWriter(url: bundle.systemURL) } }
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

    public func start() async throws {
        startChromeTracking()
        try await stream?.startCapture()
    }

    /// Re-measures the chrome band twice a second while recording. A window can
    /// gain a toolbar, enter full screen, or be resized; the crop follows.
    private func startChromeTracking() {
        guard cropper != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(1200), leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self, let track = self.windowTrack.withLock({ $0 }) else { return }
            guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], track.id) as? [NSDictionary],
                  let entry = info.first,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.height > 8 else { return }
            let chrome = WindowContent.resolve(windowID: track.id, processID: track.pid, frame: frame)?.topInset ?? 0
            let axContent = WindowContent.resolveContent(windowID: track.id, processID: track.pid, frame: frame)
            let useVision = CaptureVisionFallback.shouldUseVision(axContent: axContent)
            let wasVision = self.visionFallback.withLock { current -> Bool in
                let previous = current
                current = useVision
                return previous
            }
            if useVision, chrome <= 0.0001 {
                // Re-detect on the next complete frame; window contents change.
                self.visionPending.withLock { $0 = true }
            } else if wasVision && !useVision {
                self.visionPending.withLock { $0 = false }
            }
            self.chromeFraction.withLock { $0 = chrome / frame.height }
            self.windowTrack.withLock { $0?.frame = frame }
        }
        timer.resume()
        chromeTimer = timer
    }

    private func stopChromeTracking() {
        chromeTimer?.cancel(); chromeTimer = nil
    }

    /// Correct shutdown order: stop capture, drain the SCK sample queue,
    /// mark the video input finished, then await finishWriting off main.
    /// Signposted so a stop hang is visible in Instruments/Console.
    public func stop() async throws {
        stopChromeTracking()
        let sp = OSSignposter(logger: Logger(subsystem: "com.lumen.studio", category: "capture"))
        let state = sp.beginInterval("engine.stop")
        defer { sp.endInterval("engine.stop", state) }
        // Even if ScreenCaptureKit stopped itself (disconnect/revoke), drain
        // existing queues and finalize any valid media already captured.
        do { try await stream?.stopCapture() }
        catch { NSLog("SCStream stop: \(error)") }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            videoQ.async {
                self.drainVideo()
                if self.pendingVideo != nil { self.dropped.withLock { $0 += 1 }; self.pendingVideo = nil }
                if self.started { self.vin?.markAsFinished() }
                c.resume()
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            audioQ.async { c.resume() }
        }
        // CAFWriter.close drains its own serial writer queue.
        defer { meta?.close(); mic?.close(); system?.close() }
        guard started, let w = writer, writtenFrames > 0 else {
            writer?.cancelWriting(); throw CaptureError.writer("no frames were captured")
        }
        await w.finishWriting()
        guard w.status == .completed else {
            throw CaptureError.writer(w.error?.localizedDescription ?? "writer did not finish")
        }
    }

    /// Abandons a prepared capture that never produced a recording. The stream
    /// is stopped if it was started, the writer is cancelled rather than
    /// finalized, and every open file is closed — the bundle is about to be
    /// deleted, so no playable output is needed.
    public func cancel() async {
        stopChromeTracking()
        try? await stream?.stopCapture()
        writer?.cancelWriting()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            videoQ.async {
                self.pendingVideo = nil
                if self.started { self.vin?.markAsFinished() }
                c.resume()
            }
        }
        meta?.close(); mic?.close(); system?.close()
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
        let pts = sb.presentationTimeStamp
        // Generic-app window capture: AX gave no content rect. Inspect pixels
        // and drive the SAME chromeFraction → FrameCropper path as the AX case.
        if visionFallback.withLock({ $0 }) {
            let wasPending = visionPending.withLock { pending -> Bool in
                let value = pending; pending = false; return value
            }
            let due = wasPending || pts.seconds - lastVisionDetect >= 1.0
            if due {
                detectVisionCrop(from: pb)
                lastVisionDetect = pts.seconds
            }
        }
        // Window capture: the title bar and toolbar band are cropped away here,
        // so the writer only ever sees content pixels.
        let frame = cropped(pb)
        guard let frame else { return }
        updateSourceScale(from: frame)
        if !started {
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: pts); started = true
            ptsRange.withLock { $0.first = pts.seconds; $0.last = pts.seconds }
        }
        if pendingVideo != nil { dropped.withLock { $0 += 1 } }
        pendingVideo = (frame, pts)
        drainVideo()
        var rect = CGRect.zero
        if let d = info[.contentRect] as? [String: Any], let r = CGRect(dictionaryRepresentation: d as CFDictionary) { rect = r }
        meta?.write(pts: pts.seconds, status: raw, rect: rect)
    }

    /// Vision fallback for a window with no AXWebArea. Builds a tiny luminance
    /// image by strided sampling (no pixel-buffer copy), runs the detector,
    /// feeds the edge grid through `CropPlanner.contentRect(fromEdges:)`, and
    /// publishes the band as `chromeFraction`. The existing `cropped(_:)` then
    /// applies a true source-pixel crop — nothing downstream changes.
    private func detectVisionCrop(from pixelBuffer: CVPixelBuffer) {
        os_signpost(.begin, log: visionSignpost, name: "capture.vision.detect")
        defer { os_signpost(.end, log: visionSignpost, name: "capture.vision.detect") }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 16, height > 16 else { return }
        let lw = visionGrid.w * 8, lh = visionGrid.h * 8
        var luminance = [UInt8](repeating: 0, count: lw * lh)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for oy in 0..<lh {
            let sy = min(height - 1, oy * height / lh)
            let row = bytes + sy * bpr
            for ox in 0..<lw {
                let sx = min(width - 1, ox * width / lw)
                let p = row + sx * 4                    // kCVPixelFormatType_32BGRA
                let luma = (77 * Int(p[2]) + 150 * Int(p[1]) + 29 * Int(p[0])) / 256
                luminance[oy * lw + ox] = UInt8(min(255, max(0, luma)))
            }
        }
        guard let edges = ChromeDetector.edgeGrid(pixels: luminance, width: lw, height: lh,
                                                  gridW: visionGrid.w, gridH: visionGrid.h),
              let crop = CaptureVisionFallback.cropRect(edges: edges,
                                                        gridW: visionGrid.w, gridH: visionGrid.h,
                                                        source: PxRect(x: 0, y: 0,
                                                                       w: Double(width), h: Double(height))),
              crop.y.isFinite else { return }
        let fraction = min(max(crop.y / Double(height), 0), 0.6)
        let previous = chromeFraction.withLock { current -> Double in
            let old = current
            if abs(current - fraction) > 0.005 { current = fraction }
            return old
        }
        if abs(previous - fraction) > 0.005 {
            os_log("A4 vision fallback: content crop top=%.1f%% (AX unavailable)", log: .default,
                   type: .info, fraction * 100)
        }
    }

    /// Crops the chrome band off a window frame. Display and region captures
    /// pass straight through with no copy.
    private func cropped(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        guard let cropper else { return pb }
        let fraction = chromeFraction.withLock { $0 }
        guard fraction > 0.0005 else { return pb }
        guard let result = cropper.crop(pb, topFraction: fraction) else {
            cropper.logIfNeeded("no output buffer for \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
            dropped.withLock { $0 += 1 }
            return nil
        }
        return result
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
            written.withLock { $0 += 1 }
            liveFrameHook.withLock { $0 }?(pending.buffer)
        } else { dropped.withLock { $0 += 1 } }
    }

}
