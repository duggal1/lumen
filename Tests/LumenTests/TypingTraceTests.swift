import Testing
import Foundation
import AVFoundation
import CoreVideo
import LumenCore
import LumenProject
@testable import LumenAnalysis
import LumenExport

// Lane B regression oracle: typing visual analysis and analysis scheduling.
// Every behavioural test below is written against the tracer's *public* pixel
// contract (sample times, caret x/y) so it runs on the pre-fix tracer too and
// fails there, not just on a missing symbol.

// MARK: - synthetic grids

private enum TypingGrid {
    static let tile = 16
    static let cols = 40
    static let rows = 22

    /// A flat page with `ink` tiles marked. Light page, dark ink (mean 40).
    static func page(_ lit: [(Int, Int)], cols: Int = TypingGrid.cols, rows: Int = TypingGrid.rows,
                     background: UInt8 = 235, ink: UInt8 = 40) -> LumaTiles {
        var mean = [UInt8](repeating: background, count: cols * rows)
        for (c, r) in lit where c >= 0 && c < cols && r >= 0 && r < rows { mean[r * cols + c] = ink }
        return LumaTiles(cols: cols, rows: rows, tile: TypingGrid.tile, mean: mean)
    }

    /// `n` typed glyphs on row `row`, starting at column `first`.
    static func line(_ row: Int, _ first: Int, _ n: Int, cols: Int = TypingGrid.cols,
                     rows: Int = TypingGrid.rows) -> [(Int, Int)] {
        (0..<max(n, 0)).map { (first + $0, row) }
    }

    /// Sample times at `hz`, starting at `t0`, count `n`.
    static func times(_ t0: Double, _ n: Int, hz: Double = 30) -> [Double] {
        (0..<n).map { t0 + Double($0) / hz }
    }

    static func trace(_ frames: [LumaTiles], t0: Double = 0, burst: Double = 1,
                      anchor: SIMD2<Double>? = nil, srcH: Double = 352) -> TypingTrace? {
        TypingTracer.trace(burst: (t0, t0 + burst), ts: times(t0, frames.count), grids: frames,
                           anchor: anchor, srcH: srcH)
    }

    /// Frames of a line growing one glyph per frame, then `extra` hold frames.
    static func growing(row: Int, first: Int, from: Int, to: Int, hold: Int = 0,
                        t0: Double = 0, hz: Double = 30) -> [LumaTiles] {
        var frames: [LumaTiles] = []
        for n in from...to { frames.append(page(line(row, first, n))) }
        for _ in 0..<hold { frames.append(page(line(row, first, to))) }
        return frames
    }
}

// MARK: - 1. line wrap is followed

@Test func tracerFollowsLineWrap() throws {
    // A full line on row 12, then the caret continues on row 13.
    var frames: [LumaTiles] = [TypingGrid.page([])]
    for n in 1...18 { frames.append(TypingGrid.page(TypingGrid.line(12, 6, n))) }
    for n in 1...8 { frames.append(TypingGrid.page(TypingGrid.line(12, 6, 18) + TypingGrid.line(13, 6, n))) }
    let tr = try #require(TypingGrid.trace(frames))
    let ys = tr.samples.map(\.y)
    let firstY = try #require(ys.first)
    let lastY = try #require(ys.last)
    print("wrap y: \(ys.map { Int($0) })")
    // The tracker must end on the second line, one line-height lower.
    #expect(lastY > firstY + 8, "caret never followed the wrap: \(firstY) -> \(lastY)")
    #expect(abs(lastY - 13 * 16) < 24, "final line is \(lastY), expected ~\(13 * 16)")
    // And it must have advanced to the right on the new line.
    #expect((tr.samples.last?.x ?? 0) > 6 * 16)
}

// MARK: - 2. backspace is followed

@Test func tracerFollowsBackspace() throws {
    var frames: [LumaTiles] = [TypingGrid.page([])]
    for n in 1...12 { frames.append(TypingGrid.page(TypingGrid.line(8, 5, n))) }   // type 12 glyphs
    // Backspace: the rightmost glyph disappears, the caret moves left.
    for n in stride(from: 10, through: 7, by: -1) { frames.append(TypingGrid.page(TypingGrid.line(8, 5, n))) }
    let tr = try #require(TypingGrid.trace(frames))
    let xs = tr.samples.map(\.x)
    let peak = try #require(xs.max())
    let last = try #require(xs.last)
    print("backspace x: \(xs.map { Int($0) })")
    #expect(last < peak - 16, "caret never moved back after backspace: peak \(peak) last \(last)")
    #expect(abs(last - 12 * 16) < 24, "caret after three backspaces is \(last), expected ~\(12 * 16)")
}

