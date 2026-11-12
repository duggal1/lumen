import Foundation
import LumenCore
import LumenProject

enum SpeedRamps {
    static func plan(events: [InputEvent], vad: [ClosedRange<Double>], tm: TimeMap, audio: AudioPlan, backing: Double) -> [SpeedRamp] {
        let minIdle = max(audio.speedRampMinIdle, 1.0)
        var act: [Double] = [tm.trimStart]
        var lx = -1e6, ly = -1e6
        for e in events {
            switch e.kind {
            case .move, .drag:
                if hypot(Double(e.x) - lx, Double(e.y) - ly) > 2 * backing { act.append(e.t); lx = Double(e.x); ly = Double(e.y) }
            default: act.append(e.t)
            }
        }
        for c in tm.cuts { act.append(c.start); act.append(c.end) }       // a ramp never spans a cut
        act.append(tm.trimEnd)
        act = act.filter { $0 >= tm.trimStart && $0 <= tm.trimEnd }.sorted()
        var out: [SpeedRamp] = []
        guard act.count > 1 else { return out }
        for i in 0..<(act.count - 1) {
            let a = act[i], b = act[i + 1]
            guard b - a >= minIdle, !tm.isCut((a + b) / 2) else { continue }
            if vad.contains(where: { $0.upperBound > a && $0.lowerBound < b }) { continue }
            let speed = min(audio.speedRampMaxSpeed, (b - a) / 0.8)
            if speed >= 1.5 {
                let start = a + 0.25, end = b - 0.25
                var ramp = SpeedRamp(start: start, end: end, speed: speed)
                ramp.id = ZoomPlanner.stableID(start, end)
                out.append(ramp)
            }
        }
        return out
    }
}

/// Auto-zoom decision layer v4.
/// Only a left click or a typing burst starts a zoom. Typing is framed on the CARET
/// (never the centre of an element), one scene per burst, with a tight follow window.
enum ZoomPlanner {
    struct PathPoint { var t: Double; var p: SIMD2<Double> }
    struct Intent {
        enum Kind { case click, typing }
        var kind: Kind
        var t: Double, tEnd: Double            // source seconds
        var x: Double, y: Double               // click pixel, or caret at burst start (source px)
        var rect: CGRect? = nil                // click: verified AX element; typing: the field
        var path: [PathPoint] = []             // typing only: smoothed caret path
    }
    private struct Open { var start: Double, scale: Double, c: SIMD2<Double> }
    private struct Fix { var t: Double; var p: SIMD2<Double>; var field: CGRect? }

    /// Same source-time window -> same id across replans.
    static func stableID(_ s: Double, _ e: Double) -> UUID {
        func h(_ v: UInt64) -> String {
            let x = String(v, radix: 16, uppercase: true)
            return String(repeating: "0", count: max(16 - x.count, 0)) + x
        }
        let f = h(s.bitPattern) + h(e.bitPattern)
        func sl(_ o: Int, _ n: Int) -> String {
            String(f[f.index(f.startIndex, offsetBy: o)..<f.index(f.startIndex, offsetBy: o + n)])
        }
        return UUID(uuidString: "\(sl(0, 8))-\(sl(8, 4))-\(sl(12, 4))-\(sl(16, 4))-\(sl(20, 12))")!
    }

    /// AX coordinates are in captured source pixels. A stale frame or a large
    /// parent container can pull the camera hundreds of pixels off target.
    static func usableAX(_ frame: AXFrame, x: Double, y: Double, width: Double,
                         height: Double, backing: Double) -> Bool {
        let slack = 8 * backing
        return frame.x.isFinite && frame.y.isFinite &&
            frame.w.isFinite && frame.h.isFinite &&
            frame.w >= 8 * backing && frame.h >= 8 * backing &&
            frame.w <= 0.28 * width && frame.h <= 0.28 * height &&
            x >= frame.x - slack && x <= frame.x + frame.w + slack &&
            y >= frame.y - slack && y <= frame.y + frame.h + slack &&
            frame.x + frame.w > 0 && frame.y + frame.h > 0 &&
            frame.x < width && frame.y < height
    }

    // MARK: Caret resolution

