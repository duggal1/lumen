import Foundation
import AVFoundation
import CoreVideo
import os
import LumenProject

/// Reads only the frames around each typing burst and turns them into the
/// per-tile luma grids the pure `TypingTracer` consumes. One AVAssetReader
/// per burst keeps a 60 s 2880 px capture from being decoded end to end.
public enum TypingAnalyzer {
    public static func analyze(url: URL, bursts: [(t0: Double, t1: Double)],
                               anchors: [SIMD2<Double>?]) async throws -> [TypingTrace] {
        guard !bursts.isEmpty, bursts.count == anchors.count else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let job = TypingJob(asset: asset, track: track, bursts: bursts, anchors: anchors)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try job.run() }.value
        } onCancel: { job.cancel() }
    }
}

private final class TypingJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let bursts: [(t0: Double, t1: Double)]
    private let anchors: [SIMD2<Double>?]
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, bursts: [(t0: Double, t1: Double)], anchors: [SIMD2<Double>?]) {
        self.asset = asset; self.track = track; self.bursts = bursts; self.anchors = anchors
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
    }

    func run() throws -> [TypingTrace] {
        let duration = asset.duration.seconds
        var traces: [TypingTrace] = []
        for (i, burst) in bursts.enumerated() {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            let a = max(0, burst.t0 - 0.20), b = min(duration, burst.t1 + 0.50)
            guard b > a else { continue }
            if let trace = try one(burst: burst, anchor: anchors[i], from: a, to: b) { traces.append(trace) }
        }
        return traces
    }

    private func one(burst: (t0: Double, t1: Double), anchor: SIMD2<Double>?, from a: Double, to b: Double) throws -> TypingTrace? {
        let reader = try AVAssetReader(asset: asset)
        let handle = ReaderHandle(reader)
        readerLock.withLock { $0 = handle }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.readerConfiguration }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 600),
                                       end: CMTime(seconds: b, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? AnalysisError.readerStart }

        // One baseline shortly before the first key, then ~10 fps through the
        // burst. Sampling on the decoded frame clock keeps each grid tied to
        // the exact frame time the tracer reports.
        var wanted: [Double] = [max(a, burst.t0 - 0.12)]
        var t = burst.t0 + 0.10
        while t <= burst.t1 + 0.40 { wanted.append(t); t += 0.10 }
        var wi = 0
        var ts: [Double] = []
        var grids: [LumaTiles] = []
        var height = 0.0
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard wi < wanted.count, time + 0.0001 >= wanted[wi],
                  let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let grid = try lumaTiles(buffer)
            ts.append(time)
            grids.append(grid)
            height = max(height, Double(CVPixelBufferGetHeight(buffer)))
            wi += 1
            while wi < wanted.count, wanted[wi] <= time + 0.0001 { wi += 1 }   // a slow frame satisfies only once
            if wi >= wanted.count { break }
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        guard grids.count >= 3 else { return nil }
        return TypingTracer.trace(burst: burst, ts: ts, grids: grids, anchor: anchor, srcH: height)
    }

    /// 16 source-px tiles, stride-2 sampling, one pass over the buffer.
    private func lumaTiles(_ buffer: CVPixelBuffer) throws -> LumaTiles {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AnalysisError.pixelBuffer }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw AnalysisError.pixelBuffer }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let tile = 16
        let cols = max(1, (width + tile - 1) / tile), rows = max(1, (height + tile - 1) / tile)
        var sum = [UInt32](repeating: 0, count: cols * rows)
        var count = [UInt32](repeating: 0, count: cols * rows)
        for y in stride(from: 0, to: height, by: 2) {
            let row = base + y * rowBytes
            let ry = y / tile
            for x in stride(from: 0, to: width, by: 2) {
                let i = x * 4
                let luma = (29 * Int(row[i]) + 150 * Int(row[i + 1]) + 77 * Int(row[i + 2])) >> 8
                let index = ry * cols + x / tile
                sum[index] += UInt32(luma)
                count[index] += 1
            }
        }
        var mean = [UInt8](repeating: 0, count: cols * rows)
        for i in mean.indices where count[i] > 0 {
            mean[i] = UInt8(min(255, sum[i] / count[i]))
        }
        return LumaTiles(cols: cols, rows: rows, tile: tile, mean: mean)
    }
}
