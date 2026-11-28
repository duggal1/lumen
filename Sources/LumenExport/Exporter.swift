import Foundation
import AVFoundation
import VideoToolbox
@preconcurrency import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio

/// A3: Instruments signposts for the export stages. Behavior-neutral — this
/// only makes CPU waits, GPU completion and encoder back-pressure visible in a
/// trace so bottlenecks can be measured instead of guessed.
private let exportLog = OSLog(subsystem: "com.lumen.studio", category: "export")

public enum ExportError: Error { case writer(String), render, noTimeline }
public struct ExportProgress: Sendable {
    public var frame: Int, total: Int, notice: String?
    public init(frame: Int, total: Int, notice: String?) { self.frame = frame; self.total = total; self.notice = notice }
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
        try await renderFrame(renderer: renderer, session: session, timeline: tl, t: t, canvas: canvas,
                              fps: fps, transparent: transparent, cursorOnly: cursorOnly, reader: nil)
    }

    static func renderFrame(renderer: Renderer, session: ProjectSession, timeline tl: Timeline, t: Double, canvas: SIMD2<Int>,
                            fps: Double = 60, transparent: Bool = false, cursorOnly: Bool = false,
                            reader: ProjectFrameReader?) async throws -> CVPixelBuffer {
        let (sf, wf): (SourceFrame, SourceFrame?)
        if let reader { (sf, wf) = try await reader.frames(atOutput: t, timeline: tl) }
        else { (sf, wf) = try await session.frames(atOutput: t, timeline: tl) }
        guard let pb = makeBuffer(canvas.x, canvas.y) else { throw ExportError.render }
        let latch = Latch()
        let req = RenderRequest(timeline: tl, t: t, screen: sf, webcam: wf, canvas: canvas, fps: fps,
                                backingScale: session.meta.source.backingScale,
                                personMaskDirectory: session.bundle.cacheURL.appendingPathComponent("analysis", isDirectory: true),
                                transparent: transparent, cursorOnly: cursorOnly)
        guard renderer.renderChecked(req, into: pb, completion: { latch.fire($0) }) else { throw ExportError.render }
        try await latch.waitChecked(stage: .render)
        try Task.checkCancellation()
        return pb
    }
    /// Renders one frame and returns it as a CGImage so callers in isolated contexts
    /// never have to receive a non-Sendable CVPixelBuffer across an actor boundary.
    public static func renderCGImage(renderer: Renderer, session: ProjectSession, timeline tl: Timeline, t: Double, canvas: SIMD2<Int>,
                                    fps: Double = 60, transparent: Bool = false, cursorOnly: Bool = false) async throws -> CGImage {
        let buffer = try await render(renderer: renderer, session: session, timeline: tl, t: t, canvas: canvas,
                                     fps: fps, transparent: transparent, cursorOnly: cursorOnly)
        guard let image = cgImage(buffer) else { throw ExportError.render }
        return image
    }
    public static func writePNG(_ pb: CVPixelBuffer, to url: URL) throws {
        guard let img = cgImage(pb), let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ExportError.render }
        CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    }
}

private final class AudioFeeder: @unchecked Sendable {
    let reader: AVAssetReader, out: AVAssetReaderTrackOutput, input: AVAssetWriterInput
    private let state = OSAllocatedUnfairLock<(finished: Bool, failure: String?)>(initialState: (false, nil))
    private let sampleCount = OSAllocatedUnfairLock<Int64>(initialState: 0)
    var result: (finished: Bool, failure: String?) { state.withLock { $0 } }
    var appendedSamples: Int64 { sampleCount.withLock { $0 } }
    init(_ r: AVAssetReader, _ o: AVAssetReaderTrackOutput, _ i: AVAssetWriterInput) { reader = r; out = o; input = i }
    func start(on q: DispatchQueue) {
        input.requestMediaDataWhenReady(on: q) { [self] in
            while input.isReadyForMoreMediaData, !result.finished {
                if let sb = out.copyNextSampleBuffer() {
                    guard input.append(sb) else {
                        state.withLock { $0 = (true, "Audio encoder rejected a sample.") }
                        return
                    }
                    sampleCount.withLock { $0 += Int64(CMSampleBufferGetNumSamples(sb)) }
                } else {
                    let failure = reader.status == .completed ? nil : (reader.error?.localizedDescription ?? "Audio reader stopped before completion.")
                    if failure == nil { input.markAsFinished() }
                    state.withLock { $0 = (true, failure) }
                    return
                }
            }
        }
    }
    func cancel() {
        state.withLock { if !$0.finished { $0 = (true, "Audio export cancelled.") } }
        if reader.status == .reading { reader.cancelReading() }
    }
}

