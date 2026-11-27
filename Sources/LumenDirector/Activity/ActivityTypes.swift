import Foundation
import LumenCore

/// One proposed auto-zoom shot derived from activity. `waypoints` ascend; the
/// first is the opening subject and later ones are pans inside the same shot.
/// Pure value type; source seconds and source pixels; safe to share across tasks.
public struct VisualShot: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable { case region, loader }

    /// One framing target in source pixels. `scale` is the intended magnification.
    public struct Waypoint: Sendable, Equatable {
        public var t: Double
        public var rect: PxRect
        public var scale: Double

        public init(t: Double, rect: PxRect, scale: Double) {
            self.t = t; self.rect = rect; self.scale = scale
        }
    }

    public var start: Double
    public var end: Double
    public var waypoints: [Waypoint]
    public var strength: Double
    public var kind: Kind
    /// Source-evidence-local identity; stable for identical replay inputs.
    public var subjectID: Int? = nil
    /// Corroborated action-associated geometric progression, not an AI label.
    public var sustained: Bool = false
    /// Corroborated initiating action for either a sustained response or a
    /// distinct revealed destination; nil for ordinary passive activity.
    public var actionTime: Double? = nil

    public init(start: Double, end: Double, waypoints: [Waypoint], strength: Double, kind: Kind) {
        self.start = start; self.end = end; self.waypoints = waypoints
        self.strength = strength; self.kind = kind
    }
}

/// Output of the pure shot builder. `busy` marks intervals of visible change so
/// the speed-ramp planner never places an idle ramp across live content.
/// Pure value type; source seconds; safe to share across tasks.
public struct ActivityResult: Sendable {
    public var shots: [VisualShot]
    public var busy: [ClosedRange<Double>]

    public init(shots: [VisualShot] = [], busy: [ClosedRange<Double>] = []) {
        self.shots = shots; self.busy = busy
    }

    /// Overlapping busy spans merged into a sorted, non-overlapping list.
    public var mergedBusy: [ClosedRange<Double>] {
        guard !busy.isEmpty else { return [] }
        var out: [ClosedRange<Double>] = []
        for span in busy.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, span.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else { out.append(span) }
        }
        return out
    }
}

/// Input-event times extracted from the shared event log, in source seconds.
/// Pure value type; produced on any thread, consumed by the Director builder.
public struct ActivityInputs: Sendable {
    public var keys: [Double] = []
    public var scrolls: [Double] = []
    public var clicks: [Double] = []
    public var moveT: [Double] = []
    public var moveX: [Float] = []
    public var moveY: [Float] = []
    /// Only explicit primary clicks and non-repeated Return/Enter can seed a
    /// prospective result. Neither mouse motion nor a modifier can seed it.
    var actions: [Double] = []
    var primaryClicks: [InputEvent] = []

    public init() {}

    /// Builds time-only inputs from `InputEvent`s. Hover position is retained so
    /// hover-only changes can be suppressed; it never becomes a shot by itself.
    public static func make(events: [InputEvent]) -> ActivityInputs {
        var a = ActivityInputs()
        for e in events.filter({ $0.t.isFinite }).sorted(by: { $0.t < $1.t }) {
            switch e.kind {
            case .keyDown:
                a.keys.append(e.t)
                if (e.keyCode == 36 || e.keyCode == 76), !e.isKeyRepeat, e.flags & 0x14 == 0 {
                    a.actions.append(e.t)
                }
            case .scroll, .drag: a.scrolls.append(e.t)
            case .down:
                a.clicks.append(e.t)
                if e.button == 0, e.flags & 0x14 == 0, e.x.isFinite, e.y.isFinite {
                    a.actions.append(e.t); a.primaryClicks.append(e)
                }
            case .move:
                guard e.x.isFinite, e.y.isFinite else { continue }
                a.moveT.append(e.t); a.moveX.append(e.x); a.moveY.append(e.y)
            default: break
            }
        }
        return a
    }

    func lowerBound(_ a: [Double], _ v: Double) -> Int {
        var l = 0, r = a.count
        while l < r {
            let m = (l + r) / 2
            if a[m] < v { l = m + 1 } else { r = m }
        }
        return l
    }

