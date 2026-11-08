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

/// Scroll-wheel positions jitter event-to-event. Smooth them with a
/// time-windowed Gaussian (sigma 80ms) so a fast flick becomes a glide
/// instead of a camera jump. Pure and deterministic.
enum ScrollSmoother {
    static func positions(events: [InputEvent], sigma: Double = 0.08) -> [Int: (x: Double, y: Double)] {
        let idx = events.indices.filter { events[$0].kind == .scroll }
        var out: [Int: (x: Double, y: Double)] = [:]
        for i in idx {
            var wx = 0.0, wy = 0.0, wsum = 0.0
            for j in idx {
                let dt = events[j].t - events[i].t
                if abs(dt) > 3 * sigma { continue }
                let w = exp(-0.5 * (dt / sigma) * (dt / sigma))
                wx += Double(events[j].x) * w; wy += Double(events[j].y) * w; wsum += w
            }
            if wsum > 0 { out[i] = (wx / wsum, wy / wsum) }
        }
        return out
    }
}

enum ZoomPlanner {
    /// Source-pixel target with an optional verified AX rect. Path interactions
    /// can follow; ordinary clicks always choose a stationary target.
    struct Pt {
        var t: Double, x: Double, y: Double, w: Double
        var path = false
        var isClick = false
        var element: AXFrame? = nil
    }
    struct Seg { var s: Double, e: Double, scale: Double, focus: Focus }

    /// Same source-time window -> same id across replans. IDs never depend
    /// on wall-clock time, hash seeds or the order of sibling segments.
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

    /// Dwell: cursor stationary within `still` for `minDwell` (250-400mc typical).
    static func hovers(_ events: [InputEvent], radius: Double, still: Double,
                       endT: Double, minDwell: Double = 0.3, usable: (Double) -> Bool) -> [Pt] {
        let mv = events.filter { ($0.kind == .move || $0.kind == .drag) && usable($0.t) }
        var out: [Pt] = [], i = 0
        while i < mv.count {
            var j = i
            while j + 1 < mv.count,
                  hypot(Double(mv[j + 1].x - mv[i].x),
                        Double(mv[j + 1].y - mv[i].y)) < still { j += 1 }
            let dwellEnd = j + 1 < mv.count ? mv[j + 1].t : endT
            if dwellEnd - mv[i].t >= minDwell {
                var distance = 0.0, k = i
                while k > 0, mv[i].t - mv[k - 1].t <= 0.4 {
                    distance += hypot(Double(mv[k].x - mv[k - 1].x),
                                      Double(mv[k].y - mv[k - 1].y))
                    k -= 1
                }
                // Weight 2 so a single dwell passes the group.reduce >=2 gate.
                out.append(Pt(t: mv[i].t, x: Double(mv[i].x),
                              y: Double(mv[i].y), w: 2))
            }
            i = j + 1
        }
        return out
    }

    private static func fits(_ points: [Pt], width: Double, height: Double,
                             minScale: Double) -> Bool {
        guard let first = points.first else { return true }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for pt in points {
            minX = min(minX, pt.x); maxX = max(maxX, pt.x)
            minY = min(minY, pt.y); maxY = max(maxY, pt.y)
        }
        return (maxX - minX + 0.12 * width) * max(minScale, 1) <= 0.8 * width &&
               (maxY - minY + 0.12 * height) * max(minScale, 1) <= 0.8 * height
    }

    /// A wide cluster of clicks contains separate intentions. Break it at
    /// the biggest spatial jump, not by turning all clicks into cursor follow.
    private static func separate(_ points: [Pt], width: Double, height: Double,
                                 minScale: Double) -> [[Pt]] {
        guard points.count > 1, !fits(points, width: width, height: height,
                                      minScale: minScale) else { return [points] }
        var cut = 1, maxJump = -1.0
        for index in 1..<points.count {
            let jump = hypot(points[index].x - points[index - 1].x,
                             points[index].y - points[index - 1].y)
            if jump > maxJump { maxJump = jump; cut = index }
        }
        return separate(Array(points[..<cut]), width: width, height: height,
                        minScale: minScale) +
               separate(Array(points[cut...]), width: width, height: height,
                        minScale: minScale)
    }

