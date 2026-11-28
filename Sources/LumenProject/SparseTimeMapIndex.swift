import Foundation
import LumenCore

/// Experimental, not used by production TimeMap. Compresses constant-rate
/// sections of its existing 240 Hz integration lattice; only variable-speed
/// fade sections retain numerical knots. Evaluate parity before switching.
struct SparseTimeMapIndex: Sendable {
    private static let ds = 1.0 / 240
    private struct Span: Sendable {
        let first: Int, end: Int
        let outputStart: Double, outputEnd: Double
        let step: Double
        let knots: [Double]?

        func value(at tick: Int) -> Double {
            if let knots { return outputStart + knots[tick - first] }
            return outputStart + Double(tick - first) * step
        }
    }

    private let trimStart: Double
    private let ticks: Int
    private let spans: [Span]
    var outputDuration: Double { spans.last?.outputEnd ?? 0 }
    var segmentCount: Int { spans.count }
    var retainedKnots: Int { spans.reduce(0) { $0 + ($1.knots?.count ?? 0) } }
    var denseTickCount: Int { ticks + 1 }

    init(_ map: TimeMap) {
        let start = map.trimStart, end = map.trimEnd
        trimStart = start
        let count = ((end - start) / Self.ds).rounded(.up)
        guard start.isFinite, end.isFinite, count.isFinite, count >= 0,
              count <= 24 * 3600 / Self.ds else {
            ticks = 0; spans = []; return
        }
        let n = Int(count)
        ticks = n
        guard n > 0 else { spans = []; return }

        let ramps = map.ramps.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start &&
                $0.speed.isFinite && $0.speed > 0
        }.sorted { $0.start < $1.start }
        let cuts = map.cuts.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
        }.sorted { $0.start < $1.start }

        func midpoint(_ i: Int) -> Double { start + (Double(i) + 0.5) * Self.ds }
        // Use the actual lattice midpoint predicate rather than rounding a
        // converted coordinate, so exact cut boundaries preserve semantics.
        func boundary(_ time: Double, strict: Bool = false) -> Int {
            Self.lowerBound(n) { strict ? midpoint($0) > time : midpoint($0) >= time }
        }
        func fade(_ ramp: SpeedRamp) -> Double {
            max(min(0.5, (ramp.end - ramp.start) / 4), 0.01)
        }
        var boundaries: Set<Int> = [0, n]
        for cut in cuts {
            boundaries.insert(boundary(cut.start))
            boundaries.insert(boundary(cut.end))
        }
        for ramp in ramps {
            let w = fade(ramp)
            boundaries.insert(boundary(ramp.start))
            boundaries.insert(boundary(ramp.end, strict: true))
            boundaries.insert(boundary(ramp.start + w))
            boundaries.insert(boundary(ramp.end - w, strict: true))
        }
        let ordered = boundaries.sorted()
        var built: [Span] = []
        var total = 0.0, ri = 0, ci = 0

        for (a, b) in zip(ordered, ordered.dropFirst()) {
            guard b > a else { continue }
            let first = midpoint(a), last = midpoint(b - 1)
            while ci < cuts.count && cuts[ci].end <= first { ci += 1 }
            while ri < ramps.count && ramps[ri].end < first { ri += 1 }
            let cut = ci < cuts.count && cuts[ci].start <= first
            let ramp = ri < ramps.count && ramps[ri].start <= first ? ramps[ri] : nil
            var step = Self.ds
            var knots: [Double]?
            if cut { step = 0 }
            else if let ramp, ramp.speed != 1 {
                let w = fade(ramp)
                if first >= ramp.start + w && last <= ramp.end - w {
                    step = Self.ds / ramp.speed
                } else {
                    var values = [0.0]
                    values.reserveCapacity(b - a + 1)
                    var sum = 0.0
                    for i in a..<b {
                        let t = midpoint(i)
                        let rate = 1 + (ramp.speed - 1) *
                            smoothstep((t - ramp.start) / w) * smoothstep((ramp.end - t) / w)
                        sum += Self.ds / rate
                        values.append(sum)
                    }
                    knots = values
                }
            }
            let next = total + (knots?.last ?? (Double(b - a) * step))
            built.append(Span(first: a, end: b, outputStart: total, outputEnd: next,
                              step: step, knots: knots))
            total = next
        }
        spans = built
    }

    func output(atSource source: Double) -> Double {
        guard source.isFinite, trimStart.isFinite else { return 0 }
        let f = (source - trimStart) / Self.ds
        guard f.isFinite, f > 0 else { return 0 }
        guard f < Double(ticks) else { return outputDuration }
        let i = Int(f)
        let index = Self.lowerBound(spans.count) { spans[$0].end > i }
        guard index < spans.count else { return outputDuration }
        let span = spans[index]
        let lo = span.value(at: i), hi = span.value(at: i + 1)
        return lo + (hi - lo) * (f - Double(i))
    }

    func source(atOutput time: Double) -> Double {
        guard time.isFinite, trimStart.isFinite, ticks > 0 else {
            return trimStart.isFinite ? trimStart : 0
        }
        if time < 0 { return trimStart }
        if time >= outputDuration { return trimStart + Double(ticks) * Self.ds }
        let eps = Self.ds * 1e-6
        // Upper bound on starting output time skips zero-length cut plateaus
        // and selects the retained source to their right.
        let index = max(0, Self.lowerBound(spans.count) { spans[$0].outputStart > time + eps } - 1)
        let span = spans[index]
        var offset = 0.0
        if let knots = span.knots {
            let local = time - span.outputStart
            let i = min(knots.count - 2, max(0, Self.lowerBound(knots.count) { knots[$0] > local + eps } - 1))
            let delta = knots[i + 1] - knots[i]
            offset = Double(i) + (delta > 0 ? min(max((local - knots[i]) / delta, 0), 1) : 0)
        } else if span.step > 0 {
            let raw = (time - span.outputStart) / span.step
            offset = min(max(raw, 0), Double(span.end - span.first))
        } else {
            offset = Double(span.end - span.first)
        }
        return trimStart + (Double(span.first) + offset) * Self.ds
    }

    private static func lowerBound(_ count: Int, where predicate: (Int) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if predicate(mid) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
