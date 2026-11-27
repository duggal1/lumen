import Foundation
import os

/// Collects actual Metal presentation times for a single uninterrupted
/// playback generation. Opt-in only; no frame image or screen text is stored.
public final class PlaybackCadence: @unchecked Sendable {
    public struct Report: Codable, Sendable {
        public let samples: Int
        public let elapsedSeconds: Double
        public let sourceAdvanceSeconds: Double
        public let presentedFPS: Double
        public let expectedFPS: Double
        public let p95Milliseconds: Double
        public let p99Milliseconds: Double
        public let worstMilliseconds: Double
        public let lateFraction: Double
    }
    private struct State {
        var generation: UInt64?
        var first = 0.0
        var last = 0.0
        var sourceFirst = 0.0
        var sourceLast = 0.0
        var expectedSum = 0.0
        var intervals: [Double] = []
        var late = 0
        var emitted = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    public init() {}

    /// Returns a report once, only after >=10 seconds of continuous playback.
    /// Callback ordering and the media clock must agree. A seek resets evidence.
    public func record(generation: UInt64, sourceTime: Double, actual: Double, expected: Double) -> Report? {
        guard actual.isFinite, actual > 0, expected.isFinite, expected > 0, expected <= 0.1,
              sourceTime.isFinite, sourceTime >= 0 else { return nil }
        return state.withLock { s in
            guard !s.emitted else { return nil }
            if let prior = s.generation, generation < prior { return nil }
            if s.generation != generation {
                s = State(generation: generation, first: actual, last: actual,
                          sourceFirst: sourceTime, sourceLast: sourceTime)
                return nil
            }
            guard actual > s.last, sourceTime > s.sourceLast else { return nil }
            let delta = actual - s.last
            s.intervals.append(delta)
            s.expectedSum += expected
            if delta > expected * 1.5 { s.late += 1 }
            s.last = actual
            s.sourceLast = sourceTime
            let elapsed = actual - s.first
            guard elapsed >= 10 || s.intervals.count >= 2400 else { return nil }
            // Short windows must not masquerade as ten-second proof.
            guard elapsed >= 10, s.intervals.count >= 30 else {
                s = State(generation: generation, first: actual, last: actual,
                          sourceFirst: sourceTime, sourceLast: sourceTime)
                return nil
            }
            let sorted = s.intervals.sorted()
            func percentile(_ fraction: Double) -> Double {
                sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))] * 1000
            }
            let n = Double(sorted.count)
            s.emitted = true
            return Report(samples: sorted.count, elapsedSeconds: elapsed, sourceAdvanceSeconds: sourceTime - s.sourceFirst,
                          presentedFPS: n / elapsed, expectedFPS: n / s.expectedSum,
                          p95Milliseconds: percentile(0.95), p99Milliseconds: percentile(0.99),
                          worstMilliseconds: (sorted.last ?? 0) * 1000, lateFraction: Double(s.late) / n)
        }
    }
}
