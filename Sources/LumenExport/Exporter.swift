import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio

public enum ExportError: Error { case writer(String), render, noTimeline }
public struct ExportProgress: Sendable {
    public var frame: Int, total: Int, notice: String?
    public init(frame: Int, total: Int, notice: String?) { self.frame = frame; self.total = total; self.notice = notice }
}

/// Await-able GPU completion.
final class Latch: @unchecked Sendable {
    private let s = OSAllocatedUnfairLock<(done: Bool, c: CheckedContinuation<Void, Never>?)>(uncheckedState: (false, nil))
    func fire() { let c = s.withLock { st -> CheckedContinuation<Void, Never>? in st.done = true; let c = st.c; st.c = nil; return c }; c?.resume() }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = s.withLock { st -> Bool in if st.done { return true }; st.c = c; return false }
            if now { c.resume() }
        }
    }
}

public enum FrameImage {
    public static func makeBuffer(_ w: Int, _ h: Int, format: OSType = kCVPixelFormatType_32BGRA) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, format, [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &pb)
        return pb
    }
    public static func cgImage(_ pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let c = CGContext(data: base, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), bitsPerComponent: 8,
                          bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.displayP3)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return c?.makeImage()
    }
    /// One frame, fully rendered (CLI `frame`, GIF, cursor sidecar).
    public static func render(renderer: Renderer, session: ProjectSession, timeline tl: Timeline, t: Double, canvas: SIMD2<Int>,
                              fps: Double = 60, transparent: Bool = false, cursorOnly: Bool = false) async throws -> CVPixelBuffer {
        let (sf, wf) = try await session.frames(atOutput: t, timeline: tl)
        guard let pb = makeBuffer(canvas.x, canvas.y) else { throw ExportError.render }
        let latch = Latch()
        let req = RenderRequest(timeline: tl, t: t, screen: sf, webcam: wf, canvas: canvas, fps: fps,
                                backingScale: session.meta.source.backingScale,
                                personMaskDirectory: session.bundle.cacheURL.appendingPathComponent("analysis", isDirectory: true),
                                transparent: transparent, cursorOnly: cursorOnly)
        guard renderer.render(req, into: pb, completion: { latch.fire() }) else { throw ExportError.render }
        await latch.wait(); return pb
    }
    public static func writePNG(_ pb: CVPixelBuffer, to url: URL) throws {
        guard let img = cgImage(pb), let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ExportError.render }
        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    }
}

private final class AudioFeeder: @unchecked Sendable {
    let reader: AVAssetReader, out: AVAssetReaderTrackOutput, input: AVAssetWriterInput, done = Latch()
    init(_ r: AVAssetReader, _ o: AVAssetReaderTrackOutput, _ i: AVAssetWriterInput) { reader = r; out = o; input = i }
    func start(on q: DispatchQueue) {
        input.requestMediaDataWhenReady(on: q) { [self] in
            while input.isReadyForMoreMediaData {
                if let sb = out.copyNextSampleBuffer() { input.append(sb) } else { input.markAsFinished(); done.fire(); return }
            }
        }
    }
}

public enum Exporter {
    /// Offline export: GPU renders frame i+1 while the encoder consumes frame i (depth-2 pipeline).
    public static func run(session: ProjectSession, timeline tl: Timeline, preset p: ExportPreset, to url: URL,
                           includeAudio: Bool = true, audioBitrate: Int = 256_000, exportStems: Bool = false,
                           exportCursorLayer: Bool = false,
                           progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        guard let d = tl.derived else { throw ExportError.noTimeline }
        if p.alpha && !p.codec.supportsAlpha {
            throw ExportError.writer("Transparent delivery needs ProRes 4444.")
        }
        let benchmark = ProcessInfo.processInfo.environment["LUMEN_BENCHMARK"] == "1"
        let startedAt = HostClock.now()
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                                                              reason: "Lumen hardware video export")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var decodeSeconds = 0.0, compositeSeconds = 0.0, encodeWaitSeconds = 0.0
        var lastProgress = 0.0
        let aspect = tl.style.aspectRatio
        let (preset, notice) = ExportCapabilityMatrix.shared.resolve(p, aspect: aspect)
        // An export must never silently alter the selected codec, fps, or dimensions.
        guard preset == p, ExportCapabilityMatrix.shared.supports(p, aspect: aspect) else {
            throw ExportError.writer("This Mac cannot encode the selected resolution, frame rate and codec.")
        }
        let renderer = try Renderer(); renderer.setCustomCursors(session.cursors)
        let h = preset.height, w = preset.width(aspect: aspect), fps = preset.fps
        let compositionDuration = tl.compositionDuration
        let total = max(Int(ceil(compositionDuration * Double(fps) - 1e-8)), 1)

