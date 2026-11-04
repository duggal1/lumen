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
public struct ExportProgress: Sendable { public var frame: Int, total: Int, notice: String? }

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
    /// One frame, fully rendered (CLI `frame`, GIF).
    public static func render(renderer: Renderer, session: ProjectSession, timeline tl: Timeline, t: Double, canvas: SIMD2<Int>,
                              fps: Double = 60) async throws -> CVPixelBuffer {
        let s = tl.timeMap.source(atOutput: t)
        let sf = try await session.screen.frame(atSource: s)
        let wf = tl.webcam != nil ? try? await session.webcam?.frame(atSource: s) : nil
        guard let pb = makeBuffer(canvas.x, canvas.y) else { throw ExportError.render }
        let latch = Latch()
        let req = RenderRequest(timeline: tl, t: t, screen: sf, webcam: wf, canvas: canvas, fps: fps, backingScale: session.meta.source.backingScale)
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
                           progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        guard let d = tl.derived else { throw ExportError.noTimeline }
        let aspect = tl.style.canvas.ratio
        let (preset, notice) = ExportCapabilityMatrix.shared.resolve(p, aspect: aspect)
        let renderer = try Renderer(); renderer.setCustomCursors(session.cursors)
        let h = preset.height, w = preset.width(aspect: aspect), fps = preset.fps
        let total = max(Int(ceil(d.outputDuration * Double(fps) - 1e-8)), 1)

        let mixed = await Task.detached { session.mixer.mix(tl) }.value
        let caf = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        if let m = mixed { try AudioIO.writeCAF(m.l, m.r, to: caf) }
        defer { try? FileManager.default.removeItem(at: caf) }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: preset.codec == .prores || url.pathExtension == "mov" ? .mov : .mp4)
        let bitrate = Int(Double(w * h * fps) * (preset.bpp > 0 ? preset.bpp : 0.06))
        var comp: [String: Any] = [AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalDurationKey: 2]
        let codec: AVVideoCodecType
        switch preset.codec {
        case .h264: codec = .h264; comp[AVVideoAverageBitRateKey] = bitrate; comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc: codec = .hevc; comp[AVVideoAverageBitRateKey] = bitrate
        case .hevc10: codec = .hevc; comp[AVVideoAverageBitRateKey] = bitrate; comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case .prores: codec = .proRes422HQ
        }
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: comp])
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
                                                                                  AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
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
            await item.0.wait()
            while !vi.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            if !adaptor.append(item.1, withPresentationTime: CMTime(value: Int64(item.2), timescale: Int32(fps))) {
                throw ExportError.writer(writer.error?.localizedDescription ?? "append failed")
            }
            progress(ExportProgress(frame: item.2 + 1, total: total, notice: notice))
        }
        for i in 0..<total {
            try Task.checkCancellation()
            let t = Double(i) / Double(fps), s = tl.timeMap.source(atOutput: t)
            let sf = try await session.screen.frame(atSource: s)
            let wf = tl.webcam != nil ? try? await session.webcam?.frame(atSource: s) : nil
            var pbo: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbo)
            guard let pb = pbo else { throw ExportError.render }
            let latch = Latch()
            let req = RenderRequest(timeline: tl, t: t, screen: sf, webcam: wf, canvas: SIMD2(w, h), fps: Double(fps),
                                    backingScale: session.meta.source.backingScale)
            guard renderer.render(req, into: pb, completion: { latch.fire() }) else { throw ExportError.render }
            pending.append((latch, pb, i))
            if pending.count > 2 { try await flush(pending.removeFirst()) }
        }
        for item in pending { try await flush(item) }
        vi.markAsFinished()
        await feeder?.done.wait()
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "export failed") }
    }

    /// GIF via ImageIO (its own palette quantization). Capped at 800 px wide and 15 fps.
    public static func gif(session: ProjectSession, timeline tl: Timeline, to url: URL,
                           progress: @escaping @Sendable (ExportProgress) -> Void) async throws {
        guard let d = tl.derived else { throw ExportError.noTimeline }
        let w = 800, h = (Int((Double(w) / tl.style.canvas.ratio).rounded()) + 1) & ~1, fps = 15
        let total = max(Int(d.outputDuration * Double(fps)), 1)
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