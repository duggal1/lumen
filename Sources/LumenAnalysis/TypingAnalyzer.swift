import Foundation
import AVFoundation
import CoreVideo
import os
import LumenProject

/// One merged decode window and the bursts it covers.
///
/// Burst windows are `[t0 - lead, t1 + tail]`. Bursts closer together than
/// `mergeGap` share a window, so a recording with many short bursts is decoded
/// once per contiguous run instead of once per burst.
public struct TypingDecodeWindow: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var bursts: [Int]
    public init(start: Double, end: Double, bursts: [Int]) {
        self.start = start; self.end = end; self.bursts = bursts
    }
}

/// Reads only the frames around each typing burst and turns them into the
/// per-tile luma grids the pure `TypingTracer` consumes.
///
/// The whole analysis is one decode pass over the union of the burst windows:
/// one `AVAssetReader` per merged window, each source frame decoded at most
/// once, and every burst traced from the frames its own window produced. A
/// burst is traced as soon as its last sample time is satisfied, so memory is
/// bounded by one burst rather than by the length of the merged run.
public enum TypingAnalyzer {
    /// Merged decode windows for a set of bursts.
    public static func decodePlan(bursts: [(t0: Double, t1: Double)], duration: Double,
                                  lead: Double = 0.20, tail: Double = 0.50,
                                  mergeGap: Double = 0.35) -> [TypingDecodeWindow] {
        let order = bursts.enumerated().sorted { $0.element.t0 < $1.element.t0 }
        var windows: [TypingDecodeWindow] = []
        let end = duration > 0 ? duration : Double.greatestFiniteMagnitude
        for (index, burst) in order {
            let a = max(0, burst.t0 - lead)
            let b = min(end, burst.t1 + tail)
            guard b > a else { continue }
            if var last = windows.last, a <= last.end + mergeGap {
                last.end = max(last.end, b)
                last.bursts.append(index)
                windows[windows.count - 1] = last
            } else {
                windows.append(TypingDecodeWindow(start: a, end: b, bursts: [index]))
            }
        }
        return windows
    }

    /// Sample times the tracer needs for one burst, ascending. The first entry
    /// is the pre-typing baseline; the rest run at `hz` through the burst plus a
    /// short tail so the final caret position is measured, not extrapolated.
    public static func sampleTimes(burst: (t0: Double, t1: Double), hz: Double,
                                   lead: Double = 0.12, tail: Double = 0.40) -> [Double] {
        let step = 1.0 / max(hz, 1)
        var out = [max(burst.t0 - lead, 0)]
        var t = out[0] + step
        while t < burst.t1 + tail { out.append(t); t += step }
        out.append(burst.t1 + tail)
        return out
    }

    public static func analyze(url: URL, bursts: [(t0: Double, t1: Double)],
                               anchors: [SIMD2<Double>?],
                               settings: TypingTraceSettings = .default) async throws -> [TypingTrace] {
        guard !bursts.isEmpty, bursts.count == anchors.count else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let job = TypingJob(asset: asset, track: track, bursts: bursts, anchors: anchors, settings: settings)
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
    private let settings: TypingTraceSettings
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, bursts: [(t0: Double, t1: Double)],
         anchors: [SIMD2<Double>?], settings: TypingTraceSettings) {
        self.asset = asset; self.track = track; self.bursts = bursts
        self.anchors = anchors; self.settings = settings
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
    }

    func run() throws -> [TypingTrace] {
        let windows = TypingAnalyzer.decodePlan(bursts: bursts, duration: asset.duration.seconds)
        guard !windows.isEmpty else { return [] }
        AnalysisMetrics.shared.add(windows: windows.count)
        var traces: [TypingTrace?] = Array(repeating: nil, count: bursts.count)
        for window in windows {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            try decode(window, into: &traces)
        }
        return traces.compactMap { $0 }
    }

    private func decode(_ window: TypingDecodeWindow, into traces: inout [TypingTrace?]) throws {
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
        reader.timeRange = CMTimeRange(start: CMTime(seconds: window.start, preferredTimescale: 600),
                                       end: CMTime(seconds: window.end, preferredTimescale: 600))
        guard reader.startReading() else { throw reader.error ?? AnalysisError.readerStart }
        AnalysisMetrics.shared.add(readerOpens: 1)

        var wanted: [(t: Double, burst: Int)] = []
        for index in window.bursts {
            for t in TypingAnalyzer.sampleTimes(burst: bursts[index], hz: settings.sampleHz) {
                wanted.append((t, index))
            }
        }
        wanted.sort { $0.t < $1.t }
        var remaining = Dictionary(uniqueKeysWithValues: window.bursts.map { ($0, 0) })
        for entry in wanted { remaining[entry.burst, default: 0] += 1 }
        var active: [Int: (ts: [Double], grids: [LumaTiles])] = [:]
        var height = 0.0
        var wi = 0

        func finish(_ index: Int) {
            guard let slot = active.removeValue(forKey: index), slot.ts.count == slot.grids.count, slot.ts.count >= 2 else { return }
            traces[index] = TypingTracer.trace(burst: bursts[index], ts: slot.ts, grids: slot.grids,
                                               anchor: anchors[index], srcH: height, settings: settings)
        }

        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            guard wi < wanted.count, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time + 0.0001 >= wanted[wi].t else { continue }
            let grid = try lumaTiles(buffer)
            AnalysisMetrics.shared.add(tiles: grid.mean.count)
            height = max(height, Double(CVPixelBufferGetHeight(buffer)))
            let index = wanted[wi].burst
            var slot = active[index] ?? (ts: [], grids: [])
            slot.ts.append(time)
            slot.grids.append(grid)
            active[index] = slot
            wi += 1
            // A slow frame satisfies only the first pending time; the ones it
            // passed are covered by it, not by a second copy of it.
            while wi < wanted.count, wanted[wi].t <= time + 0.0001 { wi += 1 }
            remaining[index, default: 0] -= 1
            if remaining[index] == 0 { finish(index) }
            if wi >= wanted.count { break }
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        for index in window.bursts where traces[index] == nil { finish(index) }
        reader.cancelReading()
    }
}