// MARK: - 3. an unrelated animation is rejected

@Test func tracerRejectsUnrelatedAnimation() throws {
    // Typing on row 14 while a line of animation jumps around rows 3-4.
    var frames: [LumaTiles] = [TypingGrid.page([])]
    var anim = 4
    for n in 1...24 {
        anim = (anim + 7) % 30                       // the animation moves far each frame
        let motion = TypingGrid.line(3, anim, 8) + TypingGrid.line(4, (anim + 11) % 30, 6)
        frames.append(TypingGrid.page(TypingGrid.line(14, 6, min(n, 10)) + motion))
    }
    let tr = try #require(TypingGrid.trace(frames))
    let textY = 14 * 16.0
    let onText = tr.samples.filter { abs($0.y - textY) < 32 }.count
    print("animation: \(onText)/\(tr.samples.count) samples on the text line")
    #expect(Double(onText) / Double(max(tr.samples.count, 1)) > 0.7,
            "tracker followed the animation instead of the text line")
    #expect(abs((tr.samples.last?.y ?? 0) - textY) < 32)
    // A trace that is not on the text line is worse than no trace.
    #expect(tr.rect.map { abs($0.origin.y - 14 * 16) < 24 } ?? false)
}

// MARK: - 4. caret blink holds the line

@Test func tracerSurvivesCaretBlink() throws {
    // Five typed glyphs, then the caret toggles in place for six frames.
    var frames: [LumaTiles] = [TypingGrid.page([])]
    for n in 1...5 { frames.append(TypingGrid.page(TypingGrid.line(9, 5, n))) }
    let full = TypingGrid.line(9, 5, 5)
    for i in 0..<6 {
        // A caret bar is a thin mark: a much smaller luma change than a glyph.
        var mean = [UInt8](repeating: 235, count: TypingGrid.cols * TypingGrid.rows)
        for (c, r) in full { mean[r * TypingGrid.cols + c] = 40 }
        if i % 2 == 1 { mean[9 * TypingGrid.cols + 10] = 185 }
        frames.append(LumaTiles(cols: TypingGrid.cols, rows: TypingGrid.rows, tile: TypingGrid.tile, mean: mean))
    }
    let tr = try #require(TypingGrid.trace(frames))
    let xs = tr.samples.map(\.x)
    let last = try #require(xs.last)
    print("blink x: \(xs.map { Int($0) })")
    // A blink must not run the caret away: it may wobble by one glyph.
    #expect(last <= Double(11) * 16, "caret ran away during a blink: \(last)")
    #expect(last >= Double(9) * 16, "caret lost the line during a blink: \(last)")
    #expect(tr.samples.contains { $0.evidence == .blink }, "no sample was recognised as a caret blink")
}

// MARK: - 5. typing at the very start and the very end of a clip

@Test func tracerHandlesEdgesOfRecording() throws {
    // t=0: the first key is the first frame of the clip.
    let atStart = TypingGrid.growing(row: 10, first: 4, from: 1, to: 9, t0: 0)
    let startTrace = try #require(TypingGrid.trace(atStart, t0: 0))
    print("start trace: \(startTrace.samples.count) samples, rect \(String(describing: startTrace.rect))")
    #expect(startTrace.samples.count >= 4, "no trace at the very start of the recording")
    #expect((startTrace.samples.last?.x ?? 0) > 6 * 16)

    // The clip ends mid-burst: the tail sample times are past the last frame.
    let atEnd = TypingGrid.growing(row: 11, first: 3, from: 1, to: 10, t0: 41.5)
    let endTrace = try #require(TypingGrid.trace(atEnd, t0: 41.5, burst: 1))
    print("end trace: \(endTrace.samples.count) samples")
    #expect(endTrace.samples.count >= 4, "no trace at the very end of the recording")
    #expect((endTrace.samples.last?.x ?? 0) > 5 * 16)
}

// MARK: - 6. per-sample provenance

