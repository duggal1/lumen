import Testing
import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
@testable import LumenExport

// T1 — headless real-video end-to-end editing proof.
// Every assertion reads decoded pixels or decoded audio from an exported MP4.
// Model fields are used only to drive the next command, never as proof.

// MARK: - Wire types (driver <-> tests)

private struct T1Scenario: Codable, Sendable {
    let id: Int
    let cutStart: Double
    let cutLength: Double
    let splitOffset: Double
    let swap: Bool
    let toneHz: Double
    let caption: String
    let fps: Int
}

private struct T1Manifest: Codable, Sendable {
    let source: String
    let scenarios: [T1Scenario]
}

private struct T1Result: Codable, Sendable {
    let id: Int
    var pass: Bool
    var failures: [String]
    var metrics: [String: Double]
    var hints: [String]
}

private struct T1Results: Codable, Sendable {
    let results: [T1Result]
}

// MARK: - Deterministic parameters

private struct LCG: Sendable {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
}

private let captions = ["EDIT PROOF", "CUT VERIFIED", "合成字幕", "REORDERED", "LUMEN T1", "SPLIT AND SWAP"]

private func makeScenarios(_ count: Int) -> [T1Scenario] {
    (0..<count).map { i in
        var r = LCG(state: UInt64(i) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
        let cutStart = 0.12 + r.unit() * 0.20
        let cutLength = 0.12 + r.unit() * 0.08
        let splitOffset = 0.42 + r.unit() * 0.16
        let swap = r.next() % 2 == 0
        let toneHz = 220.0 + Double(r.next() % 660)
        let caption = captions[Int(r.next() % UInt64(captions.count))]
        let fps = r.next() % 2 == 0 ? 30 : 60
        return T1Scenario(id: i, cutStart: cutStart, cutLength: cutLength,
                          splitOffset: splitOffset, swap: swap, toneHz: toneHz,
                          caption: caption, fps: fps)
    }
}

// MARK: - Pixel signature

/// 8x8 downsampled RGB grid plus regional statistics. Sendable so it can cross
/// an async boundary without carrying a CVPixelBuffer.
private struct FrameSig: Sendable {
    let grid: [Float]            // 8 * 8 * 3, 0...1
    let meanR: Float
    let meanG: Float
    let brightLower: Int         // near-white pixels in the caption band
    let brightUpper: Int

    static func distance(_ a: FrameSig, _ b: FrameSig) -> Float {
        var s: Float = 0
        for i in 0..<min(a.grid.count, b.grid.count) { s += abs(a.grid[i] - b.grid[i]) }
        return s / Float(max(a.grid.count, 1))
    }
}

private func signature(_ pb: CVPixelBuffer) -> FrameSig {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let cells = 8
    var sums = [Float](repeating: 0, count: cells * cells * 3)
    var counts = [Float](repeating: 0, count: cells * cells)
    var rSum = 0.0, gSum = 0.0, n = 0
    var brightLower = 0, brightUpper = 0
    for y in 0..<h {
        let row = base + y * stride
        let cy = min(cells - 1, y * cells / max(h, 1))
        for x in 0..<w {
            let q = row + x * 4             // BGRA
            let r = Float(q[2]) / 255, g = Float(q[1]) / 255, b = Float(q[0]) / 255
            let c = cy * cells + min(cells - 1, x * cells / max(w, 1))
            sums[c * 3] += r; sums[c * 3 + 1] += g; sums[c * 3 + 2] += b; counts[c] += 1
            if x >= w / 4 && x < w * 3 / 4 && y >= h / 5 && y < h * 2 / 3 {
                rSum += Double(r); gSum += Double(g); n += 1
            }
            if min(q[0], q[1], q[2]) > 170 {
                if y >= h * 62 / 100 && y <= h * 94 / 100 { brightLower += 1 }
                if y >= h * 10 / 100 && y <= h * 40 / 100 { brightUpper += 1 }
            }
        }
    }
    for c in 0..<cells * cells where counts[c] > 0 {
        for k in 0..<3 { sums[c * 3 + k] /= counts[c] }
    }
    return FrameSig(grid: sums, meanR: Float(n > 0 ? rSum / Double(n) : 0),
                    meanG: Float(n > 0 ? gSum / Double(n) : 0),
                    brightLower: brightLower, brightUpper: brightUpper)
}

private func decodeSigs(_ url: URL) async throws -> [FrameSig] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { throw EditProofError.harness("no video track in \(url.path)") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    guard reader.startReading() else { throw EditProofError.harness("reader start \(url.path)") }
    var out: [FrameSig] = []
    while let sb = output.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
        out.append(signature(pb))
    }
    return out
}

