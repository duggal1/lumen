import Foundation
import LumenCore
import LumenProject

enum SpeedRamps {
    static func plan(events: [InputEvent], vad: [ClosedRange<Double>], tm: TimeMap, audio: AudioPlan, backing: Double) -> [SpeedRamp] {
        let minIdle = max(audio.speedRampMinIdle, 4.0)          // short idles are normal pauses, never speed them up
        var act: [Double] = [tm.trimStart]
        var lx = -1e6, ly = -1e6
        for e in events {
            switch e.kind {
            case .move, .drag:
                if hypot(Double(e.x) - lx, Double(e.y) - ly) > 2 * backing { act.append(e.t); lx = Double(e.x); ly = Double(e.y) }
            default: act.append(e.t)
            }
        }
        act.append(tm.trimEnd)
        act = act.filter { $0 >= tm.trimStart && $0 <= tm.trimEnd }.sorted()
        var out: [SpeedRamp] = []
        guard act.count > 1 else { return out }
        for i in 0..<(act.count - 1) {
            let a = act[i], b = act[i + 1]
            guard b - a >= minIdle else { continue }
            if vad.contains(where: { $0.upperBound > a && $0.lowerBound < b }) { continue }
            let speed = min(audio.speedRampMaxSpeed, (b - a) / 0.8)
            if speed >= 1.5 { out.append(SpeedRamp(start: a + 0.25, end: b - 0.25, speed: speed)) }
        }
        return out
    }
}

enum ZoomPlanner {
    struct Pt { var t: Double, x: Double, y: Double }
    struct Seg { var s: Double, e: Double, scale: Double, focus: Focus }

    static func plan(events: [InputEvent], ax: [AXFrame], src: SourceInfo, p: CameraParams, tm: TimeMap) -> [ZoomSegment] {
        let W = Double(src.width), H = Double(src.height), diag = hypot(W, H)
        if p.preset == .fixed {
            return [ZoomSegment(start: 0, end: tm.outputDuration, scale: p.maxScale, focus: .follow, origin: .auto)]
        }
        // Ignore the tail: the Stop click / stop hotkey are recorded right before the end and must never trigger a zoom.
        let cutoff = tm.trimEnd - 0.8
        var pts: [Pt] = []
        var lastClick = (x: W / 2, y: H / 2), lastDrag = -1.0, lastClickTime = -Double.infinity
        for e in events where e.t >= tm.trimStart && e.t <= cutoff {
            let x = Double(e.x), y = Double(e.y)
            guard x >= 0, x <= W, y >= 0, y <= H else { continue }
            switch e.kind {
            case .down:
                guard e.button == 0, e.flags & 0x14 == 0 else { continue }
                lastClickTime = e.t
                lastClick = (x, y); pts.append(Pt(t: e.t, x: x, y: y))
                if e.axFrameIndex > 0, Int(e.axFrameIndex) <= ax.count {
                    let f = ax[Int(e.axFrameIndex) - 1]
                    // Big containers (windows, web areas) would blow the focus box up to the whole screen and cancel the zoom.
                    if f.w > 8, f.h > 8, x >= f.x, x <= f.x + f.w, y >= f.y, y <= f.y + f.h, f.w <= 0.5 * W, f.h <= 0.5 * H {
                        pts.append(Pt(t: e.t, x: f.x, y: f.y)); pts.append(Pt(t: e.t, x: f.x + f.w, y: f.y + f.h))
                    }
                }
            case .drag: if e.t - lastClickTime < 2.5 && e.t - lastDrag > 0.1 { pts.append(Pt(t: e.t, x: x, y: y)); lastDrag = e.t }
            case .keyDown:
                guard e.t - lastClickTime < 1.5, e.flags & 0x14 == 0 else { break }        // cmd / ctrl chords are shortcuts, not typing
                pts.append(Pt(t: e.t, x: lastClick.x, y: lastClick.y))
            case .scroll:
                if e.t - lastClickTime < 1.5 { pts.append(Pt(t: e.t, x: x, y: y)) }
            default: break
            }
        }
        // cluster: within mergeGap seconds and 35% of the screen diagonal
        var clusters: [[Pt]] = []
        for pt in pts {
            if let c = clusters.last, let l = c.last, pt.t - l.t <= p.mergeGap {
                let cx = c.reduce(0) { $0 + $1.x } / Double(c.count), cy = c.reduce(0) { $0 + $1.y } / Double(c.count)
                if hypot(pt.x - cx, pt.y - cy) <= 0.12 * diag { clusters[clusters.count - 1].append(pt); continue }
            }
            clusters.append([pt])
        }
        var segs: [Seg] = []
        for c in clusters {
            let xs = c.map(\.x), ys = c.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
            let bw = (maxX - minX) + 0.24 * W, bh = (maxY - minY) + 0.24 * H          // 12% padding each side
            let fit = 0.8 * min(W / bw, H / bh)
            let spread = hypot(maxX - minX, maxY - minY) / diag
            // Every click cluster zooms. A wide cluster still gets a real zoom (and follows the cursor) instead of being skipped.
            var scale = fit >= p.minTrigger ? min(fit, p.maxScale) : min(max(1.5, p.minTrigger), p.maxScale)
            scale = max((scale * 10).rounded() / 10, 1.1)
            let focus: Focus = spread > 0.25 ? .follow : .fixed(x: (minX + maxX) / 2 / W, y: (minY + maxY) / 2 / H)
            let s = max(tm.trimStart, c.first!.t)                            // lead-in before first event
            let e = min(tm.trimEnd, max(c.last!.t + p.tail, s + p.minHold))
            guard e > s else { continue }
            segs.append(Seg(s: s, e: e, scale: scale, focus: focus))
        }
        // pan-through: don't zoom out if the next cluster starts soon
        if segs.count > 1 {
            for i in 0..<(segs.count - 1) where segs[i + 1].s - segs[i].e < p.panThroughGap {
                segs[i].e = max(segs[i + 1].s, segs[i].s + 0.3)
            }
        }
        return segs.compactMap {
            let a = tm.output(atSource: $0.s), b = tm.output(atSource: $0.e)
            guard b - a > 0.2 else { return nil }
            return ZoomSegment(start: a, end: b, scale: $0.scale, focus: $0.focus, origin: .auto)
        }
    }
}