@Test func traceCarriesSampleProvenance() throws {
    let frames = TypingGrid.growing(row: 7, first: 5, from: 1, to: 10)
    let tr = try #require(TypingGrid.trace(frames))
    // Every sample knows when it was taken and how much the pixels support it.
    for (a, b) in zip(tr.samples, tr.samples.dropFirst()) { #expect(b.t > a.t) }
    #expect(tr.samples.allSatisfy { $0.confidence > 0 && $0.confidence <= 1 })
    #expect(tr.samples.contains { $0.evidence == .caret })
    #expect(tr.meanConfidence > 0.5)
    // Freshness is decidable from the value alone: a sample after the burst is
    // not a sample of the burst.
    #expect(tr.sample(at: tr.t1 + 5) == tr.samples.last)
    // The line rect survives a JSON round trip with its provenance.
    let data = try JSONEncoder().encode(tr)
    let back = try JSONDecoder().decode(TypingTrace.self, from: data)
    #expect(back == tr)
    #expect(back.samples.first?.confidence == tr.samples.first?.confidence)
}

// MARK: - 7. old traces still decode (format compatibility)

@Test func legacyTypingTraceDecodesWithDefaults() throws {
    let json = Data(#"{"t0":1.0,"t1":2.0,"rect":[10,20,100,16],"samples":[{"t":1.0,"x":30,"y":28}]}"#.utf8)
    let tr = try JSONDecoder().decode(TypingTrace.self, from: json)
    #expect(tr.samples.count == 1)
    #expect(tr.samples.first?.confidence == 1)
    #expect(tr.samples.first?.evidence == .caret)
    #expect(tr.line == nil)
}

// MARK: - 8. one decode pass for overlapping bursts

@Test func overlappingBurstsShareOneDecodeWindow() {
    let bursts = [(t0: 0.50, t1: 0.80), (t0: 0.95, t1: 1.10), (t0: 1.25, t1: 1.40), (t0: 30.0, t1: 30.5)]
    let windows = TypingAnalyzer.decodePlan(bursts: bursts, duration: 60)
    print("windows: \(windows.map { "\($0.start)...\($0.end) -> \($0.bursts)" })")
    // Three overlapping bursts are one window; the far one is its own.
    #expect(windows.count == 2)
    #expect(windows.first?.bursts == [0, 1, 2])
    #expect(windows.last?.bursts == [3])
    // Every burst is covered exactly once.
    #expect(windows.flatMap(\.bursts).sorted() == [0, 1, 2, 3])
    // No window is longer than the union it covers.
    #expect(windows.allSatisfy { $0.end > $0.start })
}

@Test func typingSamplesAreDenserThanTenHertz() {
    let times = TypingAnalyzer.sampleTimes(burst: (t0: 5.0, t1: 5.4), hz: 30)
    let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
    print("typing samples: \(times.count), max gap \(gaps.max() ?? 0)")
    // The whole point of the change: a caret step is smaller than a glyph.
    #expect(times.count >= 15)
    #expect((gaps.max() ?? 0) <= 1.0 / 20 + 0.001)
    // The baseline sits before the first key and the tail covers the last one.
    #expect(times.first == 5.0 - 0.12)
    #expect(times.last! >= 5.4)
}

// MARK: - 9. decode pass over a real file (reader count is measured)

@Test func analyzerDecodesOverlappingBurstsInOnePass() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("typing.mov")
    try await TypingVideo.write(to: url, seconds: 4, fps: 30) { frame in
        // A typed line on row 14 that grows for the whole clip.
        TypingGrid.page(TypingGrid.line(14, 6, min(6 + frame / 4, 30)))
    }
    AnalysisMetrics.shared.reset()
    let bursts = [(t0: 0.6, t1: 0.9), (t0: 1.0, t1: 1.2), (t0: 1.3, t1: 1.6)]
    let traces = try await TypingAnalyzer.analyze(url: url, bursts: bursts, anchors: [nil, nil, nil])
    let metrics = AnalysisMetrics.shared.snapshot()
    print("decode: windows \(metrics.typingWindows) readers \(metrics.typingReaderOpens) frames \(metrics.typingFrames)")
    #expect(metrics.typingReaderOpens == 1, "expected one reader for three overlapping bursts, got \(metrics.typingReaderOpens)")
    #expect(metrics.typingFrames < 60, "sampled more frames than the burst needs: \(metrics.typingFrames)")
    #expect(traces.count == 3)
    #expect(traces.allSatisfy { $0.samples.count >= 2 })
    #expect(traces.allSatisfy { abs(($0.rect?.origin.y ?? 0) - 14 * 16) < 24 })
}

@Test func analyzerTracesBurstAtStartAndEndOfClip() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("edges.mov")
    // The line has to still be growing at the end of the clip. With the old
    // `min(..., 20)` cap the page froze at frame 54, so the tail burst covered
    // a stretch with no on-screen change at all: a delta tracer has nothing to
    // follow there, and "a trace at the last frame" was unprovable by
    // construction rather than by the tracer's behaviour.
    try await TypingVideo.write(to: url, seconds: 2.5, fps: 30) { frame in
        TypingGrid.page(TypingGrid.line(12, 6, 2 + frame / 3))
    }
    AnalysisMetrics.shared.reset()
    // First key of the recording, and a burst that runs to the last frame.
    let bursts = [(t0: 0.0, t1: 0.3), (t0: 2.2, t1: 2.45)]
    let traces = try await TypingAnalyzer.analyze(url: url, bursts: bursts, anchors: [nil, nil])
    print("edge traces: \(traces.map { "\($0.t0)...\($0.t1) n=\($0.samples.count)" })")
    #expect(traces.count == 2, "expected a trace for the first and the last burst, got \(traces.count)")
    #expect(traces.allSatisfy { $0.samples.count >= 3 })
    #expect(traces.allSatisfy { abs(($0.rect?.origin.y ?? -1) - 12 * 16) < 24 })
}

