import Foundation
import CoreGraphics
import LumenCore
import LumenProject

enum TypingFocus {
    /// No extra tail is baked into a typing shot's end: the critically damped
    /// camera release owns the zoom-out, so `t1` stays exactly on the last
    /// keystroke. This keeps the shot's enter/exit tight to keystroke timing
    /// and avoids a zoom-bounce between bursts.
    static let exitDebounce = 0.0
    /// A gap longer than this between keystrokes ends the current burst.
    static let idleTimeout = 0.9
    /// Once the field is resolved we tolerate a longer pause in the same field.
    static let sameFieldIdleTimeout = 1.5

    /// One caret sample, time-stamped at the keystroke that produced it.
    /// Carried on the shot so the zoom target can be checked against the caret
    /// path without ever letting the camera chase a jumping insertion point.
    struct Caret: Sendable, Equatable {
        var t: Double
        var rect: CGRect
    }

    struct Shot: Sendable, Equatable {
        var t0: Double
        var t1: Double
        var field: CGRect
        /// Caret rectangles in source pixels, one per keystroke, ascending in
        /// time. Empty when AX never reported a caret for this field.
        var carets: [Caret] = []

        func covers(_ t: Double) -> Bool { t >= t0 - 1e-9 && t <= t1 + 1e-9 }
    }

    private struct Run {
        var start: Double
        var end: Double
        var field: Field?
        var carets: [Caret] = []
    }

    struct Field: Sendable {
        var rect: CGRect
        var anchor: FocusAnchor?

        func matches(_ next: Field, backing: Double) -> Bool {
            if let a = anchor, let b = next.anchor {
                if a.windowID != b.windowID || a.appName != b.appName { return false }
                if a.epoch != 0, a.epoch == b.epoch { return true }
                if a.epoch != 0, b.epoch != 0 { return false }
            }
            let overlap = rect.intersection(next.rect)
            return !overlap.isNull &&
                overlap.width * overlap.height >= min(rect.width * rect.height,
                                                       next.rect.width * next.rect.height) * 0.75 &&
                abs(rect.midX - next.rect.midX) <= max(8 * backing, min(rect.width, next.rect.width) * 0.15) &&
                abs(rect.minY - next.rect.minY) <= max(8 * backing, min(rect.height, next.rect.height) * 0.2)
        }
    }