private func audioFacts(_ url: URL, tone: Double) async throws -> (rms: Double, toneMag: Double, otherMag: Double, hasTrack: Bool) {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard let track = tracks.first else { return (0, 0, 0, false) }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false])
    reader.add(output)
    guard reader.startReading() else { throw EditProofError.harness("audio reader start") }
    var samples: [Float] = []
    while let sb = output.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
        var length = 0
        var total = 0
        var data: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: &length,
                                          totalLengthOut: &total, dataPointerOut: &data) == noErr,
              let data else { continue }
        let count = length / MemoryLayout<Float>.size
        data.withMemoryRebound(to: Float.self, capacity: count) { floats in
            samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
        }
    }
    guard !samples.isEmpty else { return (0, 0, 0, true) }
    var square = 0.0
    for v in samples { square += Double(v) * Double(v) }
    let rms = sqrt(square / Double(samples.count))
    // Interleaved stereo: take one channel, a window away from the encoder's priming.
    let mono = stride(from: samples.count / 4, to: samples.count * 3 / 4, by: 2).map { samples[$0] }
    let window = Array(mono.prefix(16_384))
    let fs = AudioIO.fs
    func mag(_ f: Double) -> Double {
        guard window.count > 64, f > 20, f < fs / 2 else { return 0 }
        let w = 2 * Double.pi * f / fs
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in window { let s0 = Double(v) + coeff * s1 - s2; s2 = s1; s1 = s0 }
        return sqrt(max(0, s1 * s1 + s2 * s2 - coeff * s1 * s2)) / Double(window.count)
    }
    let toneMag = mag(tone)
    let control = [mag(tone * 0.55), mag(tone * 1.63), mag(137.0)].sorted()[1]
    return (rms, toneMag, control, true)
}

private enum EditProofError: Error {
    case harness(String)
}

// MARK: - Fixtures

private func flatStyle() -> Style {
    var s = Style()
    s.background = .solid
    s.colors = [RGBA(0x000000), RGBA(0x000000)]
    s.padding = 0
    s.cornerRadius = 0
    s.shadow = 0
    s.innerBorder = false
    s.contentScale = 1
    s.customAspect = 16.0 / 9.0
    return s
}

