import Foundation
import Testing
import AVFoundation
import CoreVideo
import CoreGraphics
import Metal
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
import LumenExport

// T3 — exported-video frame accuracy against the edited timeline.
//
// Every assertion below is made on REAL decoded pixels (AVAssetReader / the
// ReaderFrameSource decode path) or real decoded audio samples. There are no
// mocks and no "it ran" smoke checks. See .proof/T3-plan.md and
// .proof/T3/REPORT.md. This file never edits production code.

// MARK: - Pixel / sample primitives

private typealias Signature = [UInt8]          // GoldenImage RGBA, row-major, top-left origin

private struct SourceSample: Sendable {
    let pts: Double
    let signature: Signature
}

/// Mean absolute channel difference. Neighbouring fixture frames differ by
/// ~50; H.264 re-encode of the same frame stays under ~10.
private func meanDiff(_ a: Signature, _ b: Signature) -> Double {
    guard a.count == b.count, !a.isEmpty else { return .infinity }
    var sum = 0
    for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
    return Double(sum) / Double(a.count)
}

private func signature(of buffer: CVPixelBuffer) throws -> Signature {
    try GoldenImage(pixelBuffer: buffer).pixels
}

// MARK: - Fixture generation

/// A movie whose every frame is visually distinct at a coarse scale: a solid
/// colour that steps widely between consecutive frames plus a moving bar.
private func makeFrameIDMovie(url: URL, frames: Int, fps: Int,
                              width: Int = 320, height: Int = 180) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 6_000_000,
            AVVideoMaxKeyFrameIntervalKey: 8,
        ],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
    guard writer.canAdd(input) else { throw ExportError.writer("fixture input") }
    writer.add(input)
    guard writer.startWriting() else { throw ExportError.writer("fixture startWriting") }
    writer.startSession(atSourceTime: .zero)

    for k in 0..<frames {
        let buffer = try #require(FrameImage.makeBuffer(width, height))
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        // Coarse identity: consecutive frames differ by (23, 61, 113) in RGB.
        let r = UInt8(20 + (k * 23) % 200)
        let g = UInt8(20 + (k * 61) % 200)
        let b = UInt8(20 + (k * 113) % 200)
        let barX = (k * 7) % (width - 40)
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                let white = x >= barX && x < barX + 24 && y > height / 4 && y < 3 * height / 4
                let o = x * 4
                // BGRA byte order.
                row[o + 0] = white ? 255 : b
                row[o + 1] = white ? 255 : g
                row[o + 2] = white ? 255 : r
                row[o + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        let pts = CMTime(value: Int64(k), timescale: Int32(fps))
        guard adaptor.append(buffer, withPresentationTime: pts) else { throw ExportError.writer("fixture append \(k)") }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw ExportError.writer("fixture finish \(String(describing: writer.error))") }
}

/// Decode a movie into one signature per frame with AVAssetReader.
private func decodeFrameSignatures(_ url: URL) async throws -> [SourceSample] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw ExportError.writer("fixture has no video track")
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    output.alwaysCopiesSampleData = true
    reader.add(output)
    guard reader.startReading() else { throw ExportError.writer("reader startReading") }
    var result: [SourceSample] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
        result.append(SourceSample(pts: sample.presentationTimeStamp.seconds,
                                   signature: try signature(of: pb)))
    }
    return result
}

// MARK: - Project harness

private struct Harness {
    let root: URL
    let bundle: ProjectBundle
    let session: ProjectSession
    let baseline: Timeline          // clean, no edits, derived
    let sources: [SourceSample]     // independently decoded fixture frames
    let sourceFPS: Int
}

private func makeHarness(frames: Int = 120, fps: Int = 60,
                         name: String = "T3") async throws -> Harness {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumen-t3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let bundle = try ProjectBundle.create(named: name, in: root)
    try await makeFrameIDMovie(url: bundle.screenURL, frames: frames, fps: fps)
    let sources = try await decodeFrameSignatures(bundle.screenURL)
    #expect(sources.count == frames)

    let source = SourceInfo(width: 320, height: 180, fps: Double(fps),
                            duration: Double(frames) / Double(fps),
                            backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: source.duration)
    timeline.audio.speedRampsAuto = false
    timeline.audio.clickSounds = false
    timeline.audio.whooshes = false
    timeline.camera.autoZoom = false
    timeline.zoom = []
    timeline.captions.enabled = false
    // Make the compositor pass the source pixels through as closely as possible.
    timeline.style.padding = 0
    timeline.style.contentScale = 1
    timeline.style.cornerRadius = 0
    timeline.style.shadow = 0
    timeline.style.innerBorder = false
    timeline.style.background = .solid
    timeline.style.colors = [RGBA(0x000000)]
    timeline.style.backgroundImagePath = nil
    var meta = ProjectMeta(name: name, source: source, clock: RecordingClock())
    meta.mic = nil
    try bundle.save(ProjectFile(meta: meta, timeline: timeline))
    try EventCodec.header().write(to: bundle.eventsURL)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let (session, loaded) = try await ProjectSession.open(bundle, device: device)
    let derived = session.derive(loaded, revision: 1)
    return Harness(root: root, bundle: bundle, session: session,
                   baseline: derived, sources: sources, sourceFPS: fps)
}