    /// Where was the caret at each key? Never falls back to the centre of a big element.
    private static func fixes(t0: Double, t1: Double, keys: [InputEvent], ax: [AXFrame], traces: [TypingTrace],
                              click: InputEvent?, W: Double, H: Double, b: Double) -> [Fix] {
        var out: [Fix] = []
        for e in keys where e.t >= t0 && e.t <= t1 {
            guard e.axFrameIndex > 0, Int(e.axFrameIndex) <= ax.count else { continue }
            let f = ax[Int(e.axFrameIndex) - 1]
            guard f.x.isFinite, f.y.isFinite, f.w.isFinite, f.h.isFinite,
                  f.w >= 4 * b, f.h >= 6 * b, f.w <= 1.05 * W, f.h <= 1.05 * H,
                  f.x + f.w > 0, f.y + f.h > 0, f.x < W, f.y < H else { continue }
            let field = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
            if let c = f.caret, c.x.isFinite, c.y.isFinite, c.w.isFinite, c.h.isFinite,
               c.h >= 6 * b, c.h <= 120 * b, c.w <= 80 * b {
                // A zero-width caret is its own centre; a glyph box means "insertion point = right edge".
                let px = c.w <= 3 * b ? c.x + c.w / 2 : c.x + c.w
                let py = c.y + c.h / 2
                if px >= 0, px <= W, py >= 0, py <= H,
                   field.insetBy(dx: -24 * b, dy: -24 * b).contains(CGPoint(x: px, y: py)) {
                    out.append(Fix(t: e.t, p: SIMD2(px, py), field: field))
                    continue
                }
            }
            // No trustworthy caret: only a single-line field may stand in, and only its left part.
            if f.h <= 0.09 * H {
                out.append(Fix(t: e.t, p: SIMD2(f.x + min(f.w * 0.35, 0.18 * W), field.midY), field: field))
            }
        }
        if !out.isEmpty { return out }
        if let tr = traces.first(where: { $0.t0 <= t1 + 0.15 && $0.t1 >= t0 - 0.15 && !$0.samples.isEmpty }) {
            return tr.samples.filter { $0.x.isFinite && $0.y.isFinite }
                .map { Fix(t: $0.t, p: SIMD2($0.x, $0.y), field: tr.rect) }
        }
        if let c = click, c.x.isFinite, c.y.isFinite {
            let p = SIMD2(Double(c.x), Double(c.y))
            return [Fix(t: t0, p: p, field: nil), Fix(t: t1, p: p, field: nil)]
        }
        return []                                   // better no zoom than a wrong one
    }

    /// 30 Hz caret path, hold-then-jump across pauses, zero-phase smoothed.
    private static func smoothPath(_ fx: [Fix], t0: Double, t1: Double) -> [PathPoint] {
        guard let first = fx.first, let lastFix = fx.last else { return [] }
        let dt = 1.0 / 30
        let start = min(t0, first.t), end = max(t1, lastFix.t) + 0.1
        let n = max(Int((end - start) / dt) + 1, 2)
        var xs: [Double] = [], ys: [Double] = []
        xs.reserveCapacity(n); ys.reserveCapacity(n)
        var j = 0
        for i in 0..<n {
            let t = start + Double(i) * dt
            while j + 1 < fx.count, fx[j + 1].t <= t { j += 1 }
            let a = fx[j]
            if j + 1 < fx.count, t > a.t {
                let c = fx[j + 1], gap = c.t - a.t
                let u = gap > 0.6 ? clamp((t - (c.t - 0.15)) / 0.15, 0, 1) : clamp((t - a.t) / max(gap, 1e-6), 0, 1)
                xs.append(a.p.x + (c.p.x - a.p.x) * u); ys.append(a.p.y + (c.p.y - a.p.y) * u)
            } else { xs.append(a.p.x); ys.append(a.p.y) }
        }
        xs = zeroPhaseSmooth(xs, omega: 9, dt: dt)
        ys = zeroPhaseSmooth(ys, omega: 9, dt: dt)
        return (0..<n).map { PathPoint(t: start + Double($0) * dt, p: SIMD2(xs[$0], ys[$0])) }
    }

    // MARK: Plan