    func has(_ a: [Double], _ lo: Double, _ hi: Double) -> Bool {
        let i = lowerBound(a, lo)
        return i < a.count && a[i] <= hi
    }

    /// Last observation at or before t; never borrow a future pointer position.
    private func lastIndex(_ times: [Double], at t: Double) -> Int? {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }

    private func lastTime(_ times: [Double], at t: Double) -> Double {
        lastIndex(times, at: t).map { times[$0] } ?? -.infinity
    }

    func cursor(at t: Double) -> (x: Double, y: Double)? {
        guard let i = lastIndex(moveT, at: t),
              moveX.indices.contains(i), moveY.indices.contains(i) else { return nil }
        return (Double(moveX[i]), Double(moveY[i]))
    }

    func recentAction(at t: Double) -> Double? {
        guard let i = lastIndex(actions, at: t), t - actions[i] <= 1.8 else { return nil }
        return actions[i]
    }

    /// The first distinct action after the owner, not a second press from
    /// the same event instant. Used to freeze evidence at a handoff.
    func nextAction(after t: Double) -> Double? {
        let i = lowerBound(actions, t + 0.000001)
        return actions.indices.contains(i) ? actions[i] : nil
    }

    func primaryClick(at t: Double) -> InputEvent? {
        // Primary clicks are sorted with the event log. Avoid a full scan.
        var lo = 0, hi = primaryClicks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if primaryClicks[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        guard primaryClicks.indices.contains(lo), primaryClicks[lo].t == t else { return nil }
        return primaryClicks[lo]
    }

    func localHover(at t: Double, box: CellBox, cw: Double, ch: Double, radius: Double) -> Bool {
        guard let i = lastIndex(moveT, at: t), let cursor = cursor(at: t),
              lastTime(clicks, at: t) < moveT[i] else { return false }
        let x = cursor.x / cw, y = cursor.y / ch
        let dx = max(Double(box.x0) - x, x - Double(box.x1 + 1), 0)
        let dy = max(Double(box.y0) - y, y - Double(box.y1 + 1), 0)
        return hypot(dx, dy) <= max(radius, 0)
    }

    /// A stationary pointer can still own a delayed tooltip. For remote
    /// changes, use a bounded uncertainty window, not an unbounded global
    /// veto: autonomous results elsewhere must remain eligible after it.
    func hoverAssociated(at t: Double, box: CellBox, cw: Double, ch: Double,
                         radius: Double) -> Bool {
        guard let i = lastIndex(moveT, at: t), let cursor = cursor(at: t) else { return false }
        let move = moveT[i]
        let click = lastTime(clicks, at: t)
        if click >= move { return false }
        let latestExplicit = max(click, lastTime(keys, at: t), lastTime(scrolls, at: t))
        if move > latestExplicit && t - move <= 2.5 { return true }
        // Persistent local hover context; keyboard activity does not move the
        // pointer away. Classify the whole component, never a clipped remnant.
        let x = cursor.x / cw, y = cursor.y / ch
        let dx = max(Double(box.x0) - x, x - Double(box.x1 + 1), 0)
        let dy = max(Double(box.y0) - y, y - Double(box.y1 + 1), 0)
        return hypot(dx, dy) <= max(radius, 0)
    }
}

/// Inclusive cell rectangle. Internal working value; not persisted.
struct CellBox: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int

    var area: Int { (x1 - x0 + 1) * (y1 - y0 + 1) }
    var cx: Double { Double(x0 + x1 + 1) / 2 }
    var cy: Double { Double(y0 + y1 + 1) / 2 }

    func union(_ o: CellBox) -> CellBox {
        CellBox(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }

    func inflated(_ n: Int) -> CellBox {
        CellBox(x0: x0 - n, y0: y0 - n, x1: x1 + n, y1: y1 + n)
    }

    func overlapArea(_ o: CellBox) -> Int {
        let ix = min(x1, o.x1) - max(x0, o.x0) + 1
        let iy = min(y1, o.y1) - max(y0, o.y0) + 1
        return ix > 0 && iy > 0 ? ix * iy : 0
    }
}
