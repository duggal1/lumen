import Foundation
import CoreGraphics
import LumenCore
import LumenProject

enum TypingFocus {
    struct Shot: Sendable, Equatable {
        var t0: Double
        var t1: Double
        var field: CGRect

        func covers(_ t: Double) -> Bool { t >= t0 - 1e-9 && t <= t1 + 1e-9 }
    }

    private struct Run {
        var start: Double
        var end: Double
        var field: Field?
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
            result.append(Shot(t0: completed.start, t1: completed.end, field: rect))
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
            let observed = ax.indices.contains(index) ? field(ax[index], at: event.t, bounds: bounds, backing: b) : nil
            if let current = run {
                let same = current.field.flatMap { a in observed.map { a.matches($0, backing: b) } }
                if same == false || event.t - current.end > (same == true ? 1.5 : 0.9) { finish() }
            }
            if var current = run {
                current.end = event.t
                if current.field == nil { current.field = observed }
                run = current
            } else {
                run = Run(start: event.t, end: event.t, field: observed)
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
