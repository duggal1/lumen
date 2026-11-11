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

/// Auto-zoom decision layer v4. ONLY a left click or a typing burst can
/// start a zoom. Hover, scroll and drag never start or move one: scroll
/// and drag inside the current view only keep the scene alive.
///
/// A scene stays zoomed while activity continues. The camera moves ONLY
/// when the next target leaves the safe zone of the current view. Scale is
/// chosen once per scene with hysteresis. A scene ends `hold` seconds
/// after its last activity; a new scene starts if the gap exceeds
/// `zoomOutGap`.
enum ZoomPlanner {
    struct Intent {
        enum Kind { case click, typing }
        var kind: Kind
        var t: Double, tEnd: Double            // source seconds; tEnd = last key for typing
        var x: Double, y: Double               // focus, source px
        var rect: CGRect? = nil                // verified AX element (click) or typed-text line (typing), source px
        var caret: [TypingTrace.Sample] = []   // typing only
    }
    /// An open scene. `c` is the clamped centre used by the framing maths;
    /// `focus` is what the shot records. For a click the focus is the EXACT
    /// clicked pixel (the camera clamps it into the viewport at render time,
    /// so the shot never drifts off the thing the user hit). For typing the
    /// focus is the clamped, right-biased typing centre.
    private struct Open {
        var start: Double, scale: Double
        var c: SIMD2<Double>
        var focus: Focus
        var anchor: SIMD2<Double>
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
    /// parent container can pull the camera hundreds of pixels off target, so
    /// only a frame that plausibly IS the clicked thing is used: a container
    /// covering more than ~28 % of the screen is a parent, not the target.
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