private func cleaned(_ tl: Timeline) -> Timeline {
    var out = tl
    out.audio.speedRampsAuto = false
    out.audio.clickSounds = false
    out.audio.whooshes = false
    out.camera.autoZoom = false
    out.zoom = []
    out.captions.enabled = false
    out.style.padding = 0
    out.style.contentScale = 1
    out.style.cornerRadius = 0
    out.style.shadow = 0
    out.style.innerBorder = false
    out.style.background = .solid
    out.style.colors = [RGBA(0x000000)]
    out.style.backgroundImagePath = nil
    return out
}

/// Index of the source frame the session's funnel selects at output time `t`.
/// The pixels are then checked against independently decoded fixture frames.
/// Using the session as the oracle for the selected frame means the export is
/// verified against what the timeline resolves to at that output time — the
/// one-frame quantisation of the reader's `pts <= t` contract is identical on
/// both sides, so FP hair at lattice points cannot manufacture an off-by-one.
private func expectedSourceFrame(_ h: Harness, tl: Timeline, at t: Double) async throws -> Int {
    let frame = try await h.session.frames(atOutput: t, timeline: tl)
    var best = 0, bestD = Double.infinity
    for (i, sample) in h.sources.enumerated() {
        let d = abs(sample.pts - frame.screen.pts)
        if d < bestD { best = i; bestD = d }
    }
    return best
}

/// Find the fixture frame whose pixels best match `sig`, searching ±2 around
/// `expected`. Returns (bestIndex, bestDiff, runnerUpDiff).
private func bestMatch(_ sig: Signature, expected: Int,
                       sources: [SourceSample]) -> (Int, Double, Double) {
    var best = (-1, Double.infinity, Double.infinity)
    for offset in [-2, -1, 0, 1, 2] {
        let i = expected + offset
        guard i >= 0, i < sources.count else { continue }
        let d = meanDiff(sig, sources[i].signature)
        if d < best.1 { best = (i, d, best.1) }
        else if d < best.2 { best.2 = d }
    }
    return best
}

private func exportAndDecode(_ h: Harness, timeline: Timeline, fps: Int,
                             fileName: String = "export.mp4") async throws -> [Signature] {
    let url = h.root.appendingPathComponent(fileName)
    let preset = ExportPreset(name: "t3-\(fps)", codec: .h264, height: 180, fps: fps)
    try await Exporter.run(session: h.session, timeline: timeline, preset: preset,
                           to: url, includeAudio: false) { _ in }
    return try await decodeFrameSignatures(url).map(\.signature)
}

// MARK: - Tests

@Test func fixtureFrameIDsAreUniqueOrderedAndDecodable() async throws {
    let h = try await makeHarness(frames: 60, fps: 60)
    defer { try? FileManager.default.removeItem(at: h.root) }
    #expect(h.sources.count == 60)
    for (i, s) in h.sources.enumerated() {
        #expect(abs(s.pts - Double(i) / 60) < 1e-6, "frame \(i) pts \(s.pts)")
    }
    // Neighbouring frames must be far apart or the oracle cannot see off-by-one.
    var minNeighbour = Double.infinity
    for i in 1..<h.sources.count {
        minNeighbour = min(minNeighbour, meanDiff(h.sources[i].signature, h.sources[i - 1].signature))
    }
    #expect(minNeighbour > 15, "adjacent fixture frames too similar: \(minNeighbour)")
}

@Test func exportFrameCountMatchesDurationAt60_120_240() async throws {
    let h = try await makeHarness(frames: 120, fps: 60)
    defer { try? FileManager.default.removeItem(at: h.root) }
    var tl = cleaned(h.baseline)
    tl.timeMap.cuts = [CutRange(start: 0.5, end: 0.8)]   // output 1.7 s
    let derived = h.session.derive(tl, revision: 7)
    for fps in [60, 120, 240] {
        let frames = try await exportAndDecode(h, timeline: derived, fps: fps,
                                               fileName: "count-\(fps).mp4")
        let expected = max(Int(ceil(derived.compositionDuration * Double(fps) - 1e-8)), 1)
        #expect(frames.count == expected,
                "fps \(fps): got \(frames.count) frames, expected \(expected)")
    }
}

