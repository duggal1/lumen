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
            if speed >= 1.5 { out.append(SpeedRamp(start: a + 0.25, end: b - 0.25, speed: speed)) }
        }
        return out
    }
}

enum ZoomPlanner {
    struct Pt { var t: Double, x: Double, y: Double, w: Double }
    struct Seg { var s: Double, e: Double, scale: Double, focus: Focus }

    /// Same (start, end) -> same id, so the UI selection survives replans.
    static func stableID(_ s: Double, _ e: Double) -> UUID {
        func h(_ v: UInt64) -> String { let x = String(v, radix: 16, uppercase: true); return String(repeating: "0", count: 16 - x.count) + x }
        let f = h(s.bitPattern) + h(e.bitPattern)
        func sl(_ o: Int, _ n: Int) -> String { String(f[f.index(f.startIndex, offsetBy: o)..<f.index(f.startIndex, offsetBy: o + n)]) }
        return UUID(uuidString: "\(sl(0, 8))-\(sl(8, 4))-\(sl(12, 4))-\(sl(16, 4))-\(sl(20, 12))") ?? UUID()
    }

    /// Purposeful pointing: travel > radius within 0.4 s that ends in a dwell >= 0.2 s. Wiggles never qualify.
    static func hovers(_ events: [InputEvent], radius: Double, still: Double, endT: Double, usable: (Double) -> Bool) -> [Pt] {
        let mv = events.filter { ($0.kind == .move || $0.kind == .drag) && usable($0.t) }
        var out: [Pt] = []
        var i = 0
        while i < mv.count {
            var j = i
            while j + 1 < mv.count, hypot(Double(mv[j + 1].x - mv[i].x), Double(mv[j + 1].y - mv[i].y)) < still { j += 1 }
            let dwellEnd = j + 1 < mv.count ? mv[j + 1].t : endT
            if dwellEnd - mv[i].t >= 0.2 {
                var path = 0.0, k = i
                while k > 0, mv[i].t - mv[k - 1].t <= 0.4 {
                    path += hypot(Double(mv[k].x - mv[k - 1].x), Double(mv[k].y - mv[k - 1].y)); k -= 1
                }
                if path > radius { out.append(Pt(t: mv[i].t, x: Double(mv[i].x), y: Double(mv[i].y), w: 1)) }
            }
            i = j + 1
        }
        return out
    }

