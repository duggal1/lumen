import Foundation
import LumenCore
import LumenProject

enum SpeedRamps {
    static func plan(events: [InputEvent], vad: [ClosedRange<Double>], tm: TimeMap, audio: AudioPlan, backing: Double,
                     activity: [ActivityPoint] = [], busy: [ClosedRange<Double>] = []) -> [SpeedRamp] {
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
        // F2: visibly changing content is never sped through as "idle".
        for span in busy {
            act.append(span.lowerBound); act.append(span.upperBound)
        }
        act.append(tm.trimEnd)
        act = act.filter { $0 >= tm.trimStart && $0 <= tm.trimEnd }.sorted()
        var out: [SpeedRamp] = []
        guard act.count > 1 else { return out }
        for i in 0..<(act.count - 1) {
            let a = act[i], b = act[i + 1]
            guard b - a >= minIdle, !tm.isCut((a + b) / 2) else { continue }
            if vad.contains(where: { $0.upperBound > a && $0.lowerBound < b }) { continue }
            if busy.contains(where: { $0.upperBound > a && $0.lowerBound < b }) { continue }
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
/// The planner is attention-first. Every input (click, typing burst, visual
/// change) is an intent with a position, a rect and a time. The
/// intents are grouped into scenes. Pointer-led scenes carry a follow path so
/// the camera can glide with the pointer; a typing burst is framed whole on
/// its resolved field and deliberately carries no follow path.
enum ZoomPlanner {
    struct PathPoint { var t: Double; var p: SIMD2<Double> }
    typealias FollowPoint = PathPoint
    struct ZoomPlan {
        var segments: [ZoomSegment] = []
        var follow: [UUID: [FollowPoint]] = [:]
        /// Intent kinds by segment id, so the camera solver can tell a typing
        /// shot (stable target) from a follow shot.
        var kinds: [UUID: IntentKind] = [:]
    }
    enum IntentKind { case click, typing, visual, marker, dialog }
    struct Intent {
        var kind: IntentKind
        var t: Double, tEnd: Double            // source seconds
        var x: Double, y: Double               // click pixel, or resolved field centre (source px)
        var rect: CGRect? = nil                // click: verified AX element; typing: the field
        var preferredScale: Double? = nil
        /// Rect to frame as a whole, independent of the scale-only `rect`.
        /// Set for marker beats, for clicks centred on their control, and for
        /// the resolved text field of a typing burst.
        var frameRect: CGRect? = nil
        var visualSubjectID: Int? = nil
        var sustainedVisual = false
        var visualActionTime: Double? = nil
        var visualEnd: Double? = nil
    }
    private struct Open {
        var start: Double, scale: Double, c: SIMD2<Double>
        var path: [FollowPoint] = []
        var kind: IntentKind = .click
        var frameRect: CGRect? = nil
        var visualSubjectID: Int? = nil
        var visualEnd: Double? = nil
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

    /// Typing framing lives in `TypingFocus`. One resolved field, one shot,
    /// starting on the first keystroke — no caret follow, no synthetic anchor.

    /// A marker rect that describes a dialog/panel rather than a control. AX
    /// capture emits these when a sheet, dropdown or modal resolves. Kept in one
    /// place so the marker pass and the dialog pass cannot disagree.
    static func isDialogRect(_ r: CGRect, W: Double, H: Double) -> Bool {
        let rect = CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H)
        let area = (rect.width * rect.height) / (W * H)
        return area >= 0.08 && rect.width >= 0.15 * W && rect.height >= 0.14 * H &&
               rect.width <= 0.95 * W && rect.height <= 0.95 * H
    }

    /// A resolved, newly appearing window/sheet/panel is a subject in its own
    /// right. `usableAX` deliberately rejects frames larger than 28% of the
    /// screen so a browser window cannot pull a click off target — that same
    /// rejection loses the share sheets, New Tab dropdowns and colour panels
    /// that were being cropped at the frame edge. A dialog is a frame that is
    /// resolved, dialog-sized, has its own sample time, is NOT the element a
    /// click/typing targeted, and has no earlier resolved frame at the same
    /// place (it just appeared). Explicit capture markers are authoritative.
    static func dialogIntents(ax: [AXFrame], events: [InputEvent], markers: [DirectorMarker],
                              tm: TimeMap, W: Double, H: Double) -> [Intent] {
        var out: [Intent] = []
        for m in markers {
            guard let r = m.rect, isDialogRect(r, W: W, H: H),
                  m.start.isFinite, m.start >= tm.trimStart, m.start <= tm.trimEnd else { continue }
            let rect = CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H)
            out.append(Intent(kind: .dialog, t: m.start, tEnd: max(m.end, m.start + 0.4),
                              x: rect.midX, y: rect.midY, frameRect: rect))
        }
        // Agent 3 publishes a resolved dialog/new-window frame into the click
        // event's own AX slot, labelled `window|<role>|<subrole>|<title>`.
        // That label is authoritative even though a click references the frame:
        // the click opened the dialog, it did not target a control inside it.
        for (i, f) in ax.enumerated() where f.label?.hasPrefix("window|") == true {
            guard f.x.isFinite, f.y.isFinite, f.w.isFinite, f.h.isFinite,
                  f.w > 1, f.h > 1 else { continue }
            let rect = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
            let area = (rect.width * rect.height) / (W * H)
            guard area >= 0.02, rect.width >= 0.08 * W, rect.height >= 0.08 * H,
                  rect.width <= 0.95 * W, rect.height <= 0.95 * H else { continue }
            let rt = events.first(where: { $0.axFrameIndex == UInt32(i + 1) })?.t ?? f.sampledAt ?? -1
            guard rt.isFinite, rt >= tm.trimStart, rt <= tm.trimEnd else { continue }
            if out.contains(where: { di in
                abs(di.t - rt) < 0.35 && di.frameRect.map { dr in
                    abs(dr.midX - rect.midX) < 0.04 * W && abs(dr.midY - rect.midY) < 0.04 * H
                } ?? false
            }) { continue }
            out.append(Intent(kind: .dialog, t: rt, tEnd: rt + 0.6,
                              x: rect.midX, y: rect.midY, frameRect: rect))
        }
        // The elements a click or a keystroke actually targeted are controls or
        // fields, never a newly opened dialog — even when they are large.
        let targeted = Set(events.filter { $0.kind == .down || $0.kind == .keyDown }.map(\.axFrameIndex))
        for (i, f) in ax.enumerated() where f.label?.hasPrefix("window|") != true {
            guard f.anchor?.resolved == true else { continue }
            guard f.x.isFinite, f.y.isFinite, f.w.isFinite, f.h.isFinite,
                  f.w > 1, f.h > 1 else { continue }
            let rect = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
            let area = (rect.width * rect.height) / (W * H)
            guard area >= 0.08, rect.width >= 0.15 * W, rect.height >= 0.14 * H,
                  rect.width <= 0.85 * W, rect.height <= 0.85 * H else { continue }
            guard !targeted.contains(UInt32(i + 1)) else { continue }
            guard let st = f.sampledAt, st.isFinite, st >= tm.trimStart, st <= tm.trimEnd else { continue }
            let appearedBefore = ax.enumerated().contains { (j, g) in
                guard j != i, g.anchor?.resolved == true, let gt = g.sampledAt,
                      gt.isFinite, gt < st - 0.05 else { return false }
                let gr = CGRect(x: g.x, y: g.y, width: g.w, height: g.h)
                return abs(gr.midX - rect.midX) < 0.04 * W &&
                       abs(gr.midY - rect.midY) < 0.04 * H &&
                       abs(gr.width - rect.width) < 0.15 * rect.width &&
                       abs(gr.height - rect.height) < 0.15 * rect.height
            }
            if appearedBefore { continue }
            // A marker may already have described this exact panel.
            if out.contains(where: { di in
                abs(di.t - st) < 0.35 && di.frameRect.map { dr in
                    abs(dr.midX - rect.midX) < 0.04 * W && abs(dr.midY - rect.midY) < 0.04 * H
                } ?? false
            }) { continue }
            out.append(Intent(kind: .dialog, t: st, tEnd: st + 0.6,
                              x: rect.midX, y: rect.midY, frameRect: rect))
        }
        return out.sorted { $0.t < $1.t }
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
                     markers: [DirectorMarker] = [], activityShots: [VisualShot] = []) -> ZoomPlan {
        let W = Double(src.width), H = Double(src.height), b = max(src.backingScale, 1)
        guard W > 0, H > 0 else { return ZoomPlan() }
        if p.preset == .fixed {
            // maxScale is a hard cap even for the fixed camera: the Zoom-amount
            // slider can exceed Max-zoom, but the exported magnification must
            // never go past what the user capped it at.
            let fixedScale = clamp(p.baseScale, 1.0, clamp(p.maxScale, 1.001, 6.0))
            let segment = ZoomSegment(id: stableID(tm.trimStart, tm.trimEnd), start: tm.trimStart, end: tm.trimEnd,
                                      scale: fixedScale, focus: .follow, origin: .auto)
            return ZoomPlan(segments: [segment])
        }
        let sorted = events.filter { $0.t.isFinite && $0.t >= tm.trimStart && $0.t < tm.trimEnd }
            .sorted { $0.t < $1.t }
        func ok(_ t: Double) -> Bool { t.isFinite && t >= tm.trimStart && t < tm.trimEnd && !tm.isCut(t) }
        // `maxScale` is a hard cap, not a suggestion: the Inspector's "Max zoom"
        // slider goes down to 1.2×, and quietly clamping the cap up to 1.3×
        // pushed the camera past what the user asked for.
        let hi = clamp(p.maxScale, 1.001, 6.0)
        let lo = clamp(min(p.minScale, hi), 1.001, hi)
        let hold = max(p.hold.isFinite ? p.hold : 0.9, 0.3)
        let gap = max(p.zoomOutGap.isFinite ? p.zoomOutGap : 2.6, hold + 0.5)
        // A camera shot follows one action. Every in-shot intent used to push
        // `last` out, so a dense burst produced one 8-10 s shot. A hard ceiling
        // keeps the return tied to the action instead of to the next click.
        var maxShot = min(2.5, max(1.2, 5 * hold))

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
                let r = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
                if usableAX(f, x: x, y: y, width: W, height: H, backing: b) {
                    rect = r
                } else {
                    // usableAX rejects frames over 28% of the screen so a
                    // browser window cannot pull a click off target. That is a
                    // focus rule, not a reason to throw away honest evidence
                    // about how large the clicked surface was. Use it for
                    // scale only; the camera centre stays on the exact click.
                    let slack = 8 * b
                    if f.x.isFinite, f.y.isFinite, f.w.isFinite, f.h.isFinite,
                       f.w >= 8 * b, f.h >= 8 * b, f.w <= 0.95 * W, f.h <= 0.95 * H,
                       x >= f.x - slack, x <= f.x + f.w + slack,
                       y >= f.y - slack, y <= f.y + f.h + slack {
                        rect = r
                    }
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
        // One resolved field = one shot, beginning on the first keystroke.
        // Built entirely in TypingFocus; no caret follow and no last-click
        // invention (that synthesis is what produced the 2.0x block cascade).
        intents += TypingFocus.intents(events: sorted, ax: ax, traces: typing,
                                       W: W, H: H, b: b, timeMap: tm)
        // Marker beats are explicit intent. An agent step carries the rect of
        // the thing it was about; a plain marker inherits the nearest recent
        // click as its location. Never invent a location from nothing.
        for m in markers where ok(m.start) {
            // Panel-sized markers are dialogs, handled as their own subject.
            if let r = m.rect, isDialogRect(r, W: W, H: H) { continue }
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
        intents += dialogIntents(ax: ax, events: sorted, markers: markers, tm: tm, W: W, H: H)
        // Passive visual intents are lowest priority: the scene loop never lets
        // a `.visual` intent displace a click/typing/dialog subject.
        // F2: activity grids replace the old detector; click/typing still outrank
        // these `.visual` shots. Do NOT also call VisualZoom.intents here.
        let visual = VisualAutofocus.intents(shots: activityShots, input: intents, src: src, tm: tm)
        // Only a corroborated result can replace its own initiating click.
        // Never remove manual/marker/dialog/typing intent or an unrelated click.
        let replacedClicks = Set(visual.compactMap(\.visualActionTime))
        intents.removeAll { $0.kind == .click && replacedClicks.contains($0.t) }
        intents += visual
        intents = intents.filter { ok($0.t) && $0.tEnd.isFinite && $0.x.isFinite && $0.y.isFinite }
        intents.sort { a, b in
            if a.t != b.t { return a.t < b.t }
            // Deterministic tie order: the subject that opened a dialog is not
            // a competing click at the same instant.
            func rank(_ k: IntentKind) -> Int {
                switch k {
                case .dialog: return 0
                case .typing: return 1
                case .click, .marker: return 2
                case .visual: return 3
                }
            }
            return rank(a.kind) < rank(b.kind)
        }

        // A run of rapid intents is one burst and must not weld into an 8 s
        // shot. Sparse beats are the action itself and may hold longer. The
        // cadence of explicit subjects decides which regime we are in.
        let strongTimes = intents.filter {
            $0.kind == .click || $0.kind == .typing || $0.kind == .marker || $0.kind == .dialog
        }.map(\.t).sorted()
        if strongTimes.count > 1 {
            var minGap = Double.infinity
            for k in 1..<strongTimes.count { minGap = min(minGap, strongTimes[k] - strongTimes[k - 1]) }
            if minGap >= 0.7 { maxShot = 6.5 }
        }

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
        var shotCap = maxShot                     // effective ceiling for the open shot
        var last = 0.0
        var prevScale: Double?

        func close(at end: Double) {
            guard let o = cur else { return }
            cur = nil
            let e = min(end, o.start + shotCap, tm.trimEnd, o.visualEnd ?? .infinity)
            guard e - o.start > 0.02, o.scale > 1.001 else { return }
            let id = stableID(o.start, e)
            var path = o.path.filter { $0.t >= o.start - 1e-6 && $0.t <= e + 1e-6 }
            if path.isEmpty || path[0].t > o.start + 0.05 {
                path.insert(FollowPoint(t: o.start, p: SIMD2(o.c.x / W, o.c.y / H)), at: 0)
            }
            let focus: Focus
            let maxFrac = o.kind == .dialog || o.kind == .typing ? 0.95 : 0.6
            if let r = o.frameRect, r.width >= 8, r.height >= 6,
               r.width <= W * maxFrac, r.height <= H * maxFrac {
                // A marked control, resolved field or whole dialog is the
                // subject itself; framing its full rect keeps it unclipped.
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

        /// Fit the subject with breathing room, then lower the ceiling for
        /// subjects that already fill much of the screen. Only a genuinely
        /// small control reaches the user's maxScale; a panel or dialog gets a
        /// gentle move that leaves the whole thing inside the frame.
        func adaptiveScale(_ r: CGRect, marginW: Double = 2.0, marginH: Double = 2.0) -> Double {
            let rw = max(r.width, 1), rh = max(r.height, 1)
            let fit = min(W / (rw * marginW), H / (rh * marginH))
            let span = clamp(max(rw / W, rh / H), 0, 1)
            let ceiling = clamp(hi * (1 - 0.45 * span), lo, hi)
            return clamp(min(fit, ceiling), lo, hi)
        }

        func chooseScale(_ i: Intent, prev: Double?) -> Double {
            var s: Double
            switch i.kind {
            case .visual:
                guard let scale = i.preferredScale, scale.isFinite else { return 1 }
                return min(scale, hi)
            case .dialog:
                guard let r = i.frameRect ?? i.rect, r.width > 1, r.height > 1 else { return 1 }
                // Frame the entire dialog, not a slice of it. The margin is
                // tighter than a control's so a sheet still reads as close.
                s = adaptiveScale(r, marginW: 1.18, marginH: 1.18)
            case .click, .typing, .marker:
                if let r = i.frameRect ?? i.rect, r.width > 1, r.height > 1 {
                    // The whole field is the subject of a typing shot; the
                    // camera does not move during it, so every caret position
                    // inside the field must stay in the viewport.
                    let typing = i.kind == .typing
                    // One margin, applied once. Typing frames the resolved
                    // field at the activity padFraction convention; the old
                    // 2.4/2.8 branch re-margined a rect that was already the
                    // subject and rejected common typing targets.
                    s = adaptiveScale(r, marginW: typing ? 1.35 : 2.0,
                                      marginH: typing ? 1.35 : 2.0)
                } else {
                    // No resolved rect: keep the configured feel, but do not
                    // blindly hit the cap when a preset's base asks for more.
                    s = clamp(min(p.baseScale, hi * 0.92), lo, hi)
                }
                if i.frameRect == nil, i.kind == .click || i.kind == .marker {
                    // The exact click is the subject. A gentler zoom near an
                    // edge must not be feasibility-clamped away from it.
                    let needX = W / max(2 * min(i.x, W - i.x), 1)
                    let needY = H / max(2 * min(i.y, H - i.y), 1)
                    s = min(hi, max(s, needX, needY))
                }
            }
            guard s > 1.001 else { return 1 }
            // Only merge genuinely identical subjects. Snapping to the previous
            // scale across different sizes is what made every shot read "2.0x".
            if let prev, prev > 1.001, abs(log(s / prev)) < log(1.03) { return clamp(prev, lo, hi) }
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
        func beginScene(_ it: Intent, _ want: Double, _ anchor: SIMD2<Double>, force: Bool = false) {
            let tail = it.kind == .typing ? 0.1 : 0.0
            // One resolved field is one shot. It must cover every keystroke of
            // the interaction, so the burst duration is the floor, not a value
            // to be clipped down to the cadence cap of a rapid click run.
            let cap = it.kind == .typing
                ? max(6.5, it.tEnd - it.t + 0.6)
                : (it.sustainedVisual ? max(maxShot, it.tEnd - it.t + hold) : maxShot)
            if var o = cur {
                if force {
                    // A dialog or a resolved typing field is a different
                    // subject. It wins over the shot that was open.
                    if it.t >= o.start + 0.2 {
                        // Close where the previous action actually ended, not
                        // at the new subject: the camera returns before it
                        // re-aims instead of holding a stale target.
                        close(at: min(last + hold, it.t, o.start + shotCap))
                    } else {
                        cur = nil                       // too short to keep
                    }
                } else {
                    let cut = min(last + hold, o.start + shotCap, tm.trimEnd, it.t)
                    if cut >= o.start + 0.2 {
                        close(at: cut)
                    } else {
                        o.scale = want
                        o.c = clampC(anchor, want)
                        if let r = it.frameRect { o.frameRect = r }
                        o = withPoint(o, it.t, anchor)
                        o.kind = it.kind
                        cur = o
                        shotCap = max(shotCap, cap)
                        prevScale = want
                        last = min(max(it.t, it.tEnd + tail), o.start + shotCap - 0.15)
                        return
                    }
                }
            }
            var fresh = Open(start: it.t, scale: want, c: clampC(anchor, want), kind: it.kind, frameRect: it.frameRect,
                             visualSubjectID: it.visualSubjectID, visualEnd: it.visualEnd)
            fresh = withPoint(fresh, it.t, anchor)
            cur = fresh
            shotCap = cap
            prevScale = want
            last = min(max(it.t, it.tEnd + tail), fresh.start + cap - 0.15)
        }

        for it in intents {
            if let o = cur, let end = o.visualEnd, it.t >= end {
                close(at: end)
            }
            if let o = cur {
                if it.kind == .visual, o.kind != .visual {
                    if it.t <= last + hold { continue }
                    close(at: last + hold)
                }
                if o.kind == .typing, it.kind == .click, it.t <= last,
                   o.frameRect?.contains(CGPoint(x: it.x, y: it.y)) == true { continue }
                if o.kind == .visual, it.kind != .visual { close(at: it.t) }
                if o.kind == .visual, it.kind == .visual,
                   let old = o.visualSubjectID, let new = it.visualSubjectID, old != new {
                    close(at: min(it.t, last + hold))
                }
            }
            // A shot never outlives its action window, even under a dense run
            // of clicks that would otherwise keep pushing `last` forward.
            if let o = cur, it.t >= o.start + shotCap - 0.05 {
                // End no later than the next subject's start: one camera, one
                // target, no two shots claiming the same instant.
                close(at: min(o.start + shotCap, it.t, tm.trimEnd))
            }
            let want = chooseScale(it, prev: prevScale)
            let anchor = SIMD2(it.x, it.y)
            let strong = it.kind == .click || it.kind == .typing || it.kind == .marker || it.kind == .dialog
            // A resolved typing field or a newly opened dialog is a different
            // subject: re-aim now, rather than folding it into the open shot.
            // Only a *resolved* field is a new subject. The synthetic typing
            // fallback (no field) anchors to the last click and stays one shot.
            let reaim = it.kind == .typing || it.kind == .dialog
            if want <= 1.001 {
                if cur != nil { last = max(last, it.tEnd) }
                continue
            }
            if reaim {
                if it.kind == .typing, let o = cur, o.kind == .click, it.t <= last + hold,
                   let point = o.path.last?.p, let rect = it.frameRect,
                   rect.insetBy(dx: -8 * b, dy: -8 * b).contains(CGPoint(x: point.x * W, y: point.y * H)) {
                    var joined = it
                    joined.t = o.start
                    cur = nil
                    beginScene(joined, want, anchor)
                    continue
                }
                beginScene(it, want, anchor, force: true)
                continue
            }
            // The click that opened a dialog shares its AX slot and often its
            // instant. It is not a second subject; keep the dialog framed.
            if let o = cur, o.kind == .dialog, it.kind != .dialog, it.t <= o.start + 0.8 {
                last = max(last, it.tEnd)
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
            case .visual:
                // Passive visual autofocus may steer an open visual scene, but
                // never displaces an explicit click/typing/dialog subject.
                if o.kind == .visual || inside(anchor, o.c, o.scale) {
                    var n = o
                    if o.kind != .click && o.kind != .typing && o.kind != .dialog { n.c = clampC(anchor, o.scale) }
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
            case .dialog:
                beginScene(it, want, anchor, force: true)
                continue
            }
            let locked = o.kind == .typing || o.kind == .dialog
            if let o2 = cur, it.frameRect != nil, !locked { var n = o2; n.frameRect = it.frameRect; cur = n }
            if let o2 = cur, !locked { var n = o2; n.kind = it.kind; cur = n }
            last = min(max(last, it.tEnd + (it.kind == .typing ? 0.1 : 0)), o.start + shotCap - 0.15)
        }
        if let o = cur {
            close(at: min(last + hold, o.start + shotCap, tm.trimEnd))
        }

        // ---- 3. cursor paths ----
        let drags = sorted.filter { $0.kind == .drag && $0.x.isFinite && $0.y.isFinite && !tm.isCut($0.t) }
        var dragStart = 0
        for i in shots.indices {
            let kind = kinds[shots[i].id] ?? .click
            let s = shots[i]
            if kind == .visual {
                if let path = followPaths[s.id] { followPaths[s.id] = smoothFollow(path) }
                continue
            }
            guard kind == .click else { continue }
            let c = centers[s.id] ?? SIMD2(s.focusX * W, s.focusY * H)
            var path = followPaths[s.id] ?? []
            while dragStart < drags.count, drags[dragStart].t < s.start { dragStart += 1 }
            var k = dragStart
            while k < drags.count, drags[k].t <= s.end {
                let p = SIMD2(Double(drags[k].x), Double(drags[k].y))
                if p.x >= 0, p.x <= W, p.y >= 0, p.y <= H, inside(p, c, s.scale) {
                    if path.isEmpty {
                        path.append(FollowPoint(t: s.start, p: SIMD2(c.x / W, c.y / H)))
                    }
                    path.append(FollowPoint(t: drags[k].t, p: SIMD2(p.x / W, p.y / H)))
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
        return ZoomPlan(segments: kept, follow: followPaths.filter { ids.contains($0.key) },
                        kinds: kinds.filter { ids.contains($0.key) })
    }

}

private extension ZoomSegment {
    var focusX: Double { if case .fixed(let x, _) = focus { return x }; if case .element(let x, _, let w, _) = focus { return x + w / 2 }; return 0.5 }
    var focusY: Double { if case .fixed(_, let y) = focus { return y }; if case .element(_, let y, _, let h) = focus { return y + h / 2 }; return 0.5 }
}
