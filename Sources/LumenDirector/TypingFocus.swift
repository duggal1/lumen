import Foundation
import CoreGraphics
import LumenCore
import LumenProject

/// The typing subject, rebuilt from scratch after the screenshots showed one
/// continuous typing session turning into a run of adjacent `2.0x Auto` blocks.
///
/// There is exactly one rule: one resolved field is one shot, and that shot
/// starts on the first keystroke and ends on the last. The caret is a validation
/// hint, never a camera target — it holds, then jumps on every key and on every
/// line wrap, which is what made the old path wander and re-aim late. There is
/// no synthetic "last click" fallback: an unresolved field produces no shot.
enum TypingFocus {
    struct Shot: Sendable, Equatable {
        var t0: Double
        var t1: Double
        var field: CGRect

        /// True for every instant of the keystroke run. Used by tests to check
        /// that the framing is synchronized with typing, not trailing it.
        func covers(_ t: Double) -> Bool { t >= t0 - 1e-9 && t <= t1 + 1e-9 }
    }

    /// Printable key-downs, identical to `Array.typingBursts()`'s predicate so
    /// the planner and the crop planner resolve the same subject.
    static func isTypingKey(_ e: InputEvent) -> Bool {
        guard e.kind == .keyDown, e.flags & 0x14 == 0, e.keyCode < 53,
              ![36, 48, 51].contains(e.keyCode) else { return false }
        if e.flags & 0x08 != 0, [123, 124, 125, 126].contains(e.keyCode) { return false }
        return true
    }

    /// One field rect. The FIRST keystroke selects it; later keystrokes cannot
    /// move the target. Only genuine pixel evidence can substitute for AX.
    static func resolveField(keys: [InputEvent], ax: [AXFrame], traces: [TypingTrace],
                             W: Double, H: Double, b: Double) -> CGRect? {
        let slack = 24 * b
        for e in keys.sorted(by: { $0.t < $1.t }) {
            guard e.axFrameIndex > 0, Int(e.axFrameIndex) <= ax.count else { continue }
            let f = ax[Int(e.axFrameIndex) - 1]
            // An unresolved sample, or one too old to describe this keystroke,
            // is not evidence about the field being typed into.
            if let a = f.anchor {
                if !a.resolved { continue }
                if a.sampledAt > 0, e.t - a.sampledAt > 2.0 { continue }
            }
            guard f.x.isFinite, f.y.isFinite, f.w.isFinite, f.h.isFinite,
                  f.w >= 4 * b, f.h >= 6 * b, f.w <= 1.05 * W, f.h <= 1.05 * H,
                  f.x + f.w > 0, f.y + f.h > 0, f.x < W, f.y < H else { continue }
            let field = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
            // If a caret is present it must belong to this field. Its position
            // is never returned; it only confirms the field is the right one.
            if let c = f.caret, c.x.isFinite, c.y.isFinite, c.w.isFinite, c.h.isFinite,
               c.h >= 6 * b, c.h <= 120 * b, c.w <= 80 * b {
                let px = c.w <= 3 * b ? c.x + c.w / 2 : c.x + c.w
                let py = c.y + c.h / 2
                guard px >= 0, px <= W, py >= 0, py <= H,
                      field.insetBy(dx: -slack, dy: -slack).contains(CGPoint(x: px, y: py)) else { continue }
            }
            return field
        }
        // Pixel tracer line/rect is evidence; a last-click centre is not.
        let t0 = keys.first?.t ?? -.infinity
        let t1 = keys.last?.t ?? .infinity
        if let tr = traces.first(where: { $0.t0 <= t1 + 0.15 && $0.t1 >= t0 - 0.15 }) {
            for candidate in [tr.line, tr.rect] {
                if let r = candidate, r.width > 0, r.height > 0,
                   r.origin.x.isFinite, r.origin.y.isFinite,
                   r.width.isFinite, r.height.isFinite { return r }
            }
        }
        return nil
    }

    private static func sameField(_ a: CGRect, _ b: CGRect) -> Bool {
        let tol = 2.0
        return abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol &&
               abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// One shot per resolved field. Two bursts into the same field with a short
    /// pause between them are one interaction, not two identical zoom blocks.
    static func shots(events: [InputEvent], ax: [AXFrame], traces: [TypingTrace],
                      W: Double, H: Double, b: Double,
                      trimStart: Double, trimEnd: Double) -> [Shot] {
        let keys = events.filter(isTypingKey).sorted { $0.t < $1.t }
        guard !keys.isEmpty else { return [] }
        var bursts: [(t0: Double, t1: Double, keys: [InputEvent])] = []
        var first = 0
        for i in keys.indices {
            let last = i == keys.count - 1 || keys[i + 1].t - keys[i].t > 0.9
            if last {
                bursts.append((keys[first].t, keys[i].t, Array(keys[first...i])))
                first = i + 1
            }
        }
        var out: [Shot] = []
        for burst in bursts {
            guard burst.t0 >= trimStart - 1e-6, burst.t0 <= trimEnd + 1e-6 else { continue }
            guard let field = resolveField(keys: burst.keys, ax: ax, traces: traces,
                                           W: W, H: H, b: b),
                  field.width > 0, field.height > 0 else { continue }
            if let prev = out.last, sameField(prev.field, field),
               burst.t0 - prev.t1 <= 1.5 {
                out[out.count - 1].t1 = burst.t1
            } else {
                out.append(Shot(t0: burst.t0, t1: burst.t1, field: field))
            }
        }
        return out
    }

    /// The typing path's only output. No follow path is ever produced.
    static func intents(events: [InputEvent], ax: [AXFrame], traces: [TypingTrace],
                        W: Double, H: Double, b: Double,
                        trimStart: Double, trimEnd: Double) -> [ZoomPlanner.Intent] {
        shots(events: events, ax: ax, traces: traces, W: W, H: H, b: b,
              trimStart: trimStart, trimEnd: trimEnd).map { s in
            var i = ZoomPlanner.Intent(kind: .typing, t: s.t0, tEnd: s.t1,
                                       x: s.field.midX, y: s.field.midY)
            i.rect = s.field
            i.frameRect = s.field
            return i
        }
    }
}