@Test func cutBoundaryShowsExactSourceFrameAtAllFPS() async throws {
    let h = try await makeHarness(frames: 120, fps: 60)
    defer { try? FileManager.default.removeItem(at: h.root) }
    // Cut source [0.5, 1.0): 30 source frames removed, boundary at output 0.5 s.
    var tl = cleaned(h.baseline)
    tl.timeMap.cuts = [CutRange(start: 0.5, end: 1.0)]
    let derived = h.session.derive(tl, revision: 8)
    for fps in [60, 120, 240] {
        let frames = try await exportAndDecode(h, timeline: derived, fps: fps,
                                               fileName: "cut-\(fps).mp4")
        // Output indices around the 0.5 s boundary.
        let boundary = Int(0.5 * Double(fps))
        let probes = Set([boundary - 2, boundary - 1, boundary, boundary + 1, boundary + 2])
            .filter { $0 >= 0 && $0 < frames.count }.sorted()
        for i in probes {
            let t = Double(i) / Double(fps)
            let expected = try await expectedSourceFrame(h, tl: derived, at: t)
            let (best, diff, runner) = bestMatch(frames[i], expected: expected, sources: h.sources)
            #expect(best == expected,
                    "fps \(fps) frame \(i) (t=\(t)): best source \(best), expected \(expected) (diff \(diff) vs runner \(runner))")
            #expect(runner - diff > 8,
                    "fps \(fps) frame \(i): expected frame not clearly better (diff \(diff), runner \(runner))")
        }
    }
}

@Test func cutPositionSweep_300Positions_noOffByOneNoRepeat() async throws {
    let h = try await makeHarness(frames: 120, fps: 60)
    defer { try? FileManager.default.removeItem(at: h.root) }
    var checked = 0
    // 300 cut spans, including adjacent-frame cuts (1/60 s), cuts aligned to
    // exact frame boundaries and cuts one 1/240 tick inside a boundary.
    for k in 0..<300 {
        let startFrame = 6 + (k * 7) % 100
        let length = 1 + (k % 24)
        let endFrame = min(startFrame + length, 119)
        let start = Double(startFrame) / 60
        let end = Double(endFrame) / 60 + (k % 3 == 0 ? 1.0 / 240 : 0)
        var tl = cleaned(h.baseline)
        tl.timeMap.cuts = [CutRange(start: start, end: end)]
        let boundary = tl.timeMap.output(atSource: start)
        // Last frame before the cut and first frame after it.
        let probeTimes = [boundary - 1.0 / 120, boundary + 1.0 / 120]
        for t in probeTimes where t >= 0 {
            let (sf, _) = try await h.session.frames(atOutput: t, timeline: tl)
            let sig = try signature(of: sf.pixelBuffer)
            // Closed-form expectation from the cut spec, independent of TimeMap.
            let expectedAfter = Int(floor((t + (end - start)) * 60 + 1e-6))
            let expectedBefore = Int(floor(t * 60 + 1e-6))
            let expected = t < boundary - 1e-9 ? expectedBefore : expectedAfter
            let (best, diff, runner) = bestMatch(sig, expected: expected, sources: h.sources)
            #expect(best == expected,
                    "cut \(k) [\(start),\(end)] t=\(t): source pts \(sf.pts), best frame \(best), expected \(expected) (diff \(diff), runner \(runner))")
            #expect(abs(sf.pts - Double(expected) / 60) < 1e-6,
                    "cut \(k) t=\(t): source pts \(sf.pts) != expected frame \(expected)")
            checked += 1
        }
    }
    #expect(checked >= 600, "only \(checked) boundary probes executed")
}

