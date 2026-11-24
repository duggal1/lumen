import Testing
import Foundation
import AVFoundation
import CoreVideo
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
@testable import LumenExport

/// A6 — headless end-to-end acceptance suite: a synthetic recording (scripted
/// events + generated frames) through the whole pipeline — Director zoom
/// planning, ProjectSession, Renderer and Exporter.run — then decoded from the
/// exported movie: fps = 60, frame count, duration, cadence, zoom decisions,
/// crop, A/V sync and audio headroom.
@Suite struct A6SyntheticRecordingE2ETests {
    static let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumen-a6-e2e-\(UUID().uuidString)")

    static func tempDir(_ name: String) throws -> URL {
        let url = scratchRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Fixtures (shared with A6CrashSafetyTests)

    static func flatStyle() -> Style {
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

    static func quiet(_ t: inout Timeline) {
        t.audio.speedRampsAuto = false
        t.audio.clickSounds = false
        t.audio.whooshes = false
        t.audio.musicPath = nil
    }

    /// A real movie whose frame `k` is a unique gradient — generated frames
    /// through the exact reader path export uses.
    static func makeLadderMovie(at url: URL, count: Int, fps: Int, size: CGSize, step: UInt8) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw A6FixtureError.ladder("input") }
        writer.add(input)
        guard writer.startWriting() else { throw A6FixtureError.ladder("start") }
        writer.startSession(atSourceTime: .zero)
        for k in 0..<count {
            guard let pb = FrameImage.makeBuffer(Int(size.width), Int(size.height)) else {
                throw A6FixtureError.ladder("pixel buffer")
            }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let stride = CVPixelBufferGetBytesPerRow(pb)
                let row = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<Int(size.height) {
                    let p = row.advanced(by: y * stride)
                    for x in 0..<Int(size.width) {
                        p[x * 4 + 0] = UInt8((x + 2 * k) & 0xFF)
                        p[x * 4 + 1] = UInt8((y + k) & 0xFF)
                        p[x * 4 + 2] = UInt8((x * 2 + y + k) & 0xFF)
                        p[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            guard adaptor.append(pb, withPresentationTime: CMTime(value: Int64(k), timescale: Int32(fps)))
            else { throw A6FixtureError.ladder("append \(k)") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw A6FixtureError.ladder("finish") }
    }

    /// Scripted "system audio": a 440 Hz bed plus a 2000 Hz click burst at
    /// `clickAt`. Used to assert A/V sync and that the export does not clip.
    static func makeSystemAudio(duration: Double, clickAt: Double) -> ([Float], [Float]) {
        let n = Int(duration * AudioIO.fs)
        var l = [Float](repeating: 0, count: n)
        for i in 0..<n { l[i] = Float(0.1 * sin(2 * .pi * 440 * Double(i) / AudioIO.fs)) }
        let c0 = Int(clickAt * AudioIO.fs), c1 = min(n, Int((clickAt + 0.35) * AudioIO.fs))
        for i in c0..<c1 {
            let frac = Double(i - c0) / Double(max(c1 - c0, 1))
            let tap = min(1.0, frac / 0.05, (1 - frac) / 0.05)
            l[i] += Float(0.5 * sin(2 * .pi * 2000 * Double(i) / AudioIO.fs)) * Float(tap)
        }
        return (l, l)
    }

    /// Bundle + ProjectSession over the ladder movie, with scripted events and
    /// optional system audio installed, exactly as the export path reads them.
    static func makeSession(directory: URL, movie: URL, source: SourceInfo, timeline: Timeline,
                            events: [InputEvent] = [], systemAudio: ([Float], [Float])? = nil)
    async throws -> (ProjectSession, Renderer, Timeline) {
        let bundle = try ProjectBundle.create(named: "A6E2E", in: directory)
        try FileManager.default.copyItem(at: movie, to: bundle.screenURL)
        var data = EventCodec.header()
        for e in events {
            var record = [UInt8]()
            EventCodec.encode(e, into: &record)
            data.append(contentsOf: record)
        }
        try data.write(to: bundle.eventsURL)
        if let systemAudio { try AudioIO.writeCAF(systemAudio.0, systemAudio.1, to: bundle.systemURL) }
        var t = timeline
        t.style = flatStyle()
        var meta = ProjectMeta(name: "A6E2E", source: source, clock: RecordingClock())
        if systemAudio != nil { meta.system = TrackMeta(file: "system.caf", startHostSeconds: 0) }
        try bundle.save(ProjectFile(meta: meta, timeline: t))
        let renderer = try Renderer()
        let (session, _) = try await ProjectSession.open(bundle, device: renderer.device)
        // The timeline returned by open() is the raw project; export needs the
        // derived timeline (zoom plan + frames), exactly as the CLI does.
        return (session, renderer, session.derive(t, revision: 1))
    }

    /// Decoded video: per-frame PTS + 8x8 luma grid signature, natural size,
    /// asset duration, nominal frame rate.
    static func decodeVideo(url: URL) async throws -> (frames: [(pts: Double, sig: [Double])], width: Int, height: Int,
                                                        duration: Double, nominalFPS: Double) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw A6FixtureError.decode("reader") }
        var frames: [(Double, [Double])] = []
        while let sb = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            frames.append((CMSampleBufferGetPresentationTimeStamp(sb).seconds, Self.lumaGrid(pb)))
        }
        return (frames, Int(size.width), Int(size.height),
                try await asset.load(.duration).seconds, Double(track.nominalFrameRate))
    }

    /// Decoded audio from the exported movie as (L, R) sample arrays.
    static func decodeAudio(url: URL) throws -> ([Float], [Float]) {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let count = max(Int(file.length), 0)
        guard count > 0, fmt.channelCount >= 2, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)),
              let data = buf.floatChannelData else { throw A6FixtureError.decode("audio") }
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        return (Array(UnsafeBufferPointer(start: data[0], count: n)),
                Array(UnsafeBufferPointer(start: data[1], count: n)))
    }

    static func lumaGrid(_ pb: CVPixelBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let cells = 8
        var sums = [Double](repeating: 0, count: cells * cells)
        var counts = [Int](repeating: 0, count: cells * cells)
        for y in 0..<h {
            let cy = min(cells - 1, y * cells / max(h, 1))
            for x in 0..<w {
                let c = cy * cells + min(cells - 1, x * cells / max(w, 1))
                sums[c] += Double(base[y * stride + x * 4 + 2])
                counts[c] += 1
            }
        }
        for i in sums.indices where counts[i] > 0 { sums[i] /= Double(counts[i]) }
        return sums
    }

    static func meanAbsDiff(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return Double.greatestFiniteMagnitude / 2 }
        var s = 0.0
        for i in a.indices { s += abs(a[i] - b[i]) }
        return s / Double(a.count)
    }

    static func rms(_ ch: [Float], lo: Int, hi: Int) -> Double {
        let hi = min(hi, ch.count)
        guard hi > lo, lo >= 0, ch.indices.contains(lo) else { return 0 }
        var e = 0.0
        for i in lo..<hi { e += Double(ch[i]) * Double(ch[i]) }
        return sqrt(e / Double(hi - lo))
    }

    /// Center of the max-RMS window inside `range`; rough scan for sync checks.
    static func loudestWindowCenter(_ ch: [Float], range: ClosedRange<Double>, sampleRate: Double,
                                     window: Double = 0.08) -> Double {
        var bestCenter = -1.0, bestRMS = -1.0
        var t = range.lowerBound
        while t <= range.upperBound {
            let lo = Int(max(t - window / 2, 0) * sampleRate)
            let end = min(t + window / 2, Double(ch.count) / sampleRate)
            let hi = Int(end * sampleRate)
            let r = Self.rms(ch, lo: lo, hi: hi)
            if r > bestRMS { bestRMS = r; bestCenter = t }
            t += 0.05
        }
        return bestCenter
    }

    // MARK: - Acceptance

    @Test func syntheticRecordingExportPassesAcceptanceGates() async throws {
        let size = CGSize(width: 480, height: 270)
        let dir = try Self.tempDir("e2e")
        let ladder = dir.appendingPathComponent("ladder.mov")
        try await Self.makeLadderMovie(at: ladder, count: 150, fps: 60, size: size, step: 3)

        let source = SourceInfo(width: 480, height: 270, fps: 60, duration: 2.5,
                                backingScale: 1, originX: 0, originY: 0)
        var timeline = Timeline(duration: 2.5)
        Self.quiet(&timeline)
        // Scripted events: a click (zoom intent) at t = 1.0 s and typing keys.
        let events: [InputEvent] = [
            InputEvent(t: 1.0, kind: .down, x: 240, y: 135, button: 0),
            InputEvent(t: 1.05, kind: .up, x: 240, y: 135, button: 0),
            InputEvent(t: 1.4, kind: .keyDown, keyCode: 2),
            InputEvent(t: 1.45, kind: .keyDown, keyCode: 3),
        ]
        let (session, renderer, derived) = try await Self.makeSession(
            directory: dir, movie: ladder, source: source, timeline: timeline, events: events,
            systemAudio: Self.makeSystemAudio(duration: 2.5, clickAt: 1.0))

        // Director made zoom decisions from the scripted click events.
        #expect(!derived.zoom.isEmpty, "Director should derive zoom from the scripted click")

        var tl = derived
        // Scripted cut: [0.4, 0.6) → composition 2.3 s.
        tl.timeMap.cuts = [CutRange(start: 0.4, end: 0.6, origin: .manual)]
        // Scripted crop config: must persist and stay consistent between export and render.
        tl.smartCrop = SmartCropConfig(enabled: true, roi: CGRect(x: 0.1, y: 0.05, width: 0.8, height: 0.9))

        let out = dir.appendingPathComponent("a6-e2e.mov")
        let preset = ExportPreset(name: "a6-e2e", codec: .h264, height: 270, fps: 60)
        try await Exporter.run(session: session, timeline: tl, preset: preset, to: out,
                               includeAudio: true) { _ in }

        // ---- fps = 60, frame count, duration ----
        let video = try await Self.decodeVideo(url: out)
        #expect(video.width == preset.width(aspect: tl.style.aspectRatio),
                "width \(video.width) expected \(preset.width(aspect: tl.style.aspectRatio))")
        #expect(video.height == preset.height, "height \(video.height)")
        let expectedFrames = Int(ceil(tl.compositionDuration * 60 - 1e-8))
        #expect(video.frames.count == expectedFrames,
                "expected \(expectedFrames) frames, got \(video.frames.count)")
        #expect(abs(video.duration - tl.compositionDuration) < 0.1,
                "duration \(video.duration) expected \(tl.compositionDuration)")
        #expect(abs(video.nominalFPS - 60) <= 1, "nominal fps \(video.nominalFPS)")
        #expect(video.frames.first?.pts == 0, "first pts \(video.frames.first?.pts ?? -1)")

        // ---- constant cadence: every delta ≈ 1/60, monotonic, no duplicates ----
        for i in 1..<video.frames.count {
            let d = video.frames[i].pts - video.frames[i - 1].pts
            #expect(d > 0 && abs(d - 1 / 60) < 0.008, "frame \(i) delta \(d)")
        }

        // ---- zoom decisions + crop: decoded export matches the direct render of the same timeline ----
        var zoomCompare = 0.0
        for i in video.frames.indices where i % 12 == 0 {
            let t = video.frames[i].pts
            let direct = try await FrameImage.render(renderer: renderer, session: session, timeline: tl,
                                                     t: t, canvas: SIMD2(video.width, video.height))
            zoomCompare = max(zoomCompare, Self.meanAbsDiff(Self.lumaGrid(direct), video.frames[i].sig))
        }
        #expect(zoomCompare < 12, "decoded export differs from direct render (zoom/crop mismatch) mean \(zoomCompare)")

        // ---- crop persists through the project file ----
        try session.saveImmediately(tl)
        let reloaded = try session.bundle.load()
        #expect(reloaded.timeline.smartCrop == tl.smartCrop)
        #expect(reloaded.timeline.timeMap.cuts == tl.timeMap.cuts)

        // ---- A/V sync + audio not clipped ----
        let audio = try Self.decodeAudio(url: out)
        let report = AudioCheck.analyze(channels: [audio.0, audio.1], sampleRate: AudioIO.fs)
        #expect(report.frames > 0, "no audio decoded")
        #expect(abs(report.duration - tl.compositionDuration) < 0.15,
                "audio duration \(report.duration) expected \(tl.compositionDuration)")
        #expect(report.clippedSamples == 0, "clipped samples \(report.clippedSamples)")
        #expect(report.truePeakDb <= -1.0, "truePeakDb \(report.truePeakDb) over ceiling")
        let center = Self.loudestWindowCenter(audio.0, range: 0.9...1.5, sampleRate: AudioIO.fs)
        #expect(center >= 0.85 && center <= 1.15, "loudest window center \(center) expected ~1.0 (scripted click)")
        let near = Self.rms(audio.0, lo: Int(0.9 * AudioIO.fs), hi: Int(1.3 * AudioIO.fs))
        let far = Self.rms(audio.0, lo: Int(1.5 * AudioIO.fs), hi: Int(2.3 * AudioIO.fs))
        #expect(near > 2.5 * max(far, 0.01), "A/V sync: near \(near) far \(far)")
    }

    @Test func exportSucceedsAcrossDisplaySizeChanges() async throws {
        let size = CGSize(width: 480, height: 270)
        let dir = try Self.tempDir("dsize")
        let ladder = dir.appendingPathComponent("ladder.mov")
        try await Self.makeLadderMovie(at: ladder, count: 150, fps: 60, size: size, step: 3)
        let source = SourceInfo(width: 480, height: 270, fps: 60, duration: 2.5,
                                backingScale: 1, originX: 0, originY: 0)
        let (session, _, derived) = try await Self.makeSession(directory: dir, movie: ladder,
                                                               source: source, timeline: Timeline(duration: 2.5))
        for height in [270, 360, 540] {
            let preset = ExportPreset(name: "a6-dsize", codec: .h264, height: height, fps: 60)
            let out = dir.appendingPathComponent("dsize-\(height).mov")
            try await Exporter.run(session: session, timeline: derived, preset: preset, to: out,
                                   includeAudio: false) { _ in }
            let asset = AVURLAsset(url: out)
            let track = try await asset.loadTracks(withMediaType: .video).first
            let w = try await track?.load(.naturalSize)
            #expect(w?.height == CGFloat(preset.height), "height \(height)")
            #expect(w?.width == CGFloat(preset.width(aspect: derived.style.aspectRatio)),
                    "width for height \(height) got \(w?.width ?? -1)")
        }
    }
}

private enum A6FixtureError: Error, CustomStringConvertible {
    case ladder(String)
    case decode(String)
    var description: String {
        switch self {
        case .ladder(let s): "ladder fixture failed: \(s)"
        case .decode(let s): "decode failed: \(s)"
        }
    }
}
