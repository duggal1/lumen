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
        /// Peak resident memory in KiB observed after the export (ru_maxrss).
        public var peakRSSKb: Int64
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
        let start = Date()
        try await Exporter.run(session: session, timeline: tl, preset: preset, to: out,
                               includeAudio: true) { _ in }
        let elapsed = Date().timeIntervalSince(start)
        let total = max(Int(ceil(tl.compositionDuration * fps - 1e-8)), 1)
        let peak = Self.peakRSSKb()
        return Result(frames: total, seconds: elapsed,
                      realtimeFactor: elapsed > 0 ? Double(total) / (fps * elapsed) : 0,
                      peakRSSKb: peak)
    }

    private static func peakRSSKb() -> Int64 {
        var r: rusage = rusage()
        Darwin.getrusage(RUSAGE_SELF, &r)
        return Int64(r.ru_maxrss)
    }
}
