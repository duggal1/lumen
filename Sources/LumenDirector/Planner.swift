import Foundation
import LumenCore
import LumenProject

enum SpeedRamps {
    static func plan(events: [InputEvent], vad: [ClosedRange<Double>], tm: TimeMap, audio: AudioPlan, backing: Double, activity: [ActivityPoint] = []) -> [SpeedRamp] {
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
        for point in activity where point.t.isFinite { act.append(point.t) }
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

/// Chooses framing and source-time scenes; the solver owns camera motion.
///
/// The planner is attention-first. Every input (click, typing burst, hover
/// dwell, visual change) is an intent with a position, a rect and a time. The
/// intents are grouped into scenes, and every scene carries a follow path so
/// the camera can glide with the pointer instead of freezing on the click.
enum ZoomPlanner {
    struct PathPoint { var t: Double; var p: SIMD2<Double> }
    typealias FollowPoint = PathPoint
    struct ZoomPlan {
        var segments: [ZoomSegment] = []
        var follow: [UUID: [FollowPoint]] = [:]
    }
    enum IntentKind { case click, typing, hover, visual }
    struct Intent {
        var kind: IntentKind
        var t: Double, tEnd: Double            // source seconds
        var x: Double, y: Double               // click pixel, or caret at burst start (source px)
        var rect: CGRect? = nil                // click: verified AX element; typing: the field
        var path: [PathPoint] = []             // typing only: smoothed caret path
    }
    private struct Open {
        var start: Double, scale: Double, c: SIMD2<Double>
        var path: [FollowPoint] = []
        var kind: IntentKind = .click
    }
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

    /// The smallest resolved AX element that contains `p`. A browser window is
    /// a single AX element larger than the text field inside it; picking the
    /// biggest element aims the camera at the window and loses the caret.
    static func smallestField(containing p: SIMD2<Double>, in frames: [AXFrame],
                              slack: Double, width: Double, height: Double,
                              backing: Double) -> AXFrame? {
        var best: AXFrame?
        var bestArea = Double.greatestFiniteMagnitude
        for f in frames {
            guard f.x.isFinite, f.y.isFinite, f.w.isFinite, f.h.isFinite,
                  f.w >= 4 * backing, f.h >= 6 * backing,
                  f.w <= 1.05 * width, f.h <= 1.05 * height,
                  f.x + f.w > 0, f.y + f.h > 0, f.x < width, f.y < height else { continue }
            if let a = f.anchor, !a.resolved { continue }
            guard p.x >= f.x - slack, p.x <= f.x + f.w + slack,
                  p.y >= f.y - slack, p.y <= f.y + f.h + slack else { continue }
            let area = f.w * f.h
            if area < bestArea { bestArea = area; best = f }
        }
        return best
    }

    private static func caretFixes(t0: Double, t1: Double, keys: [InputEvent], ax: [AXFrame], traces: [TypingTrace],
                                   W: Double, H: Double, b: Double) -> (fixes: [Fix], tracked: Bool, field: CGRect?) {
        var carets: [Fix] = []
        var fields: [CGRect] = []
        let slack = 24 * b
        for e in keys where e.t >= t0 && e.t <= t1 {
            guard e.axFrameIndex > 0, Int(e.axFrameIndex) <= ax.count else { continue }
            let f = ax[Int(e.axFrameIndex) - 1]
            // Provenance: an unresolved sample, or one older than the burst,
            // is not evidence about this keystroke.
            if let a = f.anchor {
                if !a.resolved { continue }
                if a.sampledAt > 0, e.t - a.sampledAt > 2.0 { continue }
            }
            guard f.x.isFinite, f.y.isFinite, f.w.isFinite, f.h.isFinite,
                  f.w >= 4 * b, f.h >= 6 * b, f.w <= 1.05 * W, f.h <= 1.05 * H,
                  f.x + f.w > 0, f.y + f.h > 0, f.x < W, f.y < H else { continue }
            let field = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
            fields.append(field)
            if let c = f.caret, c.x.isFinite, c.y.isFinite, c.w.isFinite, c.h.isFinite,
               c.h >= 6 * b, c.h <= 120 * b, c.w <= 80 * b {
                let px = c.w <= 3 * b ? c.x + c.w / 2 : c.x + c.w
                let py = c.y + c.h / 2
                if px >= 0, px <= W, py >= 0, py <= H,
                   field.insetBy(dx: -slack, dy: -slack).contains(CGPoint(x: px, y: py)) {
                    carets.append(Fix(t: e.t, p: SIMD2(px, py), field: field))
                }
            }
        }
        if !carets.isEmpty {
            // The framing rect is the smallest field that actually contains the
            // caret, not the largest field seen during the burst.
            let first = carets[0].p
            let smallest = fields
                .filter { $0.insetBy(dx: -slack, dy: -slack).contains(CGPoint(x: first.x, y: first.y)) }
                .min { $0.width * $0.height < $1.width * $1.height }
            return (carets, true, smallest)
        }
        if let tr = traces.first(where: { $0.t0 <= t1 + 0.15 && $0.t1 >= t0 - 0.15 }) {
            let samples = tr.samples.filter { $0.confidence >= 0.4 && $0.t.isFinite && $0.x.isFinite && $0.y.isFinite }
            if samples.count >= 2 {
                let line = tr.line ?? tr.rect
                return (samples.map { Fix(t: $0.t, p: SIMD2($0.x, $0.y), field: line) }, true, line)
            }
        }
        return ([], false, nil)
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

    private static func smoothFollow(_ pts: [FollowPoint], W: Double, H: Double) -> [FollowPoint] {
        guard pts.count >= 2 else { return pts }
        let sorted = pts.sorted { $0.t < $1.t }
        let fixes = sorted.map { Fix(t: $0.t, p: SIMD2($0.p.x * W, $0.p.y * H), field: nil) }
        let t0 = fixes.first!.t, t1 = fixes.last!.t
        return smoothPath(fixes, t0: t0, t1: t1).map {
            FollowPoint(t: $0.t, p: SIMD2($0.p.x / W, $0.p.y / H))
        }
    }

    /// Normalised bounding-box diagonal of a follow path. A static path is a
    /// fixed target, not a follow target.
    static func pathExtent(_ pts: [FollowPoint]) -> Double {
        guard let first = pts.first else { return 0 }
        var lo = first.p, hi = first.p
        for p in pts { lo = SIMD2(min(lo.x, p.p.x), min(lo.y, p.p.y)); hi = SIMD2(max(hi.x, p.p.x), max(hi.y, p.p.y)) }
        return hypot(hi.x - lo.x, hi.y - lo.y)
    }

    // MARK: Plan

    /// Segments only — the old signature, kept for callers that do not need
    /// the continuous follow paths.
    static func planSegments(events: [InputEvent], ax: [AXFrame], typing: [TypingTrace], activity: [ActivityPoint],
                             src: SourceInfo, p: CameraParams, tm: TimeMap, avoid: [ClosedRange<Double>]) -> [ZoomSegment] {
        plan(events: events, ax: ax, typing: typing, activity: activity, src: src, p: p, tm: tm, avoid: avoid).segments
    }

    static func plan(events: [InputEvent], ax: [AXFrame], typing: [TypingTrace], activity: [ActivityPoint],
                     src: SourceInfo, p: CameraParams, tm: TimeMap, avoid: [ClosedRange<Double>]) -> ZoomPlan {
        let W = Double(src.width), H = Double(src.height), b = max(src.backingScale, 1)
        guard W > 0, H > 0 else { return ZoomPlan() }
        if p.preset == .fixed {
            let segment = ZoomSegment(id: stableID(tm.trimStart, tm.trimEnd), start: tm.trimStart, end: tm.trimEnd,
                                      scale: p.baseScale, focus: .follow, origin: .auto)
            return ZoomPlan(segments: [segment])
        }
        let sorted = events.sorted { $0.t < $1.t }
        func ok(_ t: Double) -> Bool { t.isFinite && t >= tm.trimStart + 0.2 && t <= tm.trimEnd - 0.2 && !tm.isCut(t) }
        let hi = clamp(max(p.maxScale, p.baseScale * 1.2), 1.3, 6.0)
        let lo = clamp(p.minScale, 1.0, hi)
        let hold = max(p.hold.isFinite ? p.hold : 0.9, 0.3)
        let gap = max(p.zoomOutGap.isFinite ? p.zoomOutGap : 2.6, hold + 0.5)

        // Input intent takes priority over autonomous visual framing.
        var intents: [Intent] = []
        var lastClick: Intent?
        for e in sorted where e.kind == .down && e.button == 0 && e.flags & 0x14 == 0 && ok(e.t) {
            let x = Double(e.x), y = Double(e.y)
            guard x >= 0, x <= W, y >= 0, y <= H else { continue }
            if let l = lastClick, e.t - l.t < 0.6, hypot(x - l.x, y - l.y) < 24 * b { continue }   // double-click = one intent
            var rect: CGRect?
            if e.axFrameIndex > 0, Int(e.axFrameIndex) <= ax.count {
                let f = ax[Int(e.axFrameIndex) - 1]
                if usableAX(f, x: x, y: y, width: W, height: H, backing: b) {
                    rect = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
                }
            }
            let i = Intent(kind: .click, t: e.t, tEnd: e.t, x: x, y: y, rect: rect)
            intents.append(i); lastClick = i
        }
        let keys = sorted.filter { $0.kind == .keyDown }
        for burst in sorted.typingBursts() where ok(burst.t0) {
            let r = caretFixes(t0: burst.t0, t1: burst.t1, keys: keys, ax: ax, traces: typing, W: W, H: H, b: b)
            if r.tracked {
                let path = smoothPath(r.fixes, t0: burst.t0, t1: burst.t1)
                guard let first = path.first else { continue }
                intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1, x: first.p.x, y: first.p.y,
                                      rect: r.field, path: path))
            } else if let field = r.field, field.height <= 0.45 * H {
                intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1, x: field.midX, y: field.midY,
                                      rect: field, path: []))
            } else if let lc = lastClick, burst.t0 - lc.t <= 30 {
                let synth = CGRect(x: lc.x - W * 0.175, y: lc.y - H * 0.05, width: W * 0.35, height: H * 0.10)
                intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1, x: lc.x, y: lc.y,
                                      rect: synth, path: []))
            }
        }
        intents += VisualZoom.intents(activity, events: sorted, input: intents, src: src, tm: tm)
        intents += hoverIntents(events: sorted, src: src, p: p, tm: tm, existing: intents)
        intents.sort { $0.t < $1.t }

        // ---- 2. scenes ----
        func half(_ s: Double) -> SIMD2<Double> { SIMD2(W, H) / (2 * s) }
        func clampC(_ c: SIMD2<Double>, _ s: Double) -> SIMD2<Double> {
            let h = half(s); return SIMD2(clamp(c.x, h.x, W - h.x), clamp(c.y, h.y, H - h.y))
        }
        func inside(_ p: SIMD2<Double>, _ c: SIMD2<Double>, _ s: Double, pad: Double = 0.75) -> Bool {
            let h = half(s) * pad
            return abs(p.x - c.x) <= h.x && abs(p.y - c.y) <= h.y
        }
        func withPoint(_ o: Open, _ t: Double, _ p: SIMD2<Double>) -> Open {
            var r = o
            let n = SIMD2(p.x / W, p.y / H)
            if r.path.isEmpty || t - r.path[r.path.count - 1].t > 1.0 / 60 || hypot(n.x - r.path[r.path.count - 1].p.x, n.y - r.path[r.path.count - 1].p.y) > 1e-4 {
                r.path.append(FollowPoint(t: t, p: n))
            }
            return r
        }
        var shots: [ZoomSegment] = []
        var followPaths: [UUID: [FollowPoint]] = [:]
        var kinds: [UUID: IntentKind] = [:]
        var centers: [UUID: SIMD2<Double>] = [:]
        var cur: Open?
        var last = 0.0
        var prevScale: Double?

        func close(at end: Double) {
            guard let o = cur else { return }
            cur = nil
            let e = min(max(end, o.start + 0.2), tm.trimEnd)
            guard e - o.start > 0.2, o.scale > 1.001 else { return }
            let id = stableID(o.start, e)
            var path = o.path.filter { $0.t >= o.start - 1e-6 && $0.t <= e + 1e-6 }
            if path.isEmpty || path[0].t > o.start + 0.05 {
                path.insert(FollowPoint(t: o.start, p: SIMD2(o.c.x / W, o.c.y / H)), at: 0)
            }
            let focus: Focus
            if path.count >= 2, pathExtent(path) > 0.008 {
                focus = .follow
                followPaths[id] = path
            } else {
                focus = .fixed(x: o.c.x / W, y: o.c.y / H)
            }
            kinds[id] = o.kind
            centers[id] = o.c
            shots.append(ZoomSegment(id: id, start: o.start, end: e, scale: o.scale, focus: focus, origin: .auto))
        }

        func chooseScale(_ i: Intent, prev: Double?) -> Double {
            var s: Double
            switch i.kind {
            case .visual:
                guard let r = i.rect else { return 1 }
                let fit = min(W / max(r.width * 1.35, 1), H / max(r.height * 1.35, 1))
                guard fit >= max(lo, 1.2) else { return 1 }
                s = min(clamp(fit, lo, hi), 1.6)
            case .hover:
                s = clamp(1.2 + 0.5 * clamp(p.sensitivity, 0, 1), lo, min(hi, 1.6))
            case .click, .typing:
                s = clamp(p.baseScale, 1.0, hi)
                if let r = i.rect {
                    // A small control earns a closer look; a large surface only
                    // a gentle one. The base scale stays the primary control.
                    let coverage = (r.width * r.height) / (W * H)
                    let factor = clamp(pow(0.06 / max(coverage, 1e-4), 0.18), 0.85, 1.45)
                    s = clamp(p.baseScale * factor, lo, hi)
                }
                if i.kind == .typing, !i.path.isEmpty, s < 1.4 { s = min(clamp(1.5, lo, hi), hi) }
            }
            guard s > 1.001 else { return 1 }
            if let prev, prev > 1.001, abs(log(s / prev)) < log(1.12) { return clamp(prev, lo, hi) }
            return s
        }

        for it in intents {
            let want = chooseScale(it, prev: prevScale)
            let anchor = SIMD2(it.x, it.y)
            let strong = it.kind == .click || it.kind == .typing
            if want <= 1.001 {
                if cur != nil { last = max(last, it.tEnd) }
                continue
            }
            guard var o = cur else {
                var fresh = Open(start: it.t, scale: want, c: clampC(anchor, want), kind: it.kind)
                fresh = withPoint(fresh, it.t, anchor)
                if it.kind == .typing { fresh.path.append(contentsOf: it.path.map { FollowPoint(t: $0.t, p: SIMD2($0.p.x / W, $0.p.y / H)) }) }
                cur = fresh
                prevScale = want
                last = max(last, it.tEnd + (it.kind == .typing ? 0.1 : 0))
                continue
            }
            let gapOK = it.t - last <= gap
            let moved = hypot(anchor.x - o.c.x, anchor.y - o.c.y) / max(half(want).x, 1)
            if strong, !gapOK || moved > 0.55 {
                close(at: it.t)
                var fresh = Open(start: it.t, scale: want, c: clampC(anchor, want), kind: it.kind)
                fresh = withPoint(fresh, it.t, anchor)
                if it.kind == .typing { fresh.path.append(contentsOf: it.path.map { FollowPoint(t: $0.t, p: SIMD2($0.p.x / W, $0.p.y / H)) }) }
                cur = fresh
                prevScale = want
                last = max(last, it.tEnd + (it.kind == .typing ? 0.1 : 0))
                continue
            }
            switch it.kind {
            case .hover:
                // A dwell only steers a scene that hover itself opened. It must
                // never pull the camera off a click or a typing target.
                if o.kind == .hover {
                    o.c = clampC(anchor, o.scale)
                    o = withPoint(o, it.t, anchor)
                }
            case .visual:
                if o.kind == .visual || o.kind == .hover || inside(anchor, o.c, o.scale) {
                    if o.kind != .click && o.kind != .typing { o.c = clampC(anchor, o.scale) }
                    o = withPoint(o, it.t, anchor)
                }
            case .click, .typing:
                if inside(anchor, o.c, o.scale) {
                    o = withPoint(o, it.t, anchor)
                } else {
                    close(at: it.t)
                    var fresh = Open(start: it.t, scale: want, c: clampC(anchor, want), kind: it.kind)
                    fresh = withPoint(fresh, it.t, anchor)
                    if it.kind == .typing { fresh.path.append(contentsOf: it.path.map { FollowPoint(t: $0.t, p: SIMD2($0.p.x / W, $0.p.y / H)) }) }
                    cur = fresh
                    prevScale = want
                    last = max(last, it.tEnd + (it.kind == .typing ? 0.1 : 0))
                    continue
                }
            }
            if it.kind == .typing {
                o.path.append(contentsOf: it.path.map { FollowPoint(t: $0.t, p: SIMD2($0.p.x / W, $0.p.y / H)) })
            }
            o.kind = it.kind
            cur = o
            last = max(last, it.tEnd + (it.kind == .typing ? 0.1 : 0))
        }
        close(at: min(last + hold, tm.trimEnd))

        // ---- 3. cursor paths ----
        // Hover and visual scenes get the pointer motion inside their viewport;
        // a click scene gets drag motion only (the click itself is the target,
        // and a later hover must not steal it); a typing scene keeps the caret
        // path, which is the better signal.
        let drags = sorted.filter { $0.kind == .drag && $0.t.isFinite && $0.x.isFinite && $0.y.isFinite }
        for i in shots.indices {
            let kind = kinds[shots[i].id] ?? .click
            if kind == .typing { continue }
            let s = shots[i]
            let c = centers[s.id] ?? SIMD2(s.focusX * W, s.focusY * H)
            var path = followPaths[s.id] ?? []
            let samples = kind == .click ? drags : sorted.filter { $0.kind == .move && $0.t.isFinite && $0.x.isFinite && $0.y.isFinite }
            var j = 0
            while j < samples.count, samples[j].t < s.start - 0.35 { j += 1 }
            var k = j
            while k < samples.count, samples[k].t <= s.end + 0.35 {
                let p = SIMD2(Double(samples[k].x), Double(samples[k].y))
                if p.x >= 0, p.x <= W, p.y >= 0, p.y <= H, inside(p, c, s.scale) {
                    path.append(FollowPoint(t: samples[k].t, p: SIMD2(p.x / W, p.y / H)))
                }
                k += 1
            }
            guard path.count >= 2 else { continue }
            let cleaned = smoothFollow(path, W: W, H: H)
            guard cleaned.count >= 2, pathExtent(cleaned) > 0.008 else { continue }
            followPaths[s.id] = cleaned
            shots[i].focus = .follow
        }

        let kept = shots.filter { s in
            !avoid.contains { $0.lowerBound < s.end + p.leadIn && $0.upperBound > s.start - p.leadIn } &&
            tm.output(atSource: s.end) - tm.output(atSource: s.start) > 0.02
        }
        // Only the paths of segments that survived the filter travel on.
        let ids = Set(kept.map(\.id))
        return ZoomPlan(segments: kept, follow: followPaths.filter { ids.contains($0.key) })
    }

    /// Purposeful pointer dwell. A user who moves to a control, pauses, reads
    /// and moves on has told us where the attention is. Hover only speaks when
    /// no click or typing burst has recently spoken louder.
    private static func hoverIntents(events: [InputEvent], src: SourceInfo, p: CameraParams,
                                     tm: TimeMap, existing: [Intent]) -> [Intent] {
        guard p.sensitivity > 0.05 else { return [] }
        let W = Double(src.width), H = Double(src.height)
        let moves = events.filter { $0.kind == .move && $0.t.isFinite && $0.x.isFinite && $0.y.isFinite }
        guard moves.count >= 2 else { return [] }
        let loud = existing.filter { $0.kind == .click || $0.kind == .typing }
        let tol = max(8 * src.backingScale, 0.008 * min(W, H))
        let dwell = 0.25 + 0.45 * (1 - clamp(p.sensitivity, 0, 1))
        var out: [Intent] = []
        var lastT = -Double.infinity
        var lastX = -Double.greatestFiniteMagnitude, lastY = lastX
        var i = 0
        while i < moves.count {
            let anchor = SIMD2(Double(moves[i].x), Double(moves[i].y))
            let start = moves[i].t
            var j = i
            var maxDist = 0.0
            while j + 1 < moves.count {
                let next = moves[j + 1]
                if next.t - start > 2.5 { break }
                let d = hypot(Double(next.x) - anchor.x, Double(next.y) - anchor.y)
                maxDist = max(maxDist, d)
                if d > tol { break }
                j += 1
            }
            let end = moves[j].t
            if j > i, end - start >= dwell, maxDist <= tol * 1.5 {
                let mid = Double(j - i + 1)
                var sx = 0.0, sy = 0.0
                for k in i...j { sx += Double(moves[k].x); sy += Double(moves[k].y) }
                let x = sx / mid, y = sy / mid
                let quiet = !loud.contains { abs($0.t - end) <= 1.2 }
                if quiet, end > lastT + 1.2 || hypot(x - lastX, y - lastY) > 40 {
                    if end <= tm.trimEnd - 0.2, !tm.isCut(end) {
                        out.append(Intent(kind: .hover, t: end, tEnd: end, x: x, y: y))
                        lastT = end; lastX = x; lastY = y
                    }
                }
            }
            i = max(j + 1, i + 1)
        }
        return out
    }
}

private extension ZoomSegment {
    var focusX: Double { if case .fixed(let x, _) = focus { return x }; if case .element(let x, _, let w, _) = focus { return x + w / 2 }; return 0.5 }
    var focusY: Double { if case .fixed(_, let y) = focus { return y }; if case .element(_, let y, _, let h) = focus { return y + h / 2 }; return 0.5 }
}