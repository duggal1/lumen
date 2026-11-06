import Foundation
import simd
import LumenCore
import LumenProject

public struct ClickPulse: Sendable, Equatable { public var t: Double; public var position: SIMD2<Float> }
public struct PulseFX: Sendable, Equatable { public var position: SIMD2<Float>; public var progress: Float }

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
            out.append(PulseFX(position: ps[i].position, progress: Float((t - ps[i].t) / duration))); i += 1
        }
        return Array(out.suffix(maxCount))
    }
}