    static func plan(events: [InputEvent], ax: [AXFrame], typing: [TypingTrace], activity: [ActivityPoint],
                     src: SourceInfo, p: CameraParams, tm: TimeMap, avoid: [ClosedRange<Double>]) -> [ZoomSegment] {
        let W = Double(src.width), H = Double(src.height), b = max(src.backingScale, 1)
        guard W > 0, H > 0 else { return [] }
        // The scene ends `hold` seconds after the last activity; the camera
        // then lingers on the target for `tail` before it eases back out.
        let hold = min(p.hold, max(p.zoomOutGap - 0.2, 0.3))
        if p.preset == .fixed {
            return [ZoomSegment(id: stableID(tm.trimStart, tm.trimEnd), start: tm.trimStart, end: tm.trimEnd,
                                scale: p.baseScale, focus: .follow, origin: .auto)]
        }
        let sorted = events.sorted { $0.t < $1.t }
        func ok(_ t: Double) -> Bool { t.isFinite && t >= tm.trimStart + 0.3 && t <= tm.trimEnd - 0.8 && !tm.isCut(t) }

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
        for burst in sorted.typingBursts() where ok(burst.t0) {
            let focused = sorted.filter { $0.kind == .keyDown && $0.t >= burst.t0 && $0.t <= burst.t1 }
                .compactMap { event -> Intent? in
                    guard event.axFrameIndex > 0, Int(event.axFrameIndex) <= ax.count else { return nil }
                    let field = ax[Int(event.axFrameIndex) - 1]
                    guard field.w > 0, field.h > 0, field.x.isFinite, field.y.isFinite else { return nil }
                    let rect = CGRect(x: field.x, y: field.y, width: field.w, height: field.h)
                    let caret = field.caret
                    guard caret != nil || (field.w <= W * 0.7 && field.h <= H * 0.28) else { return nil }
                    let x = caret.map { $0.x + $0.w / 2 } ?? rect.midX
                    let y = caret.map { $0.y + $0.h / 2 } ?? rect.midY
                    guard x >= 0, x <= W, y >= 0, y <= H else { return nil }
                    return Intent(kind: .typing, t: event.t, tEnd: event.t, x: x, y: y, rect: rect)
                }
            if !focused.isEmpty {
                // ONE intent per typing burst. A per-keystroke intent made the
                // scale change with the growing text and split a single
                // sentence into several zoom shots.
                let field = focused.compactMap(\.rect).max { $0.width * $0.height < $1.width * $1.height }
                intents.append(Intent(kind: .typing, t: focused[0].t, tEnd: focused[focused.count - 1].t,
                                      x: focused[0].x, y: focused[0].y, rect: field,
                                      caret: focused.map { TypingTrace.Sample(t: $0.t, x: $0.x, y: $0.y) }))
            } else if let tr = typing.first(where: { $0.t0 <= burst.t1 + 0.15 && $0.t1 >= burst.t0 - 0.15 }), let first = tr.samples.first {
                intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1, x: first.x, y: first.y, rect: tr.rect, caret: tr.samples))
            } else if let a = sorted.last(where: { $0.kind == .down && $0.button == 0 && $0.t <= burst.t0 && burst.t0 - $0.t < 20 }) {
                // No accessibility frame and no pixel trace: keep the field
                // the user clicked. The camera still follows the typing.
                intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1, x: Double(a.x), y: Double(a.y)))
            }
        }
        if !sorted.contains(where: \.hasPosition) {            // device/imported clip: no input log
            var last = -10.0
            for a in activity where ok(a.t) && a.t - last > 1.5 { intents.append(Intent(kind: .click, t: a.t, tEnd: a.t, x: a.x, y: a.y)); last = a.t }
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
                                     focus: o.focus, origin: .auto))
        }
        func retarget(_ c: SIMD2<Double>, at t: Double, focus: Focus) {
            guard let o = cur else { return }
            let nc = clampC(c, o.scale)
            let moved = (nc - o.c) / half(o.scale)
            if hypot(moved.x, moved.y) < 0.12 { return }                          // clamped to the same view: nothing to do
            if t - o.start <= 0.2 { cur = Open(start: o.start, scale: o.scale, c: nc, focus: focus, anchor: o.anchor); return }
            close(at: t); cur = Open(start: t, scale: o.scale, c: nc, focus: focus, anchor: c)
        }
        func ensureVisible(_ pt: SIMD2<Double>, at t: Double, typing: Bool, focus: Focus) {
            guard let o = cur else { return }
            let h = half(o.scale), d = (pt - o.c) / h                              // -1...1 spans the view
            let outside = typing ? (d.x > 0.60 || d.x < -0.85 || abs(d.y) > p.safeZone)   // text grows rightwards
                                 : (abs(d.x) > p.safeZone || abs(d.y) > p.safeZone)
            guard outside else { return }
            let c = typing ? SIMD2(pt.x + 0.30 * h.x, pt.y)
                           : pt                                                    // click anchor is the exact pixel
            retarget(c, at: t, focus: focus)
        }
        func absorbKeepAlive(upTo t: Double) {
            guard let o = cur else { return }
            while ki < keep.count, keep[ki].t < t {
                let e = keep[ki]; ki += 1
                let d = (SIMD2(Double(e.x), Double(e.y)) - o.c) / half(o.scale)
                if e.t - last <= p.zoomOutGap, abs(d.x) <= 1, abs(d.y) <= 1 { last = max(last, e.t) }
            }
        }
        func chooseScale(_ i: Intent, prevScale: Double?) -> Double {
            let hi = min(clamp(p.maxScale, 1.3, 2.6), i.kind == .typing ? 2.0 : 1.7)
            let lo = clamp(p.minScale, 1.2, hi)
            let s: Double
            if i.kind == .typing {
                // Frame the LINE being typed: viewport ≈ field width + 30 %,
                // between 42 % and 62 % of the screen.
                let fieldW = min(i.rect?.width ?? W * 0.35, W)
                let fit = W / min(max(fieldW * 1.3, W * 0.42), W * 0.62)
                s = clamp(fit, min(1.6, hi), min(2.0, hi))
            } else if let r = i.rect {
                // CONTEXT-sized, not element-sized: a small button must NOT
                // mean a big zoom. The element plus 2.4x its own size is what
                // has to fit the screen.
                let fit = min(W / max(r.width * 2.4, 1), H / max(r.height * 2.4, 1))
                if max(r.width / W, r.height / H) >= 0.85 { return 1 }   // fills the view: don't zoom
                s = clamp(min(fit, 1.7), lo, hi)
            } else {
                // No accessibility frame: the click is a point, so the base
                // scale is the only sensible one.
                s = clamp(p.baseScale, lo, hi)
            }
            guard let prevScale, prevScale > 1.001 else { return s }
            return abs(log(s / prevScale)) < log(1.12) ? clamp(prevScale, lo, hi) : s   // 12 % hysteresis
        }

        func focusCenter(_ i: Intent, _ s: Double) -> SIMD2<Double> {
            // The CARET, right-biased so text has room to grow rightwards.
            if i.kind == .typing { return SIMD2(i.x + 0.30 * half(s).x, i.y) }
            return SIMD2(i.x, i.y)                                  // click anchor = exact pixel
        }
        /// The focus a shot records. A click records the EXACT clicked pixel
        /// (the camera clamps it into the viewport at render time, so the shot
        /// never drifts off the thing the user hit). Typing records the
        /// clamped, right-biased typing centre.
        func focusFor(_ i: Intent, _ s: Double) -> Focus {
            if i.kind == .typing {
                let c = clampC(focusCenter(i, s), s)
                return .fixed(x: c.x / W, y: c.y / H)
            }
            return .fixed(x: i.x / W, y: i.y / H)
        }
        /// Is this target far enough from the open scene that it is a NEW
        /// scene rather than more activity in the current one?
        func isNewTarget(_ pt: SIMD2<Double>, _ o: Open) -> Bool {
            let d = (pt - o.anchor) / half(o.scale)
            return abs(d.x) > p.safeZone || abs(d.y) > p.safeZone
        }

        for it in intents {
            absorbKeepAlive(upTo: it.t)
            if it.kind == .typing, !it.caret.isEmpty {
                // A typing burst is ONE segment. The caret moving inside the
                // field pans that segment, it does not end the shot and open
                // another one: splitting here is what turned a single
                // sentence into a string of separate zooms.
                close(at: it.t)
                let s = chooseScale(it, prevScale: prevScale); prevScale = s
                let start = it.t, end = min(it.tEnd + hold, tm.trimEnd)
                if end - start > 0.2, s > 1.001 {
                    // The camera sits a little right of the caret so the text
                    // has room to grow rightwards, and follows it from there.
                    let bias = 0.30 * half(s).x
                    let path = it.caret.map { TypingTrace.Sample(t: $0.t, x: $0.x + bias, y: $0.y) }
                    let anchor = SIMD2(it.x + bias, it.y)
                    shots.append(ZoomSegment(id: stableID(start, end), start: start, end: end, scale: s,
                                             focus: .fixed(x: anchor.x / W, y: anchor.y / H),
                                             origin: .auto))
                }
                last = max(last, it.tEnd)
                continue
            }
            if let current = cur, it.t - last <= p.zoomOutGap, !isNewTarget(SIMD2(it.x, it.y), current) {
                // The scene continues, but the intent's OWN scale rules still
                // apply: a click must never ride a typing scene's 2.0x, and
                // the "don't zoom" rule must hold for a huge target.
                let s = chooseScale(it, prevScale: current.scale)
                if abs(log(s / current.scale)) > log(1.12) {
                    close(at: it.t)
                    let f = focusFor(it, s)
                    cur = Open(start: it.t, scale: s, c: clampC(focusCenter(it, s), s), focus: f, anchor: SIMD2(it.x, it.y))
                } else if it.kind == .typing {
                    // Typing re-aims the open scene at the caret.
                    let f = focusFor(it, current.scale)
                    cur = Open(start: current.start, scale: current.scale,
                               c: clampC(focusCenter(it, current.scale), current.scale), focus: f, anchor: SIMD2(it.x, it.y))
                }
            } else {
                close(at: last + hold)
                let s = chooseScale(it, prevScale: prevScale); prevScale = s
                let f = focusFor(it, s)
                cur = Open(start: it.t, scale: s, c: clampC(focusCenter(it, s), s), focus: f, anchor: SIMD2(it.x, it.y))
            }
            last = max(last, it.tEnd, min(it.caret.last?.t ?? 0, it.tEnd + 0.15))
        }
        absorbKeepAlive(upTo: .infinity)
        close(at: min(last + hold, tm.trimEnd))

        return shots.filter { s in
            !avoid.contains { $0.lowerBound < s.end && $0.upperBound > s.start - p.leadIn } &&
            tm.output(atSource: s.end) - tm.output(atSource: s.start) > 0.2
        }
    }
}