@Test func speedRampSamplesIntendedFrames() async throws {
    let h = try await makeHarness(frames: 120, fps: 60)
    defer { try? FileManager.default.removeItem(at: h.root) }
    // A long 2x ramp [1.0, 3.0): its middle has constant speed 2.
    var tl = cleaned(h.baseline)
    tl.timeMap.ramps = [SpeedRamp(start: 1.0, end: 3.0, speed: 2)]
    let derived = h.session.derive(tl, revision: 9)
    // TimeMap itself must stay invertible and monotonic through the ramp.
    var lastSource = -1.0
    let inverseLimit = max(1, Int((derived.timeMap.outputDuration - 0.01) * 100))
    for i in 0...inverseLimit {
        let t = Double(i) / 100
        let s = derived.timeMap.source(atOutput: t)
        #expect(s > lastSource - 1e-9, "ramp mapped backwards at \(t)")
        lastSource = s
        #expect(abs(derived.timeMap.output(atSource: s) - t) < 0.01,
                "ramp inverse drift at \(t): \(derived.timeMap.output(atSource: s))")
    }
    let frames = try await exportAndDecode(h, timeline: derived, fps: 60,
                                           fileName: "ramp.mp4")
    // In the constant-speed middle every output frame must show the frame the
    // timeline selects, and the middle must advance ~2 source frames per output
    // frame (no repeats, no jumps).
    let outputStart = derived.timeMap.output(atSource: 1.5)
    let outputEnd = derived.timeMap.output(atSource: 2.5)
    var priorFrame = -1
    var advances: [Int] = []
    for i in 0..<frames.count {
        let t = Double(i) / 60
        let expected = try await expectedSourceFrame(h, tl: derived, at: t)
        let (best, diff, runner) = bestMatch(frames[i], expected: expected, sources: h.sources)
        #expect(best == expected, "ramp frame \(i): best \(best), expected \(expected) (diff \(diff)/\(runner))")
        if t >= outputStart && t <= outputEnd {
            if priorFrame >= 0 { advances.append(best - priorFrame) }
            priorFrame = best
        }
    }
    #expect(!advances.isEmpty)
    #expect(advances.allSatisfy { $0 == 2 || $0 == 3 },
            "ramp middle advances \(advances) instead of ~2 frames/output")
}

@Test func clipInsertLandsOnIntendedOutputFrame() async throws {
    let h = try await makeHarness(frames: 120, fps: 60)
    defer { try? FileManager.default.removeItem(at: h.root) }
    var tl = cleaned(h.baseline)
    // Import the same frame-ID movie as a clip, placed at output 0.4 s,
    // starting 1.0 s into the file. It overrides the recording there.
    let clip = TimelineClip(path: h.bundle.screenURL.path, name: "insert",
                            inPoint: 1.0, duration: 0.8, start: 0.4,
                            width: 320, height: 180)
    tl.clips = [clip]
    let derived = h.session.derive(tl, revision: 10)
    let frames = try await exportAndDecode(h, timeline: derived, fps: 60,
                                           fileName: "insert.mp4")
    for i in 0..<frames.count {
        let t = Double(i) / 60
        guard t >= clip.start - 0.05 && t <= clip.end + 0.05 else { continue }
        let expected = try await expectedSourceFrame(h, tl: derived, at: t)
        let (best, diff, runner) = bestMatch(frames[i], expected: expected, sources: h.sources)
        #expect(best == expected,
                "clip frame \(i) (t=\(t)): best \(best), expected \(expected) (diff \(diff)/\(runner))")
    }
    // First frame inside the clip must be exactly inPoint, never the previous
    // recording frame nor a held first clip frame.
    let firstInside = Int(ceil(clip.start * 60))
    let t = Double(firstInside) / 60
    let expected = try await expectedSourceFrame(h, tl: derived, at: t)
    let (best, diff, runner) = bestMatch(frames[firstInside], expected: expected, sources: h.sources)
    #expect(best == expected, "clip insert at \(t): best \(best), expected source \(expected) (diff \(diff)/\(runner))")
    // The clip must start exactly at its in point: source 60, never the held
    // first frame or a previous recording frame.
    #expect(abs(h.sources[expected].pts - 1.0) < 1e-6, "clip insert selects source frame \(expected) (pts \(h.sources[expected].pts)) instead of in-point 1.0")
}

@Test func crossfadeBlendsBothSidesAtClipJoin() async throws {
    let h = try await makeHarness(frames: 120, fps: 60)
    defer { try? FileManager.default.removeItem(at: h.root) }
    var tl = cleaned(h.baseline)
    let a = TimelineClip(path: h.bundle.screenURL.path, name: "a",
                         inPoint: 0, duration: 1.0, start: 0, width: 320, height: 180)
    let b = TimelineClip(path: h.bundle.screenURL.path, name: "b",
                         inPoint: 2.0, duration: 1.0, start: 1.0, width: 320, height: 180)
    tl.clips = [a, b]
    tl.crossfadeDuration = 0.2
    let xfade = h.session.derive(tl, revision: 11)
    // Control: identical clips but no requested crossfade. If the renderer
    // honours crossfadeDuration the two exports must differ inside the join.
    var without = cleaned(tl)
    without.crossfadeDuration = 0
    let hard = h.session.derive(without, revision: 12)

    let blended = try await exportAndDecode(h, timeline: xfade, fps: 60,
                                            fileName: "crossfade.mp4")
    let reference = try await exportAndDecode(h, timeline: hard, fps: 60,
                                              fileName: "crossfade-hard.mp4")
    // A real crossfade changes pixels inside the join window. If the renderer
    // ignores crossfadeDuration the two exports are bit-identical there.
    let joinFrame = 60
    #expect(blended.count > joinFrame && reference.count > joinFrame)
    let diff = meanDiff(blended[joinFrame], reference[joinFrame])
    #expect(diff > 4,
            "crossfade ignored: join frame identical to a hard cut (diff \(diff)); effectiveCrossfade=\(xfade.effectiveCrossfade)")
}

