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

/// Auto-zoom decision layer v3. ONLY a left click or a typing burst can
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
    private struct Open { var start: Double, scale: Double, c: SIMD2<Double> }

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

    static func plan(events: [InputEvent], ax: [AXFrame], typing: [TypingTrace], activity: [ActivityPoint],
                     src: SourceInfo, p: CameraParams, tm: TimeMap, avoid: [ClosedRange<Double>]) -> [ZoomSegment] {
        let W = Double(src.width), H = Double(src.height), b = max(src.backingScale, 1)
        guard W > 0, H > 0 else { return [] }
        if p.preset == .fixed {
            return [ZoomSegment(id: stableID(tm.trimStart, tm.trimEnd), start: tm.trimStart, end: tm.trimEnd,
                                scale: p.maxScale, focus: .follow, origin: .auto)]
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
            if let tr = typing.first(where: { $0.t0 <= burst.t1 + 0.5 && $0.t1 >= burst.t0 - 0.5 }), let s0 = tr.samples.first {
                intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1, x: s0.x, y: s0.y, rect: tr.rect, caret: tr.samples))
            } else if let a = sorted.last(where: { $0.kind == .down && $0.button == 0 && $0.t <= burst.t0 && burst.t0 - $0.t < 20 }) {
                intents.append(Intent(kind: .typing, t: burst.t0, tEnd: burst.t1, x: Double(a.x), y: Double(a.y)))   // fallback: last click
            }   // no trace and no click => NO zoom. Never guess from the cursor.
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
        var prevScale = p.baseScale
        let keep = sorted.filter { ($0.kind == .scroll || $0.kind == .drag) && ok($0.t) }
        var ki = 0

        func close(at end: Double) {
            guard let o = cur else { return }
            cur = nil
            guard end - o.start > 0.2 else { return }
            shots.append(ZoomSegment(id: stableID(o.start, end), start: o.start, end: end, scale: o.scale,
                                     focus: .fixed(x: o.c.x / W, y: o.c.y / H), origin: .auto))
        }
        func retarget(_ c: SIMD2<Double>, at t: Double) {
            guard let o = cur else { return }
            let nc = clampC(c, o.scale)
            let moved = (nc - o.c) / half(o.scale)
            if hypot(moved.x, moved.y) < 0.02 { return }                          // clamped to the same view: nothing to do
            if t - o.start <= 0.2 { cur = Open(start: o.start, scale: o.scale, c: nc); return }
            close(at: t); cur = Open(start: t, scale: o.scale, c: nc)
        }
        func ensureVisible(_ pt: SIMD2<Double>, at t: Double, typing: Bool, rect: CGRect?) {
            guard let o = cur else { return }
            let h = half(o.scale), d = (pt - o.c) / h                              // -1...1 spans the view
            let outside = typing ? (d.x > 0.60 || d.x < -0.85 || abs(d.y) > p.safeZone)   // text grows rightwards
                                 : (abs(d.x) > p.safeZone || abs(d.y) > p.safeZone)
            guard outside else { return }
            // Prefer the rect centre only when the click is near it; otherwise
            // keep the exact click pixel.
            var c = pt
            if let r = rect, r.width < 1.6 * h.x {
                let m = SIMD2(Double(r.midX), Double(r.midY))
                if hypot(m.x - pt.x, m.y - pt.y) <= 12 * b { c = m }
            }
            if typing { c = SIMD2(pt.x + 0.35 * h.x, pt.y) }   // caret lands ~18 % from the left edge
            retarget(c, at: t)
        }
        func absorbKeepAlive(upTo t: Double) {
            guard let o = cur else { return }
            while ki < keep.count, keep[ki].t < t {
                let e = keep[ki]; ki += 1
                let d = (SIMD2(Double(e.x), Double(e.y)) - o.c) / half(o.scale)
                if e.t - last <= p.zoomOutGap, abs(d.x) <= 1, abs(d.y) <= 1 { last = max(last, e.t) }
            }
        }
        func chooseScale(_ i: Intent, prevScale: Double) -> Double {
            var s = p.baseScale
            if let r = i.rect, r.width > 1, r.height > 1 {
                s = i.kind == .typing ? 0.06 * H / r.height                              // text line ≈ 6 % of view height
                                      : min(0.42 * W / r.width, 0.30 * H / r.height)     // element ≈ 42 % of view width
            }
            if abs(log(s / prevScale)) < log(1.3) { s = prevScale }                      // no breathing between scenes
            s = clamp(s, p.minScale, min(p.autoMaxScale, p.maxScale))
            return s
        }
        func focusCenter(_ i: Intent, _ s: Double) -> SIMD2<Double> {
            if i.kind == .typing { return SIMD2(i.x + 0.35 * half(s).x, i.y) }
            // AX center only when the click is essentially ON the element's
            // centre; off-centre clicks keep their exact pixel.
            if let r = i.rect, r.width < 1.6 * half(s).x {
                let m = SIMD2(Double(r.midX), Double(r.midY))
                if hypot(m.x - i.x, m.y - i.y) <= 12 * b { return m }
            }
            return SIMD2(i.x, i.y)
        }

        for it in intents {
            absorbKeepAlive(upTo: it.t)
            if cur != nil, it.t - last <= p.zoomOutGap {
                ensureVisible(SIMD2(it.x, it.y), at: it.t, typing: it.kind == .typing, rect: it.rect)
            } else {
                close(at: last + p.hold)
                let s = chooseScale(it, prevScale: prevScale); prevScale = s
                cur = Open(start: it.t, scale: s, c: clampC(focusCenter(it, s), s))
            }
            for smp in it.caret where smp.t >= it.t { ensureVisible(SIMD2(smp.x, smp.y), at: smp.t, typing: true, rect: nil) }
            last = max(last, it.tEnd, it.caret.last?.t ?? 0)
        }
        absorbKeepAlive(upTo: .infinity)
        close(at: min(last + p.hold, tm.trimEnd))

        return shots.filter { s in
            !avoid.contains { $0.lowerBound < s.end && $0.upperBound > s.start - p.leadIn } &&
            tm.output(atSource: s.end) - tm.output(atSource: s.start) > 0.2
        }
    }
}