/// Real H.264 movie: first 30 frames flat red, next 30 flat green. The two tones
/// are an exact oracle for split + reorder on decoded pixels.
private func makeTwoToneMovie(_ url: URL) async throws {
    // The scratch dir survives between runs. AVAssetWriter refuses to start on
    // an existing target, so clear the cached fixture before regenerating it.
    if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
    let w = 480, h = 270, fps = 30
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    guard writer.canAdd(input) else { throw EditProofError.harness("two-tone input") }
    writer.add(input)
    guard writer.startWriting() else { throw EditProofError.harness("two-tone start") }
    writer.startSession(atSourceTime: .zero)
    for k in 0..<60 {
        guard let pb = FrameImage.makeBuffer(w, h) else { throw EditProofError.harness("no pixel buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        // The edit uses only the first 1.0 s of this 2.0 s movie, and splits it
        // at 0.42...0.58 s. Green must start before the earliest split or both
        // halves stay red and the reorder proof becomes vacuous.
        let r: UInt8 = k < 12 ? 225 : 20, g: UInt8 = k < 12 ? 20 : 225
        for y in 0..<h {
            let row = base + y * CVPixelBufferGetBytesPerRow(pb)
            for x in 0..<w { row[x * 4] = 20; row[x * 4 + 1] = g; row[x * 4 + 2] = r; row[x * 4 + 3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        guard adaptor.append(pb, withPresentationTime: CMTime(value: Int64(k), timescale: Int32(fps))) else {
            throw EditProofError.harness("two-tone append \(k)")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw EditProofError.harness("two-tone finish") }
}

private func makeMusic(_ url: URL, hz: Double) throws {
    let fs = Int(AudioIO.fs), n = fs * 2
    let x = (0..<n).map { Float(0.28 * sin(2 * Double.pi * hz * Double($0) / Double(fs))) }
    try AudioIO.writeWAV(x, x, to: url)
}

private func writePNG(_ pb: CVPixelBuffer, to url: URL) {
    guard let image = FrameImage.cgImage(pb),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

private func evidencePNGs(_ movie: URL, _ dir: URL, ids: [Int], prefix: String) async throws {
    let asset = AVURLAsset(url: movie)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out)
    guard reader.startReading() else { return }
    var i = 0
    while let sb = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) {
        if ids.contains(i) { writePNG(pb, to: dir.appendingPathComponent("\(prefix)-\(String(format: "%03d", i)).png")) }
        i += 1
    }
}

// MARK: - One scenario

private func runScenario(_ s: T1Scenario, root: URL, source: URL, side: URL,
                         sourceSigs: [FrameSig], renderer: Renderer) async -> T1Result {
    var result = T1Result(id: s.id, pass: true, failures: [], metrics: [:], hints: [])
    func fail(_ message: String, _ hint: String? = nil) {
        result.pass = false
        result.failures.append(message)
        if let hint { result.hints.append(hint) }
    }
    do {
        let work = root.appendingPathComponent("s\(String(format: "%03d", s.id))", isDirectory: true)
        // The scratch root survives between runs (and between filtered tests).
        // A stale E2E.lumen makes copyItem throw on the very first scenario,
        // which would fail all 100 for a harness reason rather than a product one.
        if FileManager.default.fileExists(atPath: work.path) {
            try? FileManager.default.removeItem(at: work)
        }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let bundle = try ProjectBundle.create(named: "E2E", in: work)
        try FileManager.default.copyItem(at: source, to: bundle.screenURL)
        try EventCodec.header().write(to: bundle.eventsURL)
        let music = work.appendingPathComponent("bed.wav")
        try makeMusic(music, hz: s.toneHz)

        var timeline = Timeline(duration: 1.0)
        timeline.style = flatStyle()
        timeline.camera.autoZoom = false
        timeline.captions.enabled = false
        timeline.cursor.clickEffect = .none
        timeline.audio.speedRampsAuto = false
        timeline.audio.clickSounds = false
        timeline.audio.whooshes = false
        timeline.audio.keySounds = false
        timeline.audio.musicPath = nil
        let meta = ProjectMeta(name: "E2E", source: SourceInfo(width: 480, height: 270, fps: 60,
                                                               duration: 1, backingScale: 1,
                                                               originX: 0, originY: 0),
                               clock: RecordingClock())
        try bundle.save(ProjectFile(meta: meta, timeline: timeline))
        let (session, loaded) = try await ProjectSession.open(bundle, device: renderer.device)
        timeline = loaded
        func apply(_ c: Command) throws {
            let ctx = ReduceContext(playhead: 0, selection: nil,
                                    duration: timeline.compositionDuration, fps: Double(s.fps))
            _ = try reduce(&timeline, c, ctx: ctx)
        }

        // 1. open
        var derived = session.derive(timeline, revision: 1)
        guard derived.derived != nil else {
            fail("open: derived timeline is nil", "Sources/LumenDirector/Director.swift:derive")
            return result
        }
        result.metrics["open_derived"] = 1

        // 2. cut a span (source seconds)
        try apply(.addCut(start: s.cutStart, end: s.cutStart + s.cutLength))
        derived = session.derive(timeline, revision: 2)
        let recordingOut = derived.timeMap.outputDuration
        result.metrics["recording_out"] = recordingOut

        // 3. split — add the companion clip, then split it in two.
        let clipStart = recordingOut
        try apply(.addClip(TimelineClip(path: side.path, name: "side", duration: 1.0,
                                        start: clipStart, width: 480, height: 270)))
        guard let whole = timeline.clips.first else {
            fail("split: no clip after addClip", "Sources/LumenProject/Commands.swift:180")
            return result
        }
        try apply(.splitClip(atOutput: clipStart + s.splitOffset))
        guard timeline.clips.count == 2 else {
            fail("split: expected 2 clips, got \(timeline.clips.count)", "Sources/LumenProject/Commands.swift:199")
            return result
        }
        result.metrics["split_clips"] = Double(timeline.clips.count)

        // 4. reorder — put the green tail before the red head.
        let rightID = timeline.clips.max { $0.start < $1.start }!.id
        if s.swap { try apply(.reorderClip(id: rightID, toIndex: 0)) }
        result.metrics["swapped"] = s.swap ? 1 : 0

        // Baseline for the caption pixel diff: same edit, no text block.
        let noText = timeline
        let noTextDerived = session.derive(noText, revision: 3)

        // 5. music (output-time bed) and 6. caption (manual text block).
        var plan = timeline.audio
        plan.musicPath = music.path
        plan.musicGainDb = -6
        try apply(.setAudio(plan))
        try apply(.addText(TextBlock(start: 0, end: 10, text: s.caption,
                                     x: 0.5, y: 0.86, size: 0.10)))
        derived = session.derive(timeline, revision: 4)
        guard derived.derived != nil else { fail("final derive: nil derived"); return result }

        // 7. export through the exact production path.
        let movie = work.appendingPathComponent("export.mp4")
        let preset = ExportPreset(name: "t1", codec: .h264, height: 270, fps: s.fps)
        try await Exporter.run(session: session, timeline: derived, preset: preset,
                               to: movie, includeAudio: true) { _ in }
        guard FileManager.default.fileExists(atPath: movie.path) else {
            fail("export: no output file", "Sources/LumenExport/Exporter.swift:89")
            return result
        }

        // Read back with AVFoundation — no player, decoded pixels only.
        let frames = try await decodeSigs(movie)
        let expectedFrames = Int(ceil(derived.compositionDuration * Double(s.fps) - 1e-8))
        result.metrics["frames"] = Double(frames.count)
        result.metrics["expected_frames"] = Double(expectedFrames)
        if abs(frames.count - expectedFrames) > 1 {
            fail("frame count \(frames.count) != \(expectedFrames)", "Sources/LumenExport/Exporter.swift:113")
        }
        if frames.isEmpty { fail("export produced zero frames"); return result }

        func frame(at t: Double) -> FrameSig {
            let i = min(max(Int((t * Double(s.fps)).rounded()), 0), frames.count - 1)
            return frames[i]
        }
        func nearestSource(_ t: Double) -> Int {
            // The frame reader sample-and-holds: it returns the newest decoded
            // frame whose PTS is <= the requested source time, i.e. floor, not
            // nearest. Using .rounded() here made a seam probe disagree with the
            // exported frame by exactly one source frame.
            min(max(Int((t * 60).rounded(.down)), 0), sourceSigs.count - 1)
        }

        // 2b. cut proof: exported pixels map to the post-cut source frame.
        let afterT = s.cutStart + s.cutLength + 0.10
        let after = frame(at: afterT)
        let afterSampleT = Double(min(max(Int((afterT * Double(s.fps)).rounded()), 0), frames.count - 1)) / Double(s.fps)
        let expectedIdx = nearestSource(afterSampleT + s.cutLength)
        let wrongIdx = nearestSource(afterSampleT)
        let dExpected = FrameSig.distance(after, sourceSigs[expectedIdx])
        let dWrong = FrameSig.distance(after, sourceSigs[wrongIdx])
        result.metrics["cut_d_expected"] = Double(dExpected)
        result.metrics["cut_d_wrong"] = Double(dWrong)
        if sourceSigs.count > 1 && wrongIdx != expectedIdx {
            // Near-duplicate frames in a real recording make two absolute
            // distances noisy at the seam. Require the post-cut frame to be at
            // least as good as the pre-cut one, with 1 ms of signature slack;
            // a genuinely wrong side is far outside that band.
            if dExpected > dWrong + 0.001 {
                fail("cut: frame at \(String(format: "%.3f", afterT))s matches pre-cut source \(wrongIdx) (\(dWrong)) instead of post-cut \(expectedIdx) (\(dExpected))",
                     "Sources/LumenProject/Commands.swift:75 / Sources/LumenDirector/Director.swift:539")
            }
        }
        let beforeT = s.cutStart * 0.5
        let before = frame(at: beforeT)
        let dBefore = FrameSig.distance(before, sourceSigs[nearestSource(beforeT)])
        let dBeforeWrong = FrameSig.distance(before, sourceSigs[nearestSource(beforeT + s.cutLength)])
        if dBefore > dBeforeWrong + 0.004 {
            fail("cut: pre-cut frame was altered (expected \(dBefore), got \(dBeforeWrong))")
        }

        // 3b+4b. split + reorder proof: flat red/green channel dominance.
        let firstHalf = frame(at: clipStart + 0.25)
        let secondHalf = frame(at: clipStart + 0.75)
        let firstGreen = firstHalf.meanG > firstHalf.meanR + 0.06
        let secondGreen = secondHalf.meanG > secondHalf.meanR + 0.06
        result.metrics["clip1_R"] = Double(firstHalf.meanR)
        result.metrics["clip1_G"] = Double(firstHalf.meanG)
        result.metrics["clip2_R"] = Double(secondHalf.meanR)
        result.metrics["clip2_G"] = Double(secondHalf.meanG)
        let wantGreenFirst = s.swap
        if firstGreen != wantGreenFirst || secondGreen == wantGreenFirst {
            fail("reorder: first half green=\(firstGreen), second half green=\(secondGreen), expected greenFirst=\(wantGreenFirst)",
                 "Sources/LumenProject/Commands.swift:299 / Sources/LumenRender/Renderer.swift:96")
        }

        // 6b. caption proof: bright text in the lower third of a flat clip frame.
        let captionFrame = frame(at: clipStart + 0.25)
        let baseline = try await FrameImage.render(renderer: renderer, session: session,
                                                   timeline: noTextDerived,
                                                   t: clipStart + 0.25, canvas: SIMD2(480, 270))
        let baselineSig = signature(baseline)
        result.metrics["caption_bright"] = Double(captionFrame.brightLower)
        result.metrics["baseline_bright"] = Double(baselineSig.brightLower)
        if captionFrame.brightLower < 25 || captionFrame.brightLower <= baselineSig.brightLower + 10 {
            fail("caption: no visible text pixels (export \(captionFrame.brightLower), baseline \(baselineSig.brightLower))",
                 "Sources/LumenRender/Renderer.swift:1127 / Sources/LumenDirector/Emphasis.swift:132")
        }
        if captionFrame.brightUpper > 20 {
            fail("caption: bright pixels leaked outside the lower third (\(captionFrame.brightUpper))")
        }

        // 5b. music proof: an AAC bed with energy at the seeded tone.
        let audio = try await audioFacts(movie, tone: s.toneHz)
        result.metrics["audio_rms"] = audio.rms
        result.metrics["audio_tone"] = audio.toneMag
        result.metrics["audio_other"] = audio.otherMag
        if !audio.hasTrack { fail("export has no audio track", "Sources/LumenExport/Exporter.swift:159") }
        else if audio.rms < 0.002 { fail("audio bed is silent (rms \(audio.rms))", "Sources/LumenAudio/Mixer.swift:615") }
        else if audio.toneMag < audio.otherMag * 3 {
            fail("no \(Int(s.toneHz)) Hz bed (tone \(audio.toneMag), other \(audio.otherMag))", "Sources/LumenAudio/Mixer.swift:615")
        }

        if s.id == 0 || s.id == 1 {
            let dir = root.appendingPathComponent("frames", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await evidencePNGs(movie, dir, ids: [0, 2, max(0, expectedFrames / 2)], prefix: "s\(s.id)-export")
        }
    } catch {
        fail("threw: \(error)")
    }
    return result
}

// MARK: - Sweep

@Suite struct RealVideoEditE2ETests {
    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func loadManifest(source: URL) throws -> T1Manifest {
        let env = ProcessInfo.processInfo.environment
        if let path = env["T1_SCENARIOS_FILE"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let manifest = try? JSONDecoder().decode(T1Manifest.self, from: data) {
            return manifest
        }
        let count = Int(env["T1_SCENARIOS"] ?? "100") ?? 100
        return T1Manifest(source: source.path, scenarios: makeScenarios(count))
    }

    @Test func fullEditingPipelineOnRealVideo100SeededScenarios() async throws {
        let root = Self.repoRoot()
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: env["T1_SOURCE"] ?? root.appendingPathComponent(".proof/visual/sequence.mp4").path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            Issue.record("missing real video \(source.path)")
            return
        }
        let manifest = try Self.loadManifest(source: source)
        let only = env["T1_SCENARIO_FILTER"].flatMap(Int.init)
        let scenarios = manifest.scenarios.filter { only == nil || $0.id == only! }
        let scratch = URL(fileURLWithPath: env["T1_SCRATCH"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("lumen-t1-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let renderer = try Renderer()
        let sourceSigs = try await decodeSigs(source)
        #expect(sourceSigs.count == 60, "real sequence must decode 60 frames, got \(sourceSigs.count)")
        let side = scratch.appendingPathComponent("side.mov")
        // Regenerate every run: a cached movie from an older colour split would
        // make the reorder proof silently meaningless.
        try await makeTwoToneMovie(side)
        let sideSigs = try await decodeSigs(side)
        #expect(sideSigs.count == 60, "two-tone fixture must decode 60 frames")

        var results: [T1Result] = []
        for s in scenarios {
            let r = await runScenario(s, root: scratch, source: source, side: side,
                                      sourceSigs: sourceSigs, renderer: renderer)
            results.append(r)
        }
        if let path = env["T1_RESULTS_FILE"] {
            let data = try JSONEncoder().encode(T1Results(results: results))
            try data.write(to: URL(fileURLWithPath: path))
        }
        let failed = results.filter { !$0.pass }
        for r in failed.prefix(12) {
            Issue.record("scenario \(r.id): \(r.failures.joined(separator: " | "))")
        }
        #expect(failed.isEmpty, "real-video E2E: \(failed.count)/\(results.count) scenarios FAILED")
    }

    @Test func smokeSingleScenarioIsNotVacuous() async throws {
        let root = Self.repoRoot()
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["T1_SOURCE"]
            ?? root.appendingPathComponent(".proof/visual/sequence.mp4").path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            Issue.record("fixture missing: .proof/visual/sequence.mp4")
            return
        }
        let sigs = try await decodeSigs(source)
        // A vacuous suite would pass even when the source frames are identical.
        #expect(FrameSig.distance(sigs[0], sigs[30]) > 0.002,
                "source frames 0 and 30 must differ; otherwise the pixel oracle is vacuous")
    }
}