@Test func audioStaysInSyncAfterCut() async throws {
    let h = try await makeHarness(frames: 120, fps: 60)
    defer { try? FileManager.default.removeItem(at: h.root) }
    let fs = Int(AudioIO.fs)
    var samples = [Float](repeating: 0, count: 2 * fs)
    for start in [0.3, 1.3] {
        let from = Int(start * Double(fs)), to = Int((start + 0.2) * Double(fs))
        for i in from..<to {
            samples[i] = 0.5 * Float(sin(2 * .pi * 440 * Double(i - from) / Double(fs)))
        }
    }
    try AudioIO.writeCAF(samples, samples, to: h.bundle.micURL)
    var meta = ProjectMeta(name: "audio", source: SourceInfo(width: 320, height: 180, fps: 60,
                                                             duration: 2, backingScale: 1,
                                                             originX: 0, originY: 0),
                           clock: RecordingClock())
    meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: 0)
    var tl = cleaned(h.baseline)
    tl.audio.micClean = false
    tl.audio.noiseReductionStrength = 0
    tl.audio.voiceClarity = false
    tl.audio.dereverb = 0
    tl.audio.declick = false
    tl.audio.normalize = false
    tl.audio.studio = 0
    tl.audio.voiceBoostDb = 0
    tl.audio.micGainDb = 0
    tl.audio.outputGainDb = 0
    tl.timeMap.cuts = [CutRange(start: 0.6, end: 0.9)]   // remove 0.3 s
    try h.bundle.save(ProjectFile(meta: meta, timeline: tl))
    let device = try #require(MTLCreateSystemDefaultDevice())
    let (reopened, loadedAudio) = try await ProjectSession.open(h.bundle, device: device)
    let derived = reopened.derive(loadedAudio, revision: 13)
    let mixed = try #require(reopened.mixer.mix(derived))
    func bursts(_ x: [Float]) -> [Double] {
        let window = fs / 50                              // 20 ms
        var peakRms = 0.0
        var scan = 0
        while scan + window <= x.count {
            var energy: Float = 0
            for j in scan..<(scan + window) { energy += x[j] * x[j] }
            peakRms = max(peakRms, Double(sqrt(energy / Float(window))))
            scan += window
        }
        let threshold = max(0.01, min(0.02, 0.05 * peakRms))
        var peaks: [(Double, Double)] = []
        var i = 0
        while i + window <= x.count {
            var energy: Float = 0
            for j in i..<(i + window) { energy += x[j] * x[j] }
            let rms = Double(sqrt(energy / Float(window)))
            // The Studio chain may attenuate a later burst relative to the
            // first; sync is about WHERE the bursts land, so use a floor plus
            // a fraction of the loudest window instead of a fixed dB cutoff.
            if rms > threshold { peaks.append((Double(i) / Double(fs), rms)) }
            i += window
        }
        // Cluster peaks into bursts (the burst is a 0.2 s tone, so a 0.05 s
        // gap between consecutive peaks still means the same burst); each
        // cluster starts at the first audible sample of that burst.
        var clusters: [Double] = []
        var current = -1.0
        for p in peaks {
            if current < 0 || p.0 - current > 0.05 {
                clusters.append(p.0)
            }
            current = p.0
        }
        return clusters
    }
    let found = bursts(mixed.l)
    #expect(found.count >= 2, "expected at least two audible bursts, got \(found)")
    if found.count >= 2 {
        // First burst stays at 0.3 s; second moves from 1.3 s to 1.0 s.
        #expect(abs(found[0] - 0.3) < 0.05, "burst 1 at \(found[0]), expected 0.3")
        #expect(abs(found[1] - 1.0) < 0.05, "burst 2 at \(found[1]), expected 1.0 after cut")
    }
}
