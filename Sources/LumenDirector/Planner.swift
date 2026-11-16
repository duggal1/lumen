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
/// intents are grouped into scenes. Pointer-led scenes carry a follow path so
/// the camera can glide with the pointer; a typing burst is framed whole on
/// its resolved field and deliberately carries no follow path.
enum ZoomPlanner {
    struct PathPoint { var t: Double; var p: SIMD2<Double> }
    typealias FollowPoint = PathPoint
    struct ZoomPlan {
        var segments: [ZoomSegment] = []
        var follow: [UUID: [FollowPoint]] = [:]
    }
    enum IntentKind { case click, typing, hover, visual, marker }
    struct Intent {
        var kind: IntentKind
        var t: Double, tEnd: Double            // source seconds
        var x: Double, y: Double               // click pixel, or resolved field centre (source px)
        var rect: CGRect? = nil                // click: verified AX element; typing: the field
        /// Rect to frame as a whole, independent of the scale-only `rect`.
        /// Set for marker beats, for clicks centred on their control, and for
        /// the resolved text field of a typing burst.
        var frameRect: CGRect? = nil
    }
    private struct Open {
        var start: Double, scale: Double, c: SIMD2<Double>
        var path: [FollowPoint] = []
        var kind: IntentKind = .click
        var frameRect: CGRect? = nil
    }

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

