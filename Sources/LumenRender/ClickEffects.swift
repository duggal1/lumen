import Foundation
import simd
import LumenCore
import LumenProject

public struct ClickPulse: Sendable, Equatable { public var t: Double; public var position: SIMD2<Float> }
public struct PulseFX: Sendable, Equatable {
    public var position: SIMD2<Float>
    public var progress: Float
    /// 0...1 opacity of the ripple at `progress`. Zero at onset and at
    /// completion, so the wave cannot pop or end on a hard edge.
    public var amplitude: Float
}

public enum ClickPulses {
    public static func build(events: [InputEvent], taps: [TapIndicator], range: ClosedRange<Double>) -> [ClickPulse] {
        var out = events.filter { $0.kind == .down && range.contains($0.t) }.map { ClickPulse(t: $0.t, position: [$0.x, $0.y]) }
        out += taps.filter { range.contains($0.t) }.map { ClickPulse(t: $0.t, position: [Float($0.x), Float($0.y)]) }
        return out.sorted { $0.t < $1.t }
    }

    public static func active(_ ps: [ClickPulse], at t: Double, duration: Double, maxCount: Int = 8) -> [PulseFX] {
        guard duration > 0, !ps.isEmpty else { return [] }
        var lo = 0, hi = ps.count
        while lo < hi { let m = (lo + hi) / 2; if ps[m].t <= t - duration { lo = m + 1 } else { hi = m } }
        var out: [PulseFX] = [], i = lo
        while i < ps.count, ps[i].t <= t {
            let progress = (t - ps[i].t) / duration
            out.append(PulseFX(position: ps[i].position, progress: Float(min(max(progress, 0), 1)),
                               amplitude: ClickEnvelope.amplitude(progress)))
            i += 1
        }
        return Array(out.suffix(maxCount))
    }
}

/// Temporal envelope of one ripple, shared by preview and export.
///
/// Onset, expansion and fade are one motion: amplitude rises from exactly zero
/// with zero slope, holds a single hump, and returns to exactly zero with zero
/// slope at the end of the duration. Linear progress is the defect — it starts
/// at full strength (a pop) and leaves the last frame at full strength (a cut).
public enum ClickEnvelope {
    /// Fraction of the duration spent fading in.
    public static let onset = 0.18

    public static func amplitude(_ progress: Double) -> Float {
        guard progress > 0, progress < 1 else { return 0 }
        let p = min(max(progress, 0), 1)
        let t = min(p / onset, 1)
        let rise = t * t * (3 - 2 * t)                      // smoothstep: zero slope at both ends
        return Float(rise * pow(1 - p, 1.35))
    }
}