public enum Exporter {
    private static func finish(_ writer: AVAssetWriter, duration: Double) async throws {
        let latch = Latch()
        // AVAssetWriter exposes no byte-level finalization progress here.
        // Use a workload-scaled absolute deadline, not fabricated progress.
        let timeout = min(1800, max(120, 120 + max(duration, 0) * 0.25))
        writer.finishWriting { latch.fire(true) }
        try await latch.waitChecked(stage: .finalize, timeout: .seconds(timeout))
    }

    /// Offline export: GPU renders frame i+1 while the encoder consumes frame i (depth-2 pipeline).
    @discardableResult
    public static func run(session: ProjectSession, timeline tl: Timeline, preset p: ExportPreset, to url: URL,
                           includeAudio: Bool = true, audioBitrate: Int = 320_000, exportStems: Bool = false,
                           exportCursorLayer: Bool = false,
                           progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportMediaProof {
        guard let d = tl.derived else { throw ExportError.noTimeline }
        if p.alpha && !p.codec.supportsAlpha {
            throw ExportError.writer("Transparent delivery needs ProRes 4444.")
        }
        let benchmark = ProcessInfo.processInfo.environment["LUMEN_BENCHMARK"] == "1"
        let startedAt = HostClock.now()
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                                                              reason: "Lumen hardware video export")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        os_signpost(.begin, log: exportLog, name: "export")
        defer { os_signpost(.end, log: exportLog, name: "export") }
        var decodeSeconds = 0.0, compositeSeconds = 0.0, encodeWaitSeconds = 0.0
        var gpuWaitSeconds = 0.0, encoderWaitSeconds = 0.0, appendSeconds = 0.0
        var mixSeconds = 0.0, finishSeconds = 0.0
        var lastProgress = 0.0
        let aspect = tl.style.aspectRatio
        let (preset, notice) = ExportCapabilityMatrix.shared.resolve(p, aspect: aspect)
        // An export must never silently alter the selected codec, fps, or dimensions.
        guard preset == p, ExportCapabilityMatrix.shared.supports(p, aspect: aspect) else {
            throw ExportError.writer("This Mac cannot encode the selected resolution, frame rate and codec.")
        }
        let renderer = try Renderer(); renderer.setCustomCursors(session.cursors)
        let reader = try await session.makeExportFrameReader()
        let h = preset.height, w = preset.width(aspect: aspect), fps = preset.fps
        let compositionDuration = tl.compositionDuration
        let total = max(Int(ceil(compositionDuration * Double(fps) - 1e-8)), 1)

        let caf = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: caf) }
        // Export audio runs at .utility so recording stays smooth on the same Mac.
        // Start it now but DON'T await it: the multi-second DSP mix and its CAF
        // write overlap the render/encode loop and are joined before finalize.
        let audioPrep: Task<Bool, Error>? = includeAudio
            ? Task.detached(priority: .utility) {
                try Task.checkCancellation()
                guard let m = session.mixer.mix(tl, cancelled: { Task.isCancelled }) else {
                    try Task.checkCancellation()
                    if session.mixer.hasProgram(tl) { throw ExportError.writer("Audio mix failed.") }
                    return false
                }
                try Task.checkCancellation()
                try AudioIO.writeCAF(m.l, m.r, to: caf)
                try Task.checkCancellation()
                return true
              }
            : nil

        // A detached DSP worker must be joined before the temporary CAF is
        // removed, including on GPU failure or user cancellation.
        do {
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
        // Export aspect uses SDR BT.709 color tags. BT.2020 would shift
        // colors on iPhone/Photos upload; the delivery is SDR, not HDR.
        var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                       AVVideoCompressionPropertiesKey: comp]
        if !preset.alpha {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                   AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                   AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        // Offline export must run faster than realtime. With this flag off,
        // VideoToolbox buffers several frames for rate-distortion lookahead and
        // the adaptor stalls ~13-19 ms per frame; realtime mode streams frames
        // through the hardware encoder immediately.
        vi.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: preset.codec.pixelFormat, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        guard writer.canAdd(vi) else { throw ExportError.writer("cannot add video input") }
        writer.add(vi)

        // The audio input is registered before writing starts; samples are fed
        // after the video loop, once the overlapping mix has completed.
        var audioInput: AVAssetWriterInput?
        if audioPrep != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                               AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: max(64_000, min(audioBitrate, 320_000))])
            ai.expectsMediaDataInRealTime = false
            guard writer.canAdd(ai) else { throw ExportError.writer("cannot add requested audio input") }
            writer.add(ai); audioInput = ai
        }
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "startWriting failed") }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.writer("no pixel buffer pool") }

        var pending: [(Latch, CVPixelBuffer, Int)] = []
        func flush(_ item: (Latch, CVPixelBuffer, Int)) async throws {
            let waitStart = HostClock.now()
            os_signpost(.begin, log: exportLog, name: "export.encode.wait")
            let gpuStart = HostClock.now()
            try await item.0.waitChecked(stage: .render)
            try Task.checkCancellation()
            gpuWaitSeconds += HostClock.now() - gpuStart
            let encoderStart = HostClock.now()
            var readiness = ExportStallGuard(stage: .encoder, idleSeconds: 30, now: encoderStart)
            while !vi.isReadyForMoreMediaData {
                try readiness.observe(progress: 0, now: HostClock.now())
                try Task.checkCancellation()
                guard writer.status == .writing else { throw ExportError.writer(writer.error?.localizedDescription ?? "encoder stopped") }
                try await Task.sleep(for: .milliseconds(1))
            }
            encoderWaitSeconds += HostClock.now() - encoderStart
            os_signpost(.end, log: exportLog, name: "export.encode.wait")
            let appendStart = HostClock.now()
            os_signpost(.event, log: exportLog, name: "export.frame.append")
            if !adaptor.append(item.1, withPresentationTime: CMTime(value: Int64(item.2), timescale: Int32(fps))) {
                throw ExportError.writer(writer.error?.localizedDescription ?? "append failed")
            }
            appendSeconds += HostClock.now() - appendStart
            encodeWaitSeconds += HostClock.now() - waitStart
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
            os_signpost(.begin, log: exportLog, name: "export.decode")
            let (sf, wf) = try await reader.frames(atOutput: t, timeline: tl)
            os_signpost(.end, log: exportLog, name: "export.decode")
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
            os_signpost(.begin, log: exportLog, name: "export.composite")
            guard renderer.renderChecked(req, into: pb, completion: { success in
                os_signpost(.event, log: exportLog, name: "export.gpu.done")
                latch.fire(success)
            }) else { throw ExportError.render }
            os_signpost(.end, log: exportLog, name: "export.composite")
            compositeSeconds += HostClock.now() - compositeStart
            pending.append((latch, pb, i))
            // Metal has three in-flight uniform slots. Keep the encode queue full
            // without retaining an unbounded number of decoded pixel buffers.
            if pending.count >= 3 { try await flush(pending.removeFirst()) }
        }
        for item in pending { try await flush(item) }
        vi.markAsFinished()
        // Join the audio prep that has been running alongside the video loop.
        if let audioPrep {
            let mixStart = HostClock.now()
            os_signpost(.begin, log: exportLog, name: "export.audio.mix")
            let hasAudio = try await audioPrep.value
            os_signpost(.end, log: exportLog, name: "export.audio.mix")
            mixSeconds = HostClock.now() - mixStart
            if hasAudio, let ai = audioInput {
                let a = AVURLAsset(url: caf)
                if let tr = try await a.loadTracks(withMediaType: .audio).first,
                   let r = try? AVAssetReader(asset: a) {
                    let o = AVAssetReaderTrackOutput(track: tr, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
                    r.add(o)
                    let feeder = AudioFeeder(r, o, ai)
                    guard r.startReading() else { throw ExportError.writer(r.error?.localizedDescription ?? "Audio reader failed to start.") }
                    defer { feeder.cancel() }
                    feeder.start(on: DispatchQueue(label: "lumen.export.audio"))
                    var audioProgress = ExportStallGuard(stage: .audio, idleSeconds: 60, now: HostClock.now())
                    while !feeder.result.finished {
                        try Task.checkCancellation()
                        try audioProgress.observe(progress: feeder.appendedSamples, now: HostClock.now())
                        guard writer.status == .writing else { throw ExportError.writer(writer.error?.localizedDescription ?? "Audio encoder stopped.") }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    if let failure = feeder.result.failure { throw ExportError.writer(failure) }
                } else { throw ExportError.writer("Mixed audio could not be read.") }
            } else { audioInput?.markAsFinished() }
        }
        let finishStart = HostClock.now()
        try await finish(writer, duration: compositionDuration)
        finishSeconds = HostClock.now() - finishStart
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "export failed") }
        try Task.checkCancellation()

        // Validate staged media before any existing destination is replaced.
        let proof = try await ExportMediaProof.verify(stagedURL, expectedDuration: compositionDuration,
            fps: fps, expectsAudio: includeAudio && session.mixer.hasProgram(tl),
            expectedSize: CGSize(width: w, height: h))
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
            let message = String(format: "Lumen export benchmark: %d frames in %.3fs (%.1f fps, %.2fx realtime) decode %.3fs GPU submit %.3fs gpuWait %.3fs encoderWait %.3fs append %.3fs mix %.3fs finish %.3fs other %.3fs\\n",
                                 total, elapsed, Double(total) / max(elapsed, 0.001), compositionDuration / max(elapsed, 0.001),
                                 decodeSeconds, compositeSeconds, gpuWaitSeconds, encoderWaitSeconds, appendSeconds,
                                 mixSeconds, finishSeconds,
                                 max(0, elapsed - decodeSeconds - compositeSeconds - encodeWaitSeconds - mixSeconds - finishSeconds))
            FileHandle.standardError.write(Data(message.utf8))
        }
        return proof
        } catch {
            audioPrep?.cancel()
            _ = try? await audioPrep?.value
            throw error
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
        defer { if writer.status != .completed { writer.cancelWriting() } }
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
        let reader = try await session.makeExportFrameReader()
        for i in 0..<total {
            try Task.checkCancellation()
            let t = Double(i) / Double(fps)
            let (sf, _) = try await reader.frames(atOutput: t, timeline: tl)
            var pbo: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbo)
            guard let pb = pbo else { throw ExportError.render }
            let latch = Latch()
            let req = RenderRequest(timeline: tl, t: t, screen: sf, canvas: SIMD2(w, h), fps: Double(fps),
                                    backingScale: session.meta.source.backingScale,
                                    personMaskDirectory: session.bundle.cacheURL.appendingPathComponent("analysis", isDirectory: true),
                                    transparent: true, cursorOnly: true)
            guard renderer.renderChecked(req, into: pb, completion: { latch.fire($0) }) else { throw ExportError.render }
            try await latch.waitChecked(stage: .render)
            try Task.checkCancellation()
            var readiness = ExportStallGuard(stage: .encoder, idleSeconds: 30, now: HostClock.now())
            while !vi.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try readiness.observe(progress: 0, now: HostClock.now())
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
        try await finish(writer, duration: tl.compositionDuration)
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "cursor layer export failed") }
        try Task.checkCancellation()
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
        let reader = try await session.makeExportFrameReader()
        let staged = url.deletingLastPathComponent().appendingPathComponent(".lumen-gif-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: staged) }
        guard let dest = CGImageDestinationCreateWithURL(staged as CFURL, UTType.gif.identifier as CFString, total, nil) else { throw ExportError.writer("gif") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<total {
            try Task.checkCancellation()
            let pb = try await FrameImage.renderFrame(renderer: renderer, session: session, timeline: tl, t: Double(i) / Double(fps), canvas: SIMD2(w, h), fps: Double(fps), reader: reader)
            guard let img = FrameImage.cgImage(pb) else { throw ExportError.render }
            CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary)
            progress(ExportProgress(frame: i + 1, total: total, notice: nil))
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writer("gif finalize failed") }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        } else { try FileManager.default.moveItem(at: staged, to: url) }
    }
}