        // Export audio runs at .utility so recording stays smooth on the same Mac
        // (complaint #1: "my MacBook is unusable while a file renders").
        let mixed = includeAudio ? await Task.detached(priority: .utility) { session.mixer.mix(tl) }.value : nil
        let caf = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        if let m = mixed { try AudioIO.writeCAF(m.l, m.r, to: caf) }
        defer { try? FileManager.default.removeItem(at: caf) }

        // Render into the destination directory and publish only after success.
        // Cancellation or an encoder error must not erase the previous export.
        let stagedURL = url.deletingLastPathComponent().appendingPathComponent(".lumen-export-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        let writer = try AVAssetWriter(outputURL: stagedURL,
                                       fileType: preset.codec.isProRes || preset.alpha || url.pathExtension == "mov" ? .mov : .mp4)
        defer { if writer.status != .completed { writer.cancelWriting() } }
        let bitrate = Int(Double(w * h * fps) * (preset.bpp > 0 ? preset.bpp : 0.06))
        var comp: [String: Any] = [AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalDurationKey: 2]
        let codec: AVVideoCodecType
        switch preset.codec {
        case .h264: codec = .h264; comp[AVVideoAverageBitRateKey] = bitrate; comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc: codec = .hevc; comp[AVVideoAverageBitRateKey] = bitrate
        case .hevc10: codec = .hevc; comp[AVVideoAverageBitRateKey] = bitrate; comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case .prores: codec = .proRes422HQ
        case .prores4444: codec = .proRes4444
        }
        // Alpha is RGB data. Asking for a YCbCr matrix on a transparent render
        // makes AVFoundation flatten the alpha channel, so leave colour keys
        // off when the delivery is transparent.
        var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                       AVVideoCompressionPropertiesKey: comp]
        if !preset.alpha {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                                                   AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                   AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vi.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: preset.codec.pixelFormat, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        guard writer.canAdd(vi) else { throw ExportError.writer("cannot add video input") }
        writer.add(vi)

        var feeder: AudioFeeder?
        if mixed != nil {
            let a = AVURLAsset(url: caf)
            if let tr = try await a.loadTracks(withMediaType: .audio).first, let r = try? AVAssetReader(asset: a) {
                let o = AVAssetReaderTrackOutput(track: tr, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
                r.add(o)
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                                  AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: max(64_000, min(audioBitrate, 320_000))])
                ai.expectsMediaDataInRealTime = false
                if writer.canAdd(ai) { writer.add(ai); feeder = AudioFeeder(r, o, ai); r.startReading() }
            }
        }
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "startWriting failed") }
        writer.startSession(atSourceTime: .zero)
        feeder?.start(on: DispatchQueue(label: "lumen.export.audio"))
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.writer("no pixel buffer pool") }

        var pending: [(Latch, CVPixelBuffer, Int)] = []
        func flush(_ item: (Latch, CVPixelBuffer, Int)) async throws {
            let waitStart = HostClock.now()
            await item.0.wait()
            while !vi.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw ExportError.writer(writer.error?.localizedDescription ?? "encoder stopped") }
                try await Task.sleep(for: .milliseconds(1))
            }
            encodeWaitSeconds += HostClock.now() - waitStart
            if !adaptor.append(item.1, withPresentationTime: CMTime(value: Int64(item.2), timescale: Int32(fps))) {
                throw ExportError.writer(writer.error?.localizedDescription ?? "append failed")
            }
            let now = HostClock.now()
            if now - lastProgress >= 0.10 || item.2 + 1 == total {
                progress(ExportProgress(frame: item.2 + 1, total: total, notice: notice))
                lastProgress = now
            }
        }
        for i in 0..<total {
            try Task.checkCancellation()
            let t = Double(i) / Double(fps)
            let readStart = HostClock.now()
            let (sf, wf) = try await session.frames(atOutput: t, timeline: tl)
            decodeSeconds += HostClock.now() - readStart
            var pbo: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbo)
            guard let pb = pbo else { throw ExportError.render }
            let latch = Latch()
            let req = RenderRequest(timeline: tl, t: t, screen: sf, webcam: wf, canvas: SIMD2(w, h), fps: Double(fps),
                                    backingScale: session.meta.source.backingScale,
                                    personMaskDirectory: session.bundle.cacheURL.appendingPathComponent("analysis", isDirectory: true),
                                    transparent: preset.alpha)
            let compositeStart = HostClock.now()
            guard renderer.render(req, into: pb, completion: { latch.fire() }) else { throw ExportError.render }
            compositeSeconds += HostClock.now() - compositeStart
            pending.append((latch, pb, i))
            // Metal has three in-flight uniform slots. Keep the encode queue full
            // without retaining an unbounded number of decoded pixel buffers.
            if pending.count >= 3 { try await flush(pending.removeFirst()) }
        }
        for item in pending { try await flush(item) }
        vi.markAsFinished()
        await feeder?.done.wait()
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "export failed") }
        try Task.checkCancellation()

        // Optionally export independent, unmastered float-WAV files for editing
        // in a professional NLE. They share the movie's output timeline and
        // remain silent in regions without their particular source.
        var stagedStems: [(temporary: URL, final: URL)] = []
        defer {
            for entry in stagedStems { try? FileManager.default.removeItem(at: entry.temporary) }
        }
        if exportStems {
            let sourceTracks = await Task.detached(priority: .utility) {
                session.mixer.stems(tl)
            }.value
            guard !sourceTracks.isEmpty else {
                throw ExportError.writer("No microphone, system audio, or voice-over tracks are available.")
            }
            let basename = url.deletingPathExtension().lastPathComponent
            let directory = url.deletingLastPathComponent()
            for stem in sourceTracks {
                try Task.checkCancellation()
                let name = basename + "-" + stem.name + ".wav"
                let destination = directory.appendingPathComponent(name)
                let temporary = directory.appendingPathComponent(".lumen-stem-\(UUID().uuidString).wav")
                try AudioIO.writeWAV(stem.left, stem.right, to: temporary)
                stagedStems.append((temporary: temporary, final: destination))
            }
        }

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: url)
        }
        for stem in stagedStems {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: stem.final.path) {
                _ = try FileManager.default.replaceItemAt(stem.final, withItemAt: stem.temporary)
            } else {
                try FileManager.default.moveItem(at: stem.temporary, to: stem.final)
            }
        }
        if exportCursorLayer {
            try Task.checkCancellation()
            let sidecar = url.deletingPathExtension().appendingPathExtension("cursor.mov")
            try await cursorLayer(session: session, timeline: tl, preset: preset, to: sidecar, progress: progress)
            // Best-effort relink sidecar: the movie is the deliverable, the
            // sidecar only documents how to swap the screen under the cursor.
            try? CursorRelink.writeSidecar(mainExport: url, cursorFile: sidecar,
                                         duration: tl.compositionDuration, fps: preset.fps,
                                         width: preset.width(aspect: aspect), height: preset.height)
        }
        if benchmark {
            let elapsed = HostClock.now() - startedAt
            let message = String(format: "Lumen export benchmark: %d frames in %.3fs (%.1f fps, %.2fx realtime) decode %.3fs GPU submit %.3fs GPU/encoder wait %.3fs other %.3fs\\n",
                                 total, elapsed, Double(total) / max(elapsed, 0.001), compositionDuration / max(elapsed, 0.001),
                                 decodeSeconds, compositeSeconds, encodeWaitSeconds,
                                 max(0, elapsed - decodeSeconds - compositeSeconds - encodeWaitSeconds))
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    /// Cursor-only movie with an alpha channel, for editors that want the
    /// pointer on its own layer. Always ProRes 4444: HEVC alpha in MOV is not
    /// reliably readable outside Apple's own apps.
    public static func cursorLayer(session: ProjectSession, timeline tl: Timeline, preset p: ExportPreset, to url: URL,
                                   progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        let fps = p.fps, w = p.width(aspect: tl.style.aspectRatio), h = p.height
        let total = max(Int(ceil(tl.compositionDuration * Double(fps) - 1e-8)), 1)
        let staged = url.deletingLastPathComponent().appendingPathComponent(".lumen-cursor-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: staged) }
        let writer = try AVAssetWriter(outputURL: staged, fileType: .mov)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: fps]])
        vi.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        guard writer.canAdd(vi) else { throw ExportError.writer("cannot add cursor layer input") }
        writer.add(vi)
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "cursor layer startWriting failed") }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.writer("no cursor layer buffer pool") }
        let renderer = try Renderer(); renderer.setCustomCursors(session.cursors)
        for i in 0..<total {
            try Task.checkCancellation()
            let t = Double(i) / Double(fps)
            let (sf, _) = try await session.frames(atOutput: t, timeline: tl)
            var pbo: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbo)
            guard let pb = pbo else { throw ExportError.render }
            let latch = Latch()
            let req = RenderRequest(timeline: tl, t: t, screen: sf, canvas: SIMD2(w, h), fps: Double(fps),
                                    backingScale: session.meta.source.backingScale,
                                    personMaskDirectory: session.bundle.cacheURL.appendingPathComponent("analysis", isDirectory: true),
                                    transparent: true, cursorOnly: true)
            guard renderer.render(req, into: pb, completion: { latch.fire() }) else { throw ExportError.render }
            await latch.wait()
            while !vi.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw ExportError.writer(writer.error?.localizedDescription ?? "cursor layer stopped") }
                try await Task.sleep(for: .milliseconds(1))
            }
            if !adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: Int32(fps))) {
                throw ExportError.writer(writer.error?.localizedDescription ?? "cursor layer append failed")
            }
            if i == total - 1 || i % max(fps / 2, 1) == 0 {
                progress(ExportProgress(frame: i + 1, total: total, notice: "Cursor layer"))
            }
        }
        vi.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "cursor layer export failed") }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: url)
        }
    }

    /// GIF via ImageIO (its own palette quantization). Capped at 800 px wide and 15 fps.
    public static func gif(session: ProjectSession, timeline tl: Timeline, to url: URL,
                           progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        guard tl.derived != nil else { throw ExportError.noTimeline }
        let w = 800, h = (Int((Double(w) / tl.style.aspectRatio).rounded()) + 1) & ~1, fps = 15
        let total = max(Int(ceil(tl.compositionDuration * Double(fps) - 1e-8)), 1)
        let renderer = try Renderer(); renderer.setCustomCursors(session.cursors)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, total, nil) else { throw ExportError.writer("gif") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<total {
            try Task.checkCancellation()
            let pb = try await FrameImage.render(renderer: renderer, session: session, timeline: tl, t: Double(i) / Double(fps), canvas: SIMD2(w, h), fps: Double(fps))
            if let img = FrameImage.cgImage(pb) {
                CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary)
            }
            progress(ExportProgress(frame: i + 1, total: total, notice: nil))
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writer("gif finalize failed") }
    }
}