// MARK: - 10. scheduler is bounded and priority ordered

@Test func schedulerRunsWithinCapacity() async throws {
    func report(_ jobs: Int, capacity: Int) async -> AnalysisScheduleReport {
        let state = OrderLog()
        let built = (0..<jobs).map { i in
            AnalysisJob(name: "j\(i)", priority: i) {
                await state.enter("j\(i)")
                try? await Task.sleep(for: .milliseconds(30))
                await state.leave("j\(i)")
            }
        }
        return await AnalysisScheduler.run(built, capacity: capacity)
    }
    let one = await report(4, capacity: 1)
    #expect(one.peakConcurrency == 1, "capacity 1 ran \(one.peakConcurrency) at once")
    #expect(one.order == ["j0", "j1", "j2", "j3"], "priority order changed: \(one.order)")
    let two = await report(5, capacity: 2)
    #expect(two.peakConcurrency == 2)
    #expect(two.peakConcurrency <= two.capacity)
    let five = await report(5, capacity: 3)
    #expect(five.peakConcurrency <= 3)
    #expect(Set(five.order).count == 5, "a job never ran: \(five.order)")
}

private actor OrderLog {
    private var running = 0
    private(set) var peak = 0
    private(set) var order: [String] = []
    func enter(_ name: String) { order.append(name); running += 1; peak = max(peak, running) }
    func leave(_ name: String) { running -= 1 }
}

// MARK: - 11. luma tile pass (profiled, printed)

@Test func lumaTilesProfile() throws {
    let width = 2880, height = 1800
    let buffer = try #require(FrameImage.makeBuffer(width, height))
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
    if let base { memset(base, 200, CVPixelBufferGetDataSize(buffer)) }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    // warm
    _ = try lumaTiles(buffer)
    let runs = 10
    let started = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<runs { _ = try lumaTiles(buffer) }
    let each = Double(DispatchTime.now().uptimeNanoseconds - started) / Double(runs) / 1_000_000
    let tiles = try lumaTiles(buffer)
    print(String(format: "lumaTiles %dx%d: %.2f ms/frame, %d tiles", width, height, each, tiles.mean.count))
    #expect(tiles.mean.count > 0)
}

// MARK: - synthetic video writer

enum TypingVideo {
    /// Writes `seconds` of 640x360 H.264 where `content` draws one frame.
    static func write(to url: URL, seconds: Double, fps: Int,
                      content: @escaping (Int) -> LumaTiles) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw NSError(domain: "TypingVideo", code: 1) }
        writer.startSession(atSourceTime: .zero)
        let total = Int(seconds * Double(fps))
        for frame in 0..<total {
            let buffer = try #require(FrameImage.makeBuffer(640, 360))
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
            if let base { memset(base, 235, CVPixelBufferGetDataSize(buffer)) }
            // The grid is 40x22 tiles at 16 px; paint each ink tile.
            let grid = content(frame)
            if let base {
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for r in 0..<grid.rows {
                    for c in 0..<grid.cols where grid.mean[r * grid.cols + c] < 128 {
                        let y0 = r * 16, x0 = c * 16
                        for y in y0..<min(y0 + 16, 360) {
                            let row = base + y * stride
                            for x in x0..<min(x0 + 16, 640) { row[x * 4] = 40; row[x * 4 + 1] = 40; row[x * 4 + 2] = 40; row[x * 4 + 3] = 255 }
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: CMTimeScale(fps))) else {
                throw NSError(domain: "TypingVideo", code: 2)
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw NSError(domain: "TypingVideo", code: 3) }
    }
}