    /// Returns SOURCE-time segments tagged .auto. `avoid` = manual zoom ranges (source time) that auto segments must not overlap.
    static func plan(events: [InputEvent], ax: [AXFrame], activity: [ActivityPoint], src: SourceInfo, p: CameraParams,
                     tm: TimeMap, avoid: [ClosedRange<Double>]) -> [ZoomSegment] {
        let W = Double(src.width), H = Double(src.height), diag = hypot(W, H), backing = max(src.backingScale, 1)
        if p.preset == .fixed {
            return [ZoomSegment(id: stableID(tm.trimStart, tm.trimEnd), start: tm.trimStart, end: tm.trimEnd, scale: p.maxScale, focus: .follow, origin: .auto)]
        }
        let cutoff = tm.trimEnd - 0.8                       // the Stop click / hotkey sit at the very end and must never trigger a zoom
        func usable(_ t: Double) -> Bool { t >= tm.trimStart && t <= cutoff && !tm.isCut(t) }
        var pts: [Pt] = []
        var lastClick = (x: W / 2, y: H / 2)
        var hasClick = false
        var lastDrag = -1.0, lastKey = -10.0, lastScroll = -10.0
        for e in events where usable(e.t) {
            let x = Double(e.x), y = Double(e.y)
            switch e.kind {
            case .down:
                guard e.button == 0, e.flags & 0x14 == 0, x >= 0, x <= W, y >= 0, y <= H else { continue }
                hasClick = true
                lastClick = (x, y); pts.append(Pt(t: e.t, x: x, y: y, w: p.clickWeight))
                if e.axFrameIndex > 0, Int(e.axFrameIndex) <= ax.count {
                    let f = ax[Int(e.axFrameIndex) - 1]
                    if f.w > 8, f.h > 8, f.w <= 0.5 * W, f.h <= 0.5 * H {      // big containers would cancel the zoom
                        pts.append(Pt(t: e.t, x: f.x, y: f.y, w: 0)); pts.append(Pt(t: e.t, x: f.x + f.w, y: f.y + f.h, w: 0))
                    }
                }
            case .drag: if e.t - lastDrag > 0.1 { pts.append(Pt(t: e.t, x: x, y: y, w: p.clickWeight)); lastDrag = e.t }
            case .keyDown:
                guard hasClick, e.flags & 0x14 == 0, !(54...63).contains(e.keyCode) else { break }                        // cmd / ctrl chords are shortcuts, not typing
                if e.t - lastKey > 0.8 { pts.append(Pt(t: e.t, x: lastClick.x, y: lastClick.y, w: 2)) }
                lastKey = e.t
            case .scroll: if e.t - lastScroll > 0.25 { pts.append(Pt(t: e.t, x: x, y: y, w: 1)); lastScroll = e.t }
            default: break
            }
        }
        let radius = lerp(120, 12, clamp(p.sensitivity, 0, 1)) * backing
        pts += hovers(events, radius: radius, still: 6 * backing, endT: tm.trimEnd, usable: usable)
        if !events.contains(where: { $0.hasPosition }) {                         // device / imported clip: pixel activity drives zoom
            var last = -10.0
            for a in activity where usable(a.t) && a.t - last > 0.5 { pts.append(Pt(t: a.t, x: a.x, y: a.y, w: 1)); last = a.t }
        }
        pts.sort { $0.t < $1.t }

        var clusters: [[Pt]] = []
        for pt in pts {
            if let c = clusters.last, let l = c.last, pt.t - l.t <= p.mergeGap {
                let cx = c.reduce(0) { $0 + $1.x } / Double(c.count), cy = c.reduce(0) { $0 + $1.y } / Double(c.count)
                if pt.t == l.t || hypot(pt.x - cx, pt.y - cy) <= 0.12 * diag { clusters[clusters.count - 1].append(pt); continue }
            }
            clusters.append([pt])
        }
        var segs: [Seg] = []
        for c in clusters {
            guard c.reduce(0, { $0 + $1.w }) >= 2 else { continue }              // a click, a typing burst, or two purposeful hovers
            let xs = c.map(\.x), ys = c.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
            let bw = (maxX - minX) + 0.24 * W, bh = (maxY - minY) + 0.24 * H    // 12% padding each side
            let fit = 0.8 * min(W / bw, H / bh)
            var scale = clamp(fit, p.minScale, p.maxScale)
            scale = max((scale * 10).rounded() / 10, 1.1)
            let fits = (maxX - minX) * scale <= 0.8 * W && (maxY - minY) * scale <= 0.8 * H
            let focus: Focus = (fits && fit >= p.minTrigger) ? .fixed(x: (minX + maxX) / 2 / W, y: (minY + maxY) / 2 / H) : .follow
            // Start the camera move before the first interaction. The CameraSolver
            // finishes its auto transition at the click, not after it.
            let anticipation = clamp(p.leadIn, 0.15, 0.30)
            let s = max(tm.trimStart, c.first!.t - anticipation)
            let e = min(tm.trimEnd, max(c.last!.t + max(p.tail, 0.8), s + p.minHold))
            guard e > s, !avoid.contains(where: { $0.lowerBound < e && $0.upperBound > s }) else { continue }
            segs.append(Seg(s: s, e: e, scale: scale, focus: focus))
        }
        let gap = max(p.panThroughGap, 0.6)                                      // never zoom out and straight back in
        if segs.count > 1 {
            for i in 0..<(segs.count - 1) where segs[i + 1].s - segs[i].e < gap {
                segs[i].e = max(segs[i + 1].s, segs[i].s + 0.3)
            }
        }
        return segs.compactMap {
            guard tm.output(atSource: $0.e) - tm.output(atSource: $0.s) > 0.2 else { return nil }
            return ZoomSegment(id: stableID($0.s, $0.e), start: $0.s, end: $0.e, scale: $0.scale, focus: $0.focus, origin: .auto)
        }
    }
}
