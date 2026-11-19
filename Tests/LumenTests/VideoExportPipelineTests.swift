import Testing
import Foundation
import AVFoundation
import CoreVideo
import Metal
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
@testable import LumenExport

/// Headless acceptance suite for the export pipeline. Every frame check reads
/// real pixels: a source movie is generated (or the bundled `sequence.mp4` is
/// used), frames are rendered through the exact ProjectSession/Renderer path
/// export uses, and the encoded movie is decoded back with AVFoundation.
@Suite struct VideoExportPipelineTests {
    private static let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumen-v2-export-\(UUID().uuidString)")

    private static func tempDir(_ name: String) throws -> URL {
        let url = scratchRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Fixture generation

    /// A real movie whose frame `k` is a flat gray `k * step`. This makes the
    /// source frame at any edit boundary recoverable from decoded pixels.
    private static func makeLadderMovie(at url: URL, count: Int, fps: Int,
                                        size: CGSize, step: UInt8) async throws {
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
            let pb = try #require(FrameImage.makeBuffer(Int(size.width), Int(size.height)))
            CVPixelBufferLockBaseAddress(pb, [])
            let base = try #require(CVPixelBufferGetBaseAddress(pb))
            memset(base, Int32(step) * Int32(k), CVPixelBufferGetDataSize(pb))
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

    private static func bundledSequence() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["LUMEN_SEQUENCE_MP4"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            root = root.deletingLastPathComponent()
            candidates.append(root.appendingPathComponent(".proof/visual/sequence.mp4"))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) { return url }
        return nil
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

    private static func makeSession(directory: URL, movie: URL, source: SourceInfo,
                                    timeline: Timeline) async throws -> (ProjectSession, Renderer) {
        let bundle = try ProjectBundle.create(named: "V2", in: directory)
        try FileManager.default.copyItem(at: movie, to: bundle.screenURL)
        try EventCodec.header().write(to: bundle.eventsURL)
        var t = timeline
        t.style = flatStyle()
        let meta = ProjectMeta(name: "V2", source: source, clock: RecordingClock())
        try bundle.save(ProjectFile(meta: meta, timeline: t))
        let renderer = try Renderer()
        let (session, _) = try await ProjectSession.open(bundle, device: renderer.device)
        return (session, renderer)
    }

    private static func exportedFrameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        reader.add(AVAssetReaderTrackOutput(track: track, outputSettings: nil))
        guard reader.startReading() else { throw ExportError.reader("start") }
        var count = 0
        while let sb = reader.outputs[0].copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sb) }
        return count
    }

    /// Mean red channel of the decoded movie frame at `index`, 0...255.
    private static func decodedLuma(_ url: URL, size: CGSize) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw ExportError.reader("start") }
        var result: [Double] = []
        while let sb = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            var sum = 0
            let x0 = w / 4, x1 = w * 3 / 4, y0 = h / 4, y1 = h * 3 / 4
            for y in y0..<y1 { for x in x0..<x1 { sum += Int(base[y * stride + x * 4 + 2]) } }
            result.append(Double(sum) / Double((x1 - x0) * (y1 - y0)))
        }
        return result
    }

    /// Mean red channel of a frame rendered directly through the export renderer.
    private static func renderedLuma(session: ProjectSession, renderer: Renderer,
                                     timeline: Timeline, t: Double, size: CGSize) async throws -> Double {
        let pb = try await FrameImage.render(renderer: renderer, session: session, timeline: timeline,
                                             t: t, canvas: SIMD2(Int(size.width), Int(size.height)))
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        let x0 = w / 4, x1 = w * 3 / 4, y0 = h / 4, y1 = h * 3 / 4
        for y in y0..<y1 { for x in x0..<x1 { sum += Int(base[y * stride + x * 4 + 2]) } }
        return Double(sum) / Double((x1 - x0) * (y1 - y0))
    }

    private static func quiet(_ t: inout Timeline) {
        t.audio.speedRampsAuto = false
        t.audio.clickSounds = false
        t.audio.whooshes = false
        t.audio.musicPath = nil
        t.camera.autoZoom = false
    }

    // MARK: - Acceptance tests

    /// Real input, exact frame counts at every required output rate.
    @Test func realSequenceExportsExactFrameCountsAt60_120_240() async throws {
        guard let real = Self.bundledSequence() else {
            Issue.record("missing .proof/visual/sequence.mp4")
            return
        }
        let size = CGSize(width: 480, height: 270)
        for fps in [60, 120, 240] {
            let dir = try Self.tempDir("count-\(fps)")
            var timeline = Timeline(duration: 1.0)
            Self.quiet(&timeline)
            let source = SourceInfo(width: 480, height: 270, fps: 60, duration: 1,
                                    backingScale: 1, originX: 0, originY: 0)
            let (session, _) = try await Self.makeSession(directory: dir, movie: real, source: source, timeline: timeline)
            let out = dir.appendingPathComponent("out.mov")
            let preset = ExportPreset(name: "v2-\(fps)", codec: .h264, height: 270, fps: fps)
            try await Exporter.run(session: session, timeline: session.derive(timeline, revision: 1),
                                   preset: preset, to: out, includeAudio: false) { _ in }
            let count = try await Self.exportedFrameCount(out)
            #expect(count == fps, "real sequence at \(fps) fps: expected \(fps) frames, got \(count)")
        }
    }

    /// A cut must join two distinct source frames: no repeat at the seam,
    /// no jump past the frame after the removed span. Checked at 60 and 240 fps.
    @Test func cutBoundaryNeverDropsOrDuplicatesSourceFrames() async throws {
        let size = CGSize(width: 320, height: 180)
        let fps = 60
        for outFPS in [60, 240] {
            let dir = try Self.tempDir("cut-\(outFPS)")
            let movie = dir.appendingPathComponent("ladder.mov")
            try await Self.makeLadderMovie(at: movie, count: 60, fps: fps, size: size, step: 4)
            var clean = Timeline(duration: 1.0)
            Self.quiet(&clean)
            let source = SourceInfo(width: 320, height: 180, fps: 60, duration: 1,
                                    backingScale: 1, originX: 0, originY: 0)
            let (session, renderer) = try await Self.makeSession(directory: dir, movie: movie, source: source, timeline: clean)
            let derivedClean = session.derive(clean, revision: 1)

            // Calibrate expected luminance per source frame through the same
            // renderer, on an uncut timeline (output time == source time).
            var expected: [Double] = []
            for k in 0..<60 {
                expected.append(try await Self.renderedLuma(session: session, renderer: renderer,
                                                            timeline: derivedClean, t: Double(k) / 60, size: size))
            }

            var cut = clean
            cut.timeMap.cuts = [CutRange(start: 0.25, end: 0.5)]
            let derivedCut = session.derive(cut, revision: 2)
            let out = dir.appendingPathComponent("cut.mov")
            let preset = ExportPreset(name: "v2-cut", codec: .h264, height: 180, fps: outFPS)
            try await Exporter.run(session: session, timeline: derivedCut, preset: preset,
                                   to: out, includeAudio: false) { _ in }
            let luma = try await Self.decodedLuma(out, size: size)
            let total = Int(ceil(derivedCut.compositionDuration * Double(outFPS) - 1e-8))
            #expect(luma.count == total, "cut export \(outFPS): expected \(total) frames, got \(luma.count)")

            // Independent oracle: a cut [0.25,0.5) makes output t map to
            // source t + 0.25 from the seam onward.
            var previousSource = -1
            for (i, value) in luma.enumerated() {
                let t = Double(i) / Double(outFPS)
                let src = t < 0.25 ? t : t + 0.25
                let k = min(59, max(0, Int((src * 60).rounded(.down))))
                #expect(abs(value - expected[k]) < 9,
                        "frame \(i) at \(t)s: expected source \(k) luma \(expected[k]), got \(value)")
                #expect(k >= previousSource, "source went backwards at frame \(i)")
                previousSource = k
            }
            // The seam itself: frame just before and just after 0.25s output.
            if outFPS == 60 {
                #expect(luma.count > 15)
                #expect(abs(luma[14] - expected[14]) < 9)
                #expect(abs(luma[15] - expected[30]) < 9)
                #expect(abs(luma[14] - luma[15]) > 20, "seam frames must differ")
            }
        }
    }

    /// A speed ramp retimes picture to an exact frame count, never plays a
    /// source frame backwards, and is byte-for-byte deterministic.
    @Test func rampFrameCountMonotonicityAndDeterminism() async throws {
        let size = CGSize(width: 320, height: 180)
        let dir = try Self.tempDir("ramp")
        let movie = dir.appendingPathComponent("ladder.mov")
        try await Self.makeLadderMovie(at: movie, count: 60, fps: 60, size: size, step: 4)
        var timeline = Timeline(duration: 1.0)
        Self.quiet(&timeline)
        timeline.timeMap.ramps = [SpeedRamp(start: 0, end: 1, speed: 2)]
        let source = SourceInfo(width: 320, height: 180, fps: 60, duration: 1,
                                backingScale: 1, originX: 0, originY: 0)
        let (session, renderer) = try await Self.makeSession(directory: dir, movie: movie, source: source, timeline: timeline)
        let derived = session.derive(timeline, revision: 1)
        let expectedCount = Int(ceil(derived.compositionDuration * 240 - 1e-8))
        #expect(expectedCount > 0)
        var sequences: [[Double]] = []
        var rendered: [[Double]] = []
        for pass in 0..<2 {
            let out = dir.appendingPathComponent("ramp-\(pass).mov")
            try await Exporter.run(session: session, timeline: derived,
                                   preset: ExportPreset(name: "v2-ramp", codec: .h264, height: 180, fps: 240),
                                   to: out, includeAudio: false) { _ in }
            let luma = try await Self.decodedLuma(out, size: size)
            #expect(luma.count == expectedCount, "ramp: expected \(expectedCount) frames, got \(luma.count)")
            for i in 1..<max(luma.count, 1) {
                #expect(luma[i] >= luma[i - 1] - 3, "ramp source went backwards at \(i)")
            }
            sequences.append(luma)
            // The renderer is the determinism oracle; H.264 rate control is
            // allowed to shift decoded pixels by a quantisation step.
            var direct: [Double] = []
            for i in 0..<expectedCount {
                direct.append(try await Self.renderedLuma(session: session, renderer: renderer,
                                                          timeline: derived, t: Double(i) / 240, size: size))
            }
            rendered.append(direct)
        }
        #expect(rendered[0] == rendered[1], "ramp render must be pixel-deterministic")
        #expect(sequences[0].count == sequences[1].count)
        for i in 0..<min(sequences[0].count, sequences[1].count) {
            #expect(abs(sequences[0][i] - sequences[1][i]) <= 3, "ramp encode drifted at frame \(i)")
        }
    }

    /// An imported clip takes over at its exact output boundary.
    @Test func importedClipJoinsAtExactOutputFrame() async throws {
        let size = CGSize(width: 320, height: 180)
        let dir = try Self.tempDir("clip")
        let main = dir.appendingPathComponent("main.mov")
        let other = dir.appendingPathComponent("other.mov")
        try await Self.makeLadderMovie(at: main, count: 30, fps: 60, size: size, step: 4)
        try await Self.makeLadderMovie(at: other, count: 30, fps: 60, size: size, step: 2)
        var timeline = Timeline(duration: 0.5)
        Self.quiet(&timeline)
        timeline.clips = [TimelineClip(path: other.path, name: "other", inPoint: 0,
                                       duration: 0.5, start: 0.5, width: 320, height: 180)]
        let source = SourceInfo(width: 320, height: 180, fps: 60, duration: 0.5,
                                backingScale: 1, originX: 0, originY: 0)
        let (session, renderer) = try await Self.makeSession(directory: dir, movie: main, source: source, timeline: timeline)
        let derived = session.derive(timeline, revision: 1)
        let out = dir.appendingPathComponent("clip.mov")
        try await Exporter.run(session: session, timeline: derived,
                               preset: ExportPreset(name: "v2-clip", codec: .h264, height: 180, fps: 60),
                               to: out, includeAudio: false) { _ in }
        let luma = try await Self.decodedLuma(out, size: size)
        #expect(luma.count == 60)
        if luma.count >= 60 {
            // Before the seam the recording's ladder peaks near 236; after it
            // the imported ladder starts dark and climbs slowly.
            #expect(luma[29] > 100, "last recording frame should be the bright end of its ladder")
            #expect(luma[30] < 40, "first imported frame should be dark")
            #expect(abs(luma[30] - (try await Self.renderedLuma(session: session, renderer: renderer,
                                                                timeline: derived, t: 0.5, size: size))) < 9)
        }
    }

    /// Resolving an unsupported preset may downgrade, but a custom width must
    /// never survive a height change and silently change the aspect ratio.
    @Test func presetDowngradeNeverChangesCustomAspectOrBreakAlpha() {
        let custom = ExportPreset(name: "eightk", codec: .h264, height: 4320, fps: 240, customWidth: 7680)
        let changed = custom.adjusted(codec: .h264, height: 1080, fps: 60)
        #expect(changed.customWidth == nil,
                "a height downgrade must recompute width, not keep a stale custom width")
        #expect(changed.width(aspect: 16.0 / 9) == 1920)

        let alpha = ExportPreset(name: "alpha", codec: .prores4444, height: 1080, fps: 60, alpha: true)
        let downgraded = alpha.adjusted(codec: .h264, height: 1080, fps: 60)
        #expect(downgraded.alpha == false)
        #expect(ExportCapabilityMatrix.shared.resolve(alpha, aspect: 16.0 / 9).0.codec.supportsAlpha)

        // A downgrade must actually resolve to a supported combination and say
        // what changed; an unresolved preset must keep its original promise.
        let (resolved, notice) = ExportCapabilityMatrix.shared.resolve(custom, aspect: 16.0 / 9)
        if resolved != custom {
            #expect(notice != nil)
            #expect(ExportCapabilityMatrix.shared.supports(resolved, aspect: 16.0 / 9))
            if resolved.customWidth == nil { #expect(notice?.contains("canvas aspect") == true) }
        }
    }

    /// GoldenImage is the pixel oracle: identical frames compare with zero
    /// differing pixels; a one-channel change is detected with an exact delta.
    @Test func goldenImageDetectsOneChannelDrift() throws {
        let reference = GoldenImage(width: 40, height: 20,
                                    pixels: [UInt8](repeating: 7, count: 40 * 20 * 4))
        var candidate = reference
        candidate.pixels[3] = 8
        let diff = GoldenComparison.compare(reference, candidate)
        #expect(diff.differingPixels == 1)
        #expect(diff.maxChannelDelta == 1)
        #expect(diff.passes(), "one of 800 pixels is inside the default gate")
        let resized = GoldenImage(width: 41, height: 20, pixels: reference.pixels)
        #expect(GoldenComparison.compare(reference, resized).passes() == false)
    }
}

private extension ExportError {
    static func reader(_ message: String) -> ExportError { .writer(message) }
}