    /// Resolve one steady subject for a typing burst: the smallest
    /// accessibility field that actually contains the caret. Per-keystroke
    /// caret positions are deliberately NOT kept as a camera target. A caret
    /// holds then jumps on every key (and jumps further on a line wrap); feeding
    /// that staircase into the camera's dead-zone + zero-phase follow made the
    /// shot wander left/right and up/down and keep ringing after the last key.
    /// The field is the thing being typed into — frame that instead.
    private static func resolvedField(t0: Double, t1: Double, keys: [InputEvent], ax: [AXFrame],
                                      traces: [TypingTrace], W: Double, H: Double, b: Double) -> CGRect? {
        let slack = 24 * b
        var carets: [CGPoint] = []
        var fields: [CGRect] = []
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
                    carets.append(CGPoint(x: px, y: py))
                }
            }
        }
        if let first = carets.first {
            // The smallest field that contains the caret, not the largest
            // container seen during the burst.
            return fields
                .filter { $0.insetBy(dx: -slack, dy: -slack).contains(first) }
                .min { $0.width * $0.height < $1.width * $1.height }
        }
        // No AX caret: fall back to the pixel tracer's resolved text line.
        if let tr = traces.first(where: { $0.t0 <= t1 + 0.15 && $0.t1 >= t0 - 0.15 }) {
            let samples = tr.samples.filter { $0.confidence >= 0.4 && $0.t.isFinite && $0.x.isFinite && $0.y.isFinite }
            if samples.count >= 2 { return tr.line ?? tr.rect }
        }
        return nil
    }

    /// Pointer paths are continuous: a cursor crossing the screen is one
    /// glide, not a hold followed by a jump. Catmull-Rom keeps velocity
    /// through every recorded point, so the camera does not stop at each
    /// click on its way to the next one. Typing no longer carries a follow
    /// path — its field is framed whole, as a steady target.
    private static func smoothFollow(_ pts: [FollowPoint]) -> [FollowPoint] {
        guard pts.count >= 2 else { return pts }
        let sorted = pts.sorted { $0.t < $1.t }
        let t0 = sorted.first!.t, t1 = sorted.last!.t
        let dt = 1.0 / 60
        let n = max(Int((t1 - t0) / dt) + 1, 2)
        func catmull(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ u: Double) -> Double {
            let u2 = u * u, u3 = u2 * u
            return 0.5 * ((2 * p1) + (-p0 + p2) * u + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2 + (-p0 + 3 * p1 - 3 * p2 + p3) * u3)
        }
        var xs: [Double] = [], ys: [Double] = []
        xs.reserveCapacity(n); ys.reserveCapacity(n)
        var j = 0
        for i in 0..<n {
            let t = t0 + Double(i) * dt
            while j + 1 < sorted.count, sorted[j + 1].t <= t { j += 1 }
            let a = sorted[j]
            if j + 1 < sorted.count, t > a.t {
                let b = sorted[j + 1]
                let p0 = sorted[max(j - 1, 0)].p, p1 = a.p, p2 = b.p, p3 = sorted[min(j + 2, sorted.count - 1)].p
                let u = clamp((t - a.t) / max(b.t - a.t, 1e-6), 0, 1)
                xs.append(catmull(p0.x, p1.x, p2.x, p3.x, u))
                ys.append(catmull(p0.y, p1.y, p2.y, p3.y, u))
            } else {
                xs.append(a.p.x); ys.append(a.p.y)
            }
        }
        xs = zeroPhaseSmooth(xs, omega: 7, dt: dt)
        ys = zeroPhaseSmooth(ys, omega: 7, dt: dt)
        return (0..<n).map { FollowPoint(t: t0 + Double($0) * dt, p: SIMD2(xs[$0], ys[$0])) }
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
                             src: SourceInfo, p: CameraParams, tm: TimeMap, avoid: [ClosedRange<Double>],
                             markers: [DirectorMarker] = []) -> [ZoomSegment] {
        plan(events: events, ax: ax, typing: typing, activity: activity, src: src, p: p, tm: tm,
             avoid: avoid, markers: markers).segments
    }

    static func plan(events: [InputEvent], ax: [AXFrame], typing: [TypingTrace], activity: [ActivityPoint],
                     src: SourceInfo, p: CameraParams, tm: TimeMap, avoid: [ClosedRange<Double>],
                     markers: [DirectorMarker] = []) -> ZoomPlan {
        let W = Double(src.width), H = Double(src.height), b = max(src.backingScale, 1)
        guard W > 0, H > 0 else { return ZoomPlan() }
        if p.preset == .fixed {
            let segment = ZoomSegment(id: stableID(tm.trimStart, tm.trimEnd), start: tm.trimStart, end: tm.trimEnd,
                                      scale: p.baseScale, focus: .follow, origin: .auto)
            return ZoomPlan(segments: [segment])
        }
        let sorted = events.sorted { $0.t < $1.t }
        func ok(_ t: Double) -> Bool { t.isFinite && t >= tm.trimStart + 0.2 && t <= tm.trimEnd - 0.2 && !tm.isCut(t) }
        // `maxScale` is a hard cap, not a suggestion: the Inspector's "Max zoom"
        // slider goes down to 1.2×, and quietly clamping the cap up to 1.3×
        // pushed the camera past what the user asked for.
        let hi = clamp(p.maxScale, 1.001, 6.0)
        let lo = clamp(min(p.minScale, hi), 1.001, hi)
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
            // Frame the whole control only when the click is close to its
            // centre. A click far off-centre keeps its exact pixel target —
            // the recorded click is the more precise evidence there.
            var frameRect: CGRect?
            if let r = rect {
                let centre = SIMD2(Double(r.midX), Double(r.midY))
                let halfRect = SIMD2(Double(r.width), Double(r.height)) / 2
                if halfRect.x > 0, halfRect.y > 0,
                   abs(x - centre.x) <= halfRect.x * 0.25,
                   abs(y - centre.y) <= halfRect.y * 0.25,
                   r.width <= W * 0.6, r.height <= H * 0.6 {
                    frameRect = r
                }
            }
            let i = Intent(kind: .click, t: e.t, tEnd: e.t, x: x, y: y, rect: rect, frameRect: frameRect)
            intents.append(i); lastClick = i
        }
        let keys = sorted.filter { $0.kind == .keyDown }
        for burst in sorted.typingBursts() where ok(burst.t0) {
            if let field = resolvedField(t0: burst.t0, t1: burst.t1, keys: keys, ax: ax,
                                         traces: typing, W: W, H: H, b: b) {
                // One steady shot on the field. There is no caret follow path:
                // the field is the subject, so the centre does not chase every
                // keystroke (or jump on a line wrap).
                intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1,
                                      x: field.midX, y: field.midY, rect: field, frameRect: field))
            } else if let lc = lastClick, burst.t0 - lc.t <= 30 {
                // No resolved field: keep the last-click anchor rather than
                // inventing a centre from nothing.
                let synth = CGRect(x: lc.x - W * 0.175, y: lc.y - H * 0.05, width: W * 0.35, height: H * 0.10)
                intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1, x: lc.x, y: lc.y, rect: synth))
            }
        }
        // Marker beats are explicit intent. An agent step carries the rect of
        // the thing it was about; a plain marker inherits the nearest recent
        // click as its location. Never invent a location from nothing.
        for m in markers where ok(m.start) {
            var x = 0.0, y = 0.0, frame: CGRect?
            if let r = m.rect, r.width >= 0.005, r.height >= 0.005 {
                x = r.midX * W; y = r.midY * H
                frame = CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H)
            } else if let e = sorted.last(where: { ev in
                ev.t <= m.start && m.start - ev.t <= 1.2 &&
                    (ev.kind == .down || ev.kind == .keyDown)
            }) {
                x = Double(e.x); y = Double(e.y)
            } else { continue }
            intents.append(Intent(kind: .marker, t: m.start,
                                  tEnd: max(m.end, m.start + 0.4),
                                  x: x, y: y, frameRect: frame))
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
            if let r = o.frameRect, r.width >= 8, r.height >= 6, r.width <= W * 0.6, r.height <= H * 0.6 {
                // A marked or well-centred control is the subject itself;
                // framing its whole rect keeps the action readable.
                focus = .element(x: r.minX / W, y: r.minY / H, w: r.width / W, h: r.height / H)
            } else if path.count >= 2, pathExtent(path) > 0.008 {
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
            case .click, .typing, .marker:
                if i.kind == .typing, let r = i.frameRect {
                    // The whole field is the subject and the camera does not
                    // move during the burst. Fit it, with breathing room, so
                    // every caret position inside it stays in the viewport.
                    let fit = min(W / max(r.width * 1.2, 1), H / max(r.height * 1.6, 1))
                    s = clamp(min(fit, hi), lo, hi)
                } else {
                    s = clamp(p.baseScale, 1.0, hi)
                    if let r = i.rect {
                        // A small control earns a closer look; a large surface
                        // only a gentle one. The base scale is the control.
                        let coverage = (r.width * r.height) / (W * H)
                        let factor = clamp(pow(0.06 / max(coverage, 1e-4), 0.18), 0.85, 1.45)
                        s = clamp(p.baseScale * factor, lo, hi)
                    }
                    if let r = i.frameRect {
                        // Fit the marked rect with breathing room, but never
                        // pull back from the user's chosen zoom amount.
                        let fit = min(W / max(r.width * 1.25, 1), H / max(r.height * 1.25, 1))
                        s = clamp(max(s, min(fit, hi)), lo, hi)
                    }
                }
            }
            guard s > 1.001 else { return 1 }
            if let prev, prev > 1.001, abs(log(s / prev)) < log(1.12) { return clamp(prev, lo, hi) }
            return s
        }

        /// Start a new scene for `it`, or continue the open one.
        ///
        /// A camera has exactly one target at a time, so two segments may never
        /// overlap: the solver holds them in an ordered pass, and an overlap
        /// makes a later write stomp an earlier one mid-curve — the track then
        /// jumps a third of the screen in one tick. When the new subject is too
        /// close to the open shot's minimum length, it is not a separate shot at
        /// all; the camera pans inside the current one.
        func beginScene(_ it: Intent, _ want: Double, _ anchor: SIMD2<Double>) {
            if var o = cur {
                let cut = min(last + hold, tm.trimEnd, it.t)
                if cut >= o.start + 0.2 {
                    close(at: cut)
                } else {
                    o.scale = want
                    o.c = clampC(anchor, want)
                    if let r = it.frameRect { o.frameRect = r }
                    o = withPoint(o, it.t, anchor)
                    o.kind = it.kind
                    cur = o
                    prevScale = want
                    last = max(last, it.tEnd + (it.kind == .typing ? 0.1 : 0))
                    return
                }
            }
            var fresh = Open(start: it.t, scale: want, c: clampC(anchor, want), kind: it.kind, frameRect: it.frameRect)
            fresh = withPoint(fresh, it.t, anchor)
            cur = fresh
            prevScale = want
            last = max(last, it.tEnd + (it.kind == .typing ? 0.1 : 0))
        }

        for it in intents {
            let want = chooseScale(it, prev: prevScale)
            let anchor = SIMD2(it.x, it.y)
            let strong = it.kind == .click || it.kind == .typing || it.kind == .marker
            if want <= 1.001 {
                if cur != nil { last = max(last, it.tEnd) }
                continue
            }
            if cur == nil { beginScene(it, want, anchor); continue }
            guard let o = cur else { continue }
            let gapOK = it.t - last <= gap
            // Distance from where the camera is looking *now*, not from where
            // the shot opened. A run of clicks walking across a toolbar stays
            // one shot; a jump to the other side of the screen opens a new one.
            let ref = o.path.last.map { SIMD2($0.p.x * W, $0.p.y * H) } ?? o.c
            let moved = hypot(anchor.x - ref.x, anchor.y - ref.y) / max(half(want).x, 1)
            if strong, !gapOK || moved > 0.55 {
                beginScene(it, want, anchor)
                continue
            }
            switch it.kind {
            case .hover:
                // A dwell only steers a scene that hover itself opened. It must
                // never pull the camera off a click or a typing target.
                if o.kind == .hover {
                    var n = o
                    n.c = clampC(anchor, o.scale)
                    n = withPoint(n, it.t, anchor)
                    cur = n
                }
            case .visual:
                if o.kind == .visual || o.kind == .hover || inside(anchor, o.c, o.scale) {
                    var n = o
                    if o.kind != .click && o.kind != .typing { n.c = clampC(anchor, o.scale) }
                    n = withPoint(n, it.t, anchor)
                    cur = n
                }
            case .click, .typing, .marker:
                if inside(anchor, o.c, o.scale) {
                    var n = o
                    n = withPoint(n, it.t, anchor)
                    cur = n
                } else {
                    beginScene(it, want, anchor)
                    continue
                }
            }
            if let o2 = cur, it.frameRect != nil { var n = o2; n.frameRect = it.frameRect; cur = n }
            if let o2 = cur { var n = o2; n.kind = it.kind; cur = n }
            last = max(last, it.tEnd + (it.kind == .typing ? 0.1 : 0))
        }
        close(at: min(last + hold, tm.trimEnd))

        // ---- 3. cursor paths ----
        // Hover and visual scenes get the pointer motion inside their viewport;
        // a click scene gets drag motion only (the click itself is the target,
        // and a later hover must not steal it). Typing and marker scenes keep
        // their steady subject — a field rect or a marker rect — and cursor
        // motion must never replace it.
        let drags = sorted.filter { $0.kind == .drag && $0.t.isFinite && $0.x.isFinite && $0.y.isFinite }
        for i in shots.indices {
            let kind = kinds[shots[i].id] ?? .click
            if kind == .typing || kind == .marker { continue }
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
            let cleaned = smoothFollow(path)
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