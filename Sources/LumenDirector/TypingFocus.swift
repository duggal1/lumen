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

        func compatibleContext(_ next: Field) -> Bool {
            guard let a = anchor, let b = next.anchor else { return true }
            if a.windowID != b.windowID || a.appName != b.appName || a.host != b.host { return false }
            return a.epoch == 0 || b.epoch == 0 || a.epoch == b.epoch
        }

        func matches(_ next: Field, backing: Double) -> Bool {
            guard compatibleContext(next) else { return false }
            if let a = anchor, let b = next.anchor,
               a.epoch != 0, a.epoch == b.epoch { return true }
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
        // A held guess, blink, or unrelated animation is not typing
        // evidence. Require actual ink/caret changes during this run.
        let ranked = matches.compactMap { trace -> (TypingTrace, [TypingTrace.Sample])? in
            let samples = trace.samples.filter {
                $0.t.isFinite && $0.t >= run.start - 0.15 && $0.t <= run.end + 0.15 &&
                $0.x.isFinite && $0.y.isFinite && $0.confidence.isFinite &&
                $0.confidence >= 0.65 &&
                ($0.evidence == .caret || $0.evidence == .lineWrap || $0.evidence == .backspace)
            }
            guard samples.count >= 2,
                  let first = samples.map(\.t).min(), let last = samples.map(\.t).max(),
                  last - first >= 0.03 else { return nil }
            return (trace, samples)
        }.sorted {
            if $0.1.count != $1.1.count { return $0.1.count > $1.1.count }
            return $0.0.t0 < $1.0.t0
        }
        for (trace, samples) in ranked {
            for candidate in [trace.line, trace.rect] {
                guard let rect = candidate, rect.minX.isFinite, rect.minY.isFinite,
                      rect.width.isFinite, rect.height.isFinite else { continue }
                let clipped = bounds.intersection(rect)
                guard !clipped.isEmpty, clipped.width > 1, clipped.height > 1,
                      clipped.width <= bounds.width * 0.95, clipped.height <= bounds.height * 0.95 else { continue }
                let supported = samples.filter {
                    clipped.insetBy(dx: -24, dy: -24).contains(CGPoint(x: $0.x, y: $0.y))
                }.count
                if supported >= 2, supported * 4 >= samples.count * 3 { return clipped }
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
                let nestedField = current.field.flatMap { a in observed.map { a.compatibleContext($0) && Self.nested(a.rect, $0.rect) } }
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
                    if let existing = current.field, existing.compatibleContext(observed), Self.nested(existing.rect, observed.rect),
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
