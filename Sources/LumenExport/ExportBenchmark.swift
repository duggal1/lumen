import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import Darwin
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio

/// Real-export benchmark: runs the actual `Exporter.run` pipeline against a
/// synthetic ladder fixture and reports wall time, realtime factor, per-stage
/// timings and peak RSS. Uses the same fixture recipe as the export pipeline
/// acceptance tests (see VideoExportPipelineTests).
public enum ExportBenchmark {
    public struct Result: Sendable {
        public var frames: Int
        public var seconds: Double
        public var realtimeFactor: Double
        /// Process-lifetime peak RSS in KiB, not isolated export memory.
        public var peakRSSKb: Int64
        /// Time spent inspecting the delivered compressed sample stream.
        public var validationSeconds: Double
        public var outputBytes: Int64
        public var verifiedRealtimeFactor: Double {
            Double(frames) / max(seconds + validationSeconds, 0.001) / frameRate
        }
        public var frameRate: Double
    }

    /// A real movie whose frame `k` is a flat gray `k * step` (analogous to
    /// the ladder fixture in the export acceptance suite).
    public static func makeLadderMovie(at url: URL, count: Int, fps: Int = 60,
                                       size: CGSize, step: UInt8 = 4) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw ExportError.writer("ladder input") }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writer("ladder start") }
        writer.startSession(atSourceTime: .zero)
        for k in 0..<count {
            guard let pb = FrameImage.makeBuffer(Int(size.width), Int(size.height)) else {
                throw ExportError.writer("ladder buffer \(k)")
            }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, Int32(step) * Int32(k), CVPixelBufferGetDataSize(pb))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard adaptor.append(pb, withPresentationTime: CMTime(value: Int64(k), timescale: Int32(fps))) else {
                throw ExportError.writer("ladder append \(k)")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.writer("ladder finish") }
    }

    public static func makeSession(directory: URL, movie: URL, source: SourceInfo,
                                   timeline: Timeline) async throws -> (ProjectSession, Timeline) {
        let bundle = try ProjectBundle.create(named: "ExportBench", in: directory)
        try FileManager.default.copyItem(at: movie, to: bundle.screenURL)
        try EventCodec.header().write(to: bundle.eventsURL)
        var t = timeline
        // Auto speed ramps derive from audio/VAD and would retime the output,
        // producing a frame count different from the fixture's. Benchmark and
        // cadence tests need a 1:1 source→output timeline.
        t.audio.speedRampsAuto = false
        t.style = flatStyle()
        let meta = ProjectMeta(name: "ExportBench", source: source, clock: RecordingClock())
        try bundle.save(ProjectFile(meta: meta, timeline: t))
        let renderer = try Renderer()
        let (session, _) = try await ProjectSession.open(bundle, device: renderer.device)
        return (session, session.derive(t, revision: 1))
    }

    private static func flatStyle() -> Style {
        var s = Style()
        s.background = .solid
        s.colors = [RGBA(0x000000), RGBA(0x000000)]
        s.padding = 0
        s.cornerRadius = 0
        s.shadow = 0
        s.innerBorder = false
        s.contentScale = 1
        return s
    }

    /// Runs the real export pipeline. `seconds` of video at `preset.fps` from a
    /// `frameCount`-frame fixture. Returns wall time, realtime factor and peak RSS.
    public static func run(session: ProjectSession, timeline tl: Timeline, preset: ExportPreset,
                           frames: Int) async throws -> Result {
        let fps = Double(preset.fps)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-export-bench-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }
        let expected = max(Int(ceil(tl.compositionDuration * fps - 1e-8)), 1)
        guard frames == expected else {
            throw ExportError.writer("Benchmark fixture expected \(frames) frames, timeline requires \(expected).")
        }
        let start = HostClock.now()
        try await Exporter.run(session: session, timeline: tl, preset: preset, to: out,
                               includeAudio: true) { _ in }
        let elapsed = HostClock.now() - start
        let validationStart = HostClock.now()
        let actual = try await validateVideo(at: out, expectedFrames: expected, fps: preset.fps)
        let bytes = try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0 else { throw ExportError.writer("Benchmark output is empty.") }
        return Result(frames: actual, seconds: elapsed,
                      realtimeFactor: elapsed > 0 ? Double(actual) / (fps * elapsed) : 0,
                      peakRSSKb: Self.peakRSSKb(), validationSeconds: HostClock.now() - validationStart,
                      outputBytes: Int64(bytes), frameRate: fps)
    }

    /// Inspect actual compressed samples without decoding the entire movie.
    /// Presentation timestamps may be reordered by B-frames; verify sorted
    /// presentation order, not container decode order.
    public static func validateVideo(at url: URL, expectedFrames: Int, fps: Int) async throws -> Int {
        guard expectedFrames > 0, fps > 0 else { throw ExportError.writer("Invalid benchmark expectation.") }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.writer("Benchmark output has no video track.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.writer("Benchmark reader configuration.") }
        reader.add(output)
        guard reader.startReading() else { throw ExportError.writer("Benchmark reader start.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var timestamps: [Double] = []
        timestamps.reserveCapacity(min(expectedFrames, 100_000))
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = sample.presentationTimeStamp.seconds
            guard pts.isFinite, CMSampleBufferGetNumSamples(sample) == 1 else {
                throw ExportError.writer("Invalid compressed video sample.")
            }
            timestamps.append(pts)
            guard timestamps.count <= expectedFrames else { throw ExportError.writer("Extra video frames.") }
        }
        guard reader.status == .completed, timestamps.count == expectedFrames else {
            throw ExportError.writer("Benchmark video frame count: \(timestamps.count), expected \(expectedFrames).")
        }
        timestamps.sort()
        let tolerance = 0.25 / Double(fps)
        for (index, pts) in timestamps.enumerated() {
            guard abs(pts - Double(index) / Double(fps)) <= tolerance else {
                throw ExportError.writer("Benchmark video timestamp mismatch at frame \(index).")
            }
        }
        return timestamps.count
    }

    private static func peakRSSKb() -> Int64 {
        var r: rusage = rusage()
        Darwin.getrusage(RUSAGE_SELF, &r)
        // Darwin reports bytes (Linux reports KiB).
        return Int64(r.ru_maxrss) / 1024
    }
}