    static func plan(events: [InputEvent], ax: [AXFrame], activity: [ActivityPoint],
                     src: SourceInfo, p: CameraParams, tm: TimeMap,
                     avoid: [ClosedRange<Double>]) -> [ZoomSegment] {
        let width = Double(src.width), height = Double(src.height)
        guard width > 0, height > 0 else { return [] }
        let diagonal = hypot(width, height), backing = max(src.backingScale, 1)
        if p.preset == .fixed {
            return [ZoomSegment(id: stableID(tm.trimStart, tm.trimEnd),
                                start: tm.trimStart, end: tm.trimEnd,
                                scale: p.maxScale, focus: .follow, origin: .auto)]
        }
        let cutoff = tm.trimEnd - 0.8
        func usable(_ t: Double) -> Bool {
            t.isFinite && t >= tm.trimStart && t <= cutoff && !tm.isCut(t)
        }
        let sorted = events.sorted { $0.t < $1.t }
        let smoothedScroll = ScrollSmoother.positions(events: sorted)
        var points: [Pt] = []
        var lastDrag = -1.0, lastScroll = -1.0
        for (sortedIndex, event) in sorted.enumerated() where usable(event.t) {
            let x = Double(event.x), y = Double(event.y)
            switch event.kind {
            case .down:
                guard event.button == 0, event.flags & 0x14 == 0,
                      x >= 0, x <= width, y >= 0, y <= height else { continue }
                var point = Pt(t: event.t, x: x, y: y, w: max(p.clickWeight, 2), isClick: true)
                if event.axFrameIndex > 0, Int(event.axFrameIndex) <= ax.count {
                    let f = ax[Int(event.axFrameIndex) - 1]
                    if usableAX(f, x: x, y: y, width: width, height: height,
                                backing: backing) {
                        // Accessibility bounds may be much larger than the clicked
                        // control. Only snap to the AX center when it is within
                        // a few source pixels of the actual mouse-down.
                        let cx = clamp(f.x + f.w * 0.5, 0, width)
                        let cy = clamp(f.y + f.h * 0.5, 0, height)
                        if hypot(cx - x, cy - y) <= 4 * backing {
                            point.element = f
                            point.x = cx
                            point.y = cy
                        }
                    }
                }
                points.append(point)
            case .drag:
                if x >= 0, x <= width, y >= 0, y <= height, event.t - lastDrag > 0.1 {
                    points.append(Pt(t: event.t, x: x, y: y, w: 1.5, path: true))
                    lastDrag = event.t
                }
            case .scroll:
                if x >= 0, x <= width, y >= 0, y <= height, event.t - lastScroll > 0.25 {
                    let smoothed = smoothedScroll[sortedIndex]
                    points.append(Pt(t: event.t, x: smoothed?.x ?? x, y: smoothed?.y ?? y, w: 1, path: true))
                    lastScroll = event.t
                }
            default: break
            }
        }

        // A lone keypress, Return, Esc or a shortcut never generates a zoom.
        // Actual typing needs a burst; place it at the last real pointer
        // location or a recent click, never at an invented screen center.
        let presses = sorted.filter {
            $0.kind == .keyDown && usable($0.t) && $0.flags & 0x14 == 0 &&
            $0.keyCode < 53 && ![36, 48, 51].contains($0.keyCode)
        }
        // Caret-first typing: AX caret > focused element > last click > last cursor.
        // Priority: typing > click > dwell > cursor-follow with hysteresis.
        let clicked = sorted.filter { $0.kind == .down && $0.button == 0 && usable($0.t) }
        let positioned = sorted.filter {
            $0.hasPosition && usable($0.t) &&
            Double($0.x) >= 0 && Double($0.x) <= width &&
            Double($0.y) >= 0 && Double($0.y) <= height
        }
        func typingAnchor(_ t: Double) -> (SIMD2<Double>, AXFrame?)?? {
            // Caret rect from AX (Chromium if accessibility on). Peak: element frame.
            if let lastClick = clicked.last(where: { $0.t <= t && t - $0.t < 20 }),
               lastClick.axFrameIndex > 0, Int(lastClick.axFrameIndex) <= ax.count {
                let f = ax[Int(lastClick.axFrameIndex) - 1]
                // Caret x is left edge of focused text range, not box centre.
                let caretX = clamp(f.x + min(f.w * 0.15, 8 * backing), 0, width)
                return (SIMD2(caretX, f.y + f.h / 2), f)
            }
            if let last = clicked.last(where: { $0.t <= t && t - $0.t < 20 }) {
                return (SIMD2(Double(last.x), Double(last.y)), nil)
            }
            if let last = positioned.last(where: { $0.t <= t && t - $0.t < 8 }) {
                return (SIMD2(Double(last.x), Double(last.y)), nil)
            }
            return nil // never window edge/margin — unanchored typing makes no zoom
        }
        var first = 0
        for i in presses.indices where i == presses.count - 1 || presses[i + 1].t - presses[i].t > 0.9 {
            let count = i - first + 1
            let hasClickedField = clicked.contains { $0.t <= presses[first].t && presses[first].t - $0.t < 20 }
            if (count >= 3 || (count >= 2 && hasClickedField)) {
                if let anchorObj = typingAnchor(presses[first].t),
                   let (anchor, elem) = anchorObj {
                    // Caret walks right while typing: advance the end anchor by
                    // an estimated glyph width per key, capped inside the
                    // field, so the frame follows the insertion point instead
                    // of freezing at burst start.
                    let drift = min(Double(count) * 7 * backing, max((elem?.w ?? 0) * 0.7, 0))
                    var firstPt = Pt(t: presses[first].t, x: anchor.x, y: anchor.y, w: 2)
                    firstPt.element = elem
                    var lastPt = Pt(t: presses[i].t, x: anchor.x + drift, y: anchor.y, w: 0.5)
                    lastPt.element = elem
                    points.append(firstPt)
                    points.append(lastPt)
                }
            }
            first = i + 1
        }

        // Dwell 250-400ms, gentle — maps to 1.4x-2.2x via target size, not fixed.
        let radius = lerp(120, 12, clamp(p.sensitivity, 0, 1)) * backing
        points += hovers(sorted, radius: radius, still: 12 * backing,
                         endT: tm.trimEnd, minDwell: 0.3, usable: usable)
        if positioned.isEmpty {
            var last = -10.0
            for item in activity where usable(item.t) && item.t - last > 0.5 {
                points.append(Pt(t: item.t, x: item.x, y: item.y, w: 1))
                last = item.t
            }
        }
        points.sort { ($0.t, -$0.w) < ($1.t, -$1.w) }

        var clusters: [[Pt]] = []
        for point in points {
            if let cluster = clusters.last, let previous = cluster.last,
               point.t - previous.t <= p.mergeGap {
                let totalWeight = max(cluster.reduce(0) { $0 + $1.w }, 1)
                let midX = cluster.reduce(0) { $0 + $1.x * $1.w } / totalWeight
                let midY = cluster.reduce(0) { $0 + $1.y * $1.w } / totalWeight
                if hypot(point.x - midX, point.y - midY) <= 0.12 * diagonal {
                    clusters[clusters.count - 1].append(point)
                    continue
                }
            }
            clusters.append([point])
        }
        var segments: [Seg] = []
        for cluster in clusters {
            let pieces = cluster.contains(where: \.path) ? [cluster] :
                separate(cluster, width: width, height: height, minScale: p.minScale)
            for group in pieces where group.reduce(0, { $0 + $1.w }) >= 2 {
                let anchors = group.filter { $0.w > 0 }
                guard !anchors.isEmpty else { continue }
                var left = anchors[0].x, right = left
                var top = anchors[0].y, bottom = top
                for point in anchors {
                    left = min(left, point.element?.x ?? point.x)
                    right = max(right, (point.element.map { $0.x + $0.w }) ?? point.x)
                    top = min(top, point.element?.y ?? point.y)
                    bottom = max(bottom, (point.element.map { $0.y + $0.h }) ?? point.y)
                }
                let boxWidth = max(right - left, 0), boxHeight = max(bottom - top, 0)
                // Derive scale from target size: smaller target -> higher zoom.
                // 1.4-3.3 typical, configurable min/max. Pure point targets hit cap.
                let targetArea = (boxWidth + 48 * backing) * (boxHeight + 48 * backing)
                // Sigmoid: 0 area -> 3.3, large area -> 1.4
                let norm = 1.0 / (1.0 + targetArea / 40_000)
                let targetScale = 1.4 + 1.9 * norm
                let fit = 0.8 * min(width / (boxWidth + 0.12 * width),
                                    height / (boxHeight + 0.12 * height))
                let usableFit = fit >= max(p.minScale, p.minTrigger)
                let scale = clamp(min(fit, targetScale), p.minScale, p.maxScale)
                let mass = max(anchors.reduce(0) { $0 + $1.w }, 1)
                let cx = anchors.reduce(0) { $0 + $1.x * $1.w } / mass
                let cy = anchors.reduce(0) { $0 + $1.y * $1.w } / mass
                let focus: Focus
                let clickAnchor = anchors.first(where: \.isClick)
                let dwellOnly = !anchors.contains(where: \.isClick)
                // Typing caret: frame the caret rect, not box centre for wide fields.
                let typingAnchor = anchors.first { $0.w == 2 && $0.element != nil } ?? anchors.first { $0.w == 2 }
                if let typingAnchor, let el = typingAnchor.element, dwellOnly {
                    // Left-aligned caret for wide fields
                    let caretX = clamp(el.x + min(el.w * 0.15, 8 * backing), 0, width)
                    focus = .fixed(x: caretX / width, y: (el.y + el.h / 2) / height)
                } else if let typingAnchor, dwellOnly {
                    focus = .fixed(x: typingAnchor.x / width, y: typingAnchor.y / height)
                } else if group.contains(where: \.path) && !usableFit {
                    focus = .follow
                } else if let clickAnchor, anchors.count == 1, let element = clickAnchor.element {
                    focus = .element(x: element.x / width, y: element.y / height,
                                     w: element.w / width, h: element.h / height)
                } else if let clickAnchor {
                    focus = .fixed(x: clickAnchor.x / width, y: clickAnchor.y / height)
                } else if anchors.count == 1, let element = anchors[0].element {
                    focus = .element(x: element.x / width, y: element.y / height,
                                     w: element.w / width, h: element.h / height)
                } else {
                    focus = .fixed(x: cx / width, y: cy / height)
                }
                // CameraSolver already performs the critically damped
                // entrance on this timeline. Extra spring settle time here
                // shifted the entire zoom hundreds of milliseconds too early.
                let anticipation = clamp(p.leadIn, 0.15, 0.30)
                let start = max(tm.trimStart, group[0].t - anticipation)
                let end = min(tm.trimEnd,
                              max(group[group.count - 1].t + max(p.tail, 0.8),
                                  start + p.minHold))
                guard end > start,
                      !avoid.contains(where: { $0.lowerBound < end && $0.upperBound > start }) else { continue }
                segments.append(Seg(s: start, e: end, scale: scale, focus: focus))
            }
        }
        let gap = max(p.panThroughGap, 0.6)
        if segments.count > 1 {
            for i in 0..<(segments.count - 1) where segments[i + 1].s - segments[i].e < gap {
                segments[i].e = max(segments[i + 1].s, segments[i].s + 0.3)
            }
        }
        return segments.compactMap {
            guard tm.output(atSource: $0.e) - tm.output(atSource: $0.s) > 0.2 else { return nil }
            return ZoomSegment(id: stableID($0.s, $0.e), start: $0.s, end: $0.e,
                               scale: $0.scale, focus: $0.focus, origin: .auto)
        }
    }
}
