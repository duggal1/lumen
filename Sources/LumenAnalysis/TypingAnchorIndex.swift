import Foundation
import LumenCore
import LumenProject

/// Sorted event indexes are built once, then queried in logarithmic time.
/// The original scan visited the complete event log twice per typing burst.
enum TypingAnchorIndex {
    static func resolve(events: [InputEvent], ax: [AXFrame],
                        bursts: [(t0: Double, t1: Double)]) -> [SIMD2<Double>?] {
        let keys = events.filter {
            $0.t.isFinite && $0.kind == .keyDown && $0.axFrameIndex > 0 && Int($0.axFrameIndex) <= ax.count
        }.sorted { $0.t < $1.t }
        let clicks = events.filter { $0.t.isFinite && $0.kind == .down }.sorted { $0.t < $1.t }
        func bound(_ values: [InputEvent], _ time: Double, inclusive: Bool) -> Int {
            var lo = 0, hi = values.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if values[mid].t < time || (inclusive && values[mid].t == time) { lo = mid + 1 }
                else { hi = mid }
            }
            return lo
        }
        return bursts.map { burst in
            guard burst.t0.isFinite, burst.t1.isFinite, burst.t1 >= burst.t0 else { return nil }
            let index = bound(keys, burst.t0, inclusive: false)
            if keys.indices.contains(index), keys[index].t <= burst.t1 {
                let frame = ax[Int(keys[index].axFrameIndex) - 1]
                if frame.w > 0 {
                    if let anchor = frame.anchor, !anchor.resolved { return nil }
                    return SIMD2(frame.caret.map { $0.x + $0.w / 2 } ?? frame.x + frame.w / 2,
                                 frame.caret.map { $0.y + $0.h / 2 } ?? frame.y + frame.h / 2)
                }
            }
            let indexBefore = bound(clicks, burst.t0, inclusive: true) - 1
            guard clicks.indices.contains(indexBefore) else { return nil }
            let event = clicks[indexBefore]
            guard burst.t0 - event.t < 20, event.x.isFinite, event.y.isFinite else { return nil }
            return SIMD2(Double(event.x), Double(event.y))
        }
    }
}