    static func field(_ frame: AXFrame, at time: Double, bounds: CGRect, backing: Double) -> Field? {
        guard frame.label?.hasPrefix("window|") != true,
              frame.anchor?.resolved != false,
              frame.x.isFinite, frame.y.isFinite, frame.w.isFinite, frame.h.isFinite,
              frame.w >= 4 * backing, frame.h >= 6 * backing,
              frame.w <= 0.95 * bounds.width, frame.h <= 0.95 * bounds.height else { return nil }
        if let sampledAt = frame.anchor?.sampledAt, sampledAt > 0, time - sampledAt > 2 { return nil }
        let rect = CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h).intersection(bounds)
        guard !rect.isEmpty else { return nil }
        if let caret = frame.caret, caret.x.isFinite, caret.y.isFinite,
           caret.h >= 6 * backing, caret.h <= 120 * backing, caret.w >= 0, caret.w <= 80 * backing {
            let point = CGPoint(x: caret.x + caret.w / 2, y: caret.y + caret.h / 2)
            let slack = 24 * backing
            guard rect.insetBy(dx: -slack, dy: -slack).contains(point) else { return nil }
        }
        return Field(rect: rect, anchor: frame.anchor)
    }

    /// Two AX rectangles that contain one another describe the same text
    /// subject at two granularities: a wide container and the focused field
    /// inside it. They belong to one typing run, not two shots — the caret
    /// selects the smaller (more specific) field as the subject.
    private static func nested(_ a: CGRect, _ b: CGRect) -> Bool {
        let pad: CGFloat = 2
        return a.insetBy(dx: -pad, dy: -pad).contains(b) ||
               b.insetBy(dx: -pad, dy: -pad).contains(a)
    }

    /// Caret rectangle for one keystroke's AX sample, validated against the
    /// resolved field so a stale or foreign caret cannot pull the zoom target.
    private static func caret(for frame: AXFrame, in field: CGRect,
                              at time: Double, backing: Double) -> Caret? {
        guard let c = frame.caret, c.x.isFinite, c.y.isFinite, c.w.isFinite, c.h.isFinite,
              c.w >= 0, c.w <= 80 * backing,
              c.h >= 6 * backing, c.h <= 120 * backing else { return nil }
        let rect = CGRect(x: c.x, y: c.y, width: max(c.w, 1), height: c.h)
        let slack = 24 * backing
        guard field.insetBy(dx: -slack, dy: -slack).contains(
            CGPoint(x: rect.midX, y: rect.midY)) else { return nil }
        return Caret(t: time, rect: rect)
    }

    private static func pixelField(for run: Run, traces: [TypingTrace], bounds: CGRect) -> CGRect? {
        let matches = traces.filter { $0.t0 <= run.end + 0.15 && $0.t1 >= run.start - 0.15 }
        let ordered = matches.sorted {
            min($0.t1, run.end) - max($0.t0, run.start) > min($1.t1, run.end) - max($1.t0, run.start)
        }
        for trace in ordered {
            for candidate in [trace.line, trace.rect] {
                guard let rect = candidate, rect.minX.isFinite, rect.minY.isFinite,
                      rect.width.isFinite, rect.height.isFinite else { continue }
                let clipped = bounds.intersection(rect)
                if !clipped.isEmpty { return clipped }
            }
        }
        return nil
    }

    /// Locks the first supported rectangle in each typing run. A second field,
    /// a click outside the current field, or a source cut ends the run.
    static func shots(events: [InputEvent], ax: [AXFrame], traces: [TypingTrace],
                      W: Double, H: Double, b: Double,
                      trimStart: Double, trimEnd: Double, cuts: [CutRange] = []) -> [Shot] {
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        let ordered = events.filter {
            ($0.isTypingKey || ($0.kind == .down && $0.button == 0)) &&
            $0.t.isFinite && $0.t >= trimStart && $0.t < trimEnd
        }.sorted { $0.t < $1.t }
        let orderedCuts = cuts.sorted { $0.start < $1.start }
        var cut = 0
        var run: Run?
        var result: [Shot] = []

        func finish() {
            guard let completed = run else { return }
            run = nil
            guard let rect = completed.field?.rect ?? pixelField(for: completed, traces: traces, bounds: bounds)
            else { return }
            result.append(Shot(t0: completed.start, t1: completed.end,
                               field: rect, carets: completed.carets))
        }

        for event in ordered {
            while cut < orderedCuts.count, orderedCuts[cut].start <= event.t {
                if let current = run, current.end < orderedCuts[cut].start { finish() }
                if event.t < orderedCuts[cut].end { break }
                cut += 1
            }
            if cut < orderedCuts.count, orderedCuts[cut].start <= event.t { continue }
            if event.kind == .down {
                if let current = run,
                   current.field?.rect.contains(CGPoint(x: Double(event.x), y: Double(event.y))) != true {
                    finish()
                }
                continue
            }
            let index = Int(event.axFrameIndex) - 1
            let frame = ax.indices.contains(index) ? ax[index] : nil
            let observed = frame.flatMap { field($0, at: event.t, bounds: bounds, backing: b) }
            let caretSample: Caret? = {
                guard let frame, let observed else { return nil }
                return caret(for: frame, in: observed.rect, at: event.t, backing: b)
            }()
            if let current = run {
                let same = current.field.flatMap { a in observed.map { a.matches($0, backing: b) } }
                let nestedField = current.field.flatMap { a in observed.map { Self.nested(a.rect, $0.rect) } }
                let sameSubject = same == true || nestedField == true
                let gap = sameSubject ? Self.sameFieldIdleTimeout : Self.idleTimeout
                // A container and the field inside it are one subject. Keep the
                // run open so the burst produces a single shot instead of a
                // short container burst plus a zero-length field burst.
                if (observed != nil && !sameSubject) || event.t - current.end > gap { finish() }
            }
            if var current = run {
                current.end = event.t
                if let observed {
                    if let existing = current.field, Self.nested(existing.rect, observed.rect),
                       observed.rect.width * observed.rect.height < existing.rect.width * existing.rect.height {
                        // The caret's smaller field is the subject; the parent
                        // container is only evidence of which field it was in.
                        current.field = observed
                    } else if current.field == nil {
                        current.field = observed
                    }
                }
                if let caretSample { current.carets.append(caretSample) }
                run = current
            } else {
                run = Run(start: event.t, end: event.t, field: observed,
                          carets: caretSample.map { [$0] } ?? [])
            }
        }
        finish()
        return result
    }

    static func intents(events: [InputEvent], ax: [AXFrame], traces: [TypingTrace],
                        W: Double, H: Double, b: Double, timeMap: TimeMap) -> [ZoomPlanner.Intent] {
        shots(events: events, ax: ax, traces: traces, W: W, H: H, b: b,
              trimStart: timeMap.trimStart, trimEnd: timeMap.trimEnd, cuts: timeMap.cuts).map {
            ZoomPlanner.Intent(kind: .typing, t: $0.t0, tEnd: $0.t1,
                               x: $0.field.midX, y: $0.field.midY,
                               rect: $0.field, frameRect: $0.field)
        }
    }
}