    static func plan(events: [InputEvent], ax: [AXFrame], typing: [TypingTrace], activity: [ActivityPoint],
                     src: SourceInfo, p: CameraParams, tm: TimeMap, avoid: [ClosedRange<Double>]) -> [ZoomSegment] {
        let W = Double(src.width), H = Double(src.height), b = max(src.backingScale, 1)
        guard W > 0, H > 0 else { return [] }
        if p.preset == .fixed {
            return [ZoomSegment(id: stableID(tm.trimStart, tm.trimEnd), start: tm.trimStart, end: tm.trimEnd,
                                scale: p.baseScale, focus: .follow, origin: .auto)]
        }
        let sorted = events.sorted { $0.t < $1.t }
        func ok(_ t: Double) -> Bool { t.isFinite && t >= tm.trimStart + 0.3 && t <= tm.trimEnd - 0.8 && !tm.isCut(t) }
        let hi = clamp(p.maxScale, 1.3, 2.6), lo = clamp(p.minScale, 1.2, hi)
        let hold = min(p.hold, max(p.zoomOutGap - 0.2, 0.3))

        // ---- 1. intents: ONLY clicks and typing bursts ----
        var intents: [Intent] = []
        var lastClick: Intent?
        for e in sorted where e.kind == .down && e.button == 0 && e.flags & 0x14 == 0 && ok(e.t) {
            let x = Double(e.x), y = Double(e.y)
            guard x >= 0, x <= W, y >= 0, y <= H else { continue }
            if let l = lastClick, e.t - l.t < 0.6, hypot(x - l.x, y - l.y) < 24 * b { continue }   // double-click = one intent
            var rect: CGRect?
            if e.axFrameIndex > 0, Int(e.axFrameIndex) <= ax.count {
                let f = ax[Int(e.axFrameIndex) - 1]
                if usableAX(f, x: x, y: y, width: W, height: H, backing: b) { rect = CGRect(x: f.x, y: f.y, width: f.w, height: f.h) }
            }
            let i = Intent(kind: .click, t: e.t, tEnd: e.t, x: x, y: y, rect: rect)
            intents.append(i); lastClick = i
        }
        let keys = sorted.filter { $0.kind == .keyDown }
        for burst in sorted.typingBursts() where ok(burst.t0) {
            let click = sorted.last(where: { $0.kind == .down && $0.button == 0 && $0.t <= burst.t0 && burst.t0 - $0.t < 20 })
            let fx = fixes(t0: burst.t0, t1: burst.t1, keys: keys, ax: ax, traces: typing, click: click, W: W, H: H, b: b)
            guard !fx.isEmpty else { continue }
            let path = smoothPath(fx, t0: burst.t0, t1: burst.t1)
            guard let first = path.first else { continue }
            let field = fx.compactMap(\.field).max { $0.width * $0.height < $1.width * $1.height }
            intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1, x: first.p.x, y: first.p.y, rect: field, path: path))
        }
        if !sorted.contains(where: \.hasPosition) {            // device/imported clip: no input log
            var lastT = -10.0
            for a in activity where ok(a.t) && a.t - lastT > 1.5 {
                intents.append(Intent(kind: .click, t: a.t, tEnd: a.t, x: a.x, y: a.y)); lastT = a.t
            }
        }
        intents.sort { $0.t < $1.t }

        // ---- 2. scenes ----
        func half(_ s: Double) -> SIMD2<Double> { SIMD2(W, H) / (2 * s) }
        func clampC(_ c: SIMD2<Double>, _ s: Double) -> SIMD2<Double> {
            let h = half(s); return SIMD2(clamp(c.x, h.x, W - h.x), clamp(c.y, h.y, H - h.y))
        }
        var shots: [ZoomSegment] = []
        var cur: Open?
        var last = 0.0                                  // last activity in the open scene
        var prevScale: Double?
        let keep = sorted.filter { ($0.kind == .scroll || $0.kind == .drag) && ok($0.t) }
        var ki = 0

        func close(at end: Double) {
            guard let o = cur else { return }
            cur = nil
            guard end - o.start > 0.2, o.scale > 1.001 else { return }
            shots.append(ZoomSegment(id: stableID(o.start, end), start: o.start, end: end, scale: o.scale,
                                     focus: .fixed(x: o.c.x / W, y: o.c.y / H), origin: .auto))
        }
        func retarget(_ c: SIMD2<Double>, at t: Double) {
            guard let o = cur else { return }
            let nc = clampC(c, o.scale)
            let moved = (nc - o.c) / half(o.scale)
            if hypot(moved.x, moved.y) < 0.12 { return }
            if t - o.start <= 0.2 { cur = Open(start: o.start, scale: o.scale, c: nc); return }
            close(at: t); cur = Open(start: t, scale: o.scale, c: nc)
        }
        func ensureVisible(_ pt: SIMD2<Double>, at t: Double) {          // clicks only
            guard let o = cur else { return }
            let d = (pt - o.c) / half(o.scale)
            guard abs(d.x) > p.safeZone || abs(d.y) > p.safeZone else { return }
            retarget(pt, at: t)                                          // click anchor is the exact pixel
        }
        func absorbKeepAlive(upTo t: Double) {
            guard let o = cur else { return }
            while ki < keep.count, keep[ki].t < t {
                let e = keep[ki]; ki += 1
                let d = (SIMD2(Double(e.x), Double(e.y)) - o.c) / half(o.scale)
                if e.t - last <= p.zoomOutGap, abs(d.x) <= 1, abs(d.y) <= 1 { last = max(last, e.t) }
            }
        }
        /// Caret sits ~42 % across the view, vertically centred.
        func typingCenter(_ pt: SIMD2<Double>, _ s: Double) -> SIMD2<Double> {
            clampC(SIMD2(pt.x + 0.16 * half(s).x, pt.y), s)
        }
        /// Tight follow window: the caret never gets to wander to the right/bottom edge.
        func follow(_ path: [PathPoint], from t0: Double) {
            var lastMove = t0 - 1
            for s in path where s.t >= t0 && ok(s.t) {
                guard let o = cur else { return }
                let h = half(o.scale), d = (s.p - o.c) / h
                let outside = d.x > 0.06 || d.x < -0.34 || abs(d.y) > 0.22
                guard outside, s.t - lastMove >= 0.45 else { continue }
                let target = typingCenter(s.p, o.scale)
                let moved = (target - o.c) / h
                guard hypot(moved.x, moved.y) >= 0.12 else { continue }  // clamped to the same view: nothing to do
                retarget(target, at: s.t)
                lastMove = s.t
            }
        }
        func chooseScale(_ i: Intent, prev: Double?) -> Double {
            var s: Double
            if i.kind == .typing {
                // viewport ≈ field + 30 %, between 42 % and 62 % of the screen
                let fieldW = min(i.rect?.width ?? W * 0.35, W)
                s = W / min(max(fieldW * 1.3, W * 0.42), W * 0.62)
                s = clamp(s, min(1.6, hi), min(2.0, hi))
            } else if let r = i.rect {
                // CONTEXT-sized, not element-sized: a small button must not mean a big zoom
                let fit = min(W / max(r.width * 2.4, 1), H / max(r.height * 2.4, 1))
                if fit < 1.2 { return 1 }                                // element already fills the view
                s = clamp(min(fit, 1.7), lo, hi)
            } else {
                s = clamp(1.5, lo, hi)
            }
            guard let prev, prev > 1.001 else { return s }
            return abs(log(s / prev)) < log(1.12) ? clamp(prev, lo, hi) : s
        }

        for it in intents {
            absorbKeepAlive(upTo: it.t)
            let continuing = cur != nil && it.t - last <= p.zoomOutGap
            let want = chooseScale(it, prev: continuing ? cur?.scale : prevScale)
            switch it.kind {
            case .click:
                if continuing, let o = cur {
                    if want > 1.001, abs(log(want / o.scale)) > log(1.35) {
                        close(at: it.t)
                        cur = Open(start: it.t, scale: want, c: clampC(SIMD2(it.x, it.y), want)); prevScale = want
                    } else {
                        ensureVisible(SIMD2(it.x, it.y), at: it.t)
                    }
                } else {
                    close(at: last + hold)
                    if want > 1.001 {
                        prevScale = want
                        cur = Open(start: it.t, scale: want, c: clampC(SIMD2(it.x, it.y), want))
                    }
                }
            case .typing:
                if continuing, let o = cur, abs(log(want / o.scale)) <= log(1.35) {
                    // keep the zoom the user already saw; follow() moves the camera onto the caret
                } else {
                    close(at: continuing ? it.t : last + hold)
                    prevScale = want
                    cur = Open(start: it.t, scale: want, c: typingCenter(SIMD2(it.x, it.y), want))
                }
                follow(it.path, from: it.t)
            }
            last = max(last, it.kind == .typing ? it.tEnd + 0.1 : it.tEnd)
        }
        absorbKeepAlive(upTo: .infinity)
        close(at: min(last + hold, tm.trimEnd))

        return shots.filter { s in
            !avoid.contains { $0.lowerBound < s.end && $0.upperBound > s.start - p.leadIn } &&
            tm.output(atSource: s.end) - tm.output(atSource: s.start) > 0.2
        }
    }
}