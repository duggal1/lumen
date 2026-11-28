import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenDirector

extension TimelineStrip {
    /// Pure selection rule for a drag. A music lane is a list tile, not a
    /// canvas region: it gets a flat selected surface, never corner brackets.
    /// Kept separate from the gesture so it is testable without a window.
    nonisolated static func dragSelectionID(_ id: UUID?, isMusic: Bool) -> UUID? {
        guard let id else { return nil }
        return isMusic && !StudioSelectionStyle.usesCornerBrackets(for: .musicTile) ? nil : id
    }

    // MARK: - Hover

    func setHover(at p: CGPoint, width: CGFloat) {
        let vp = viewport(width: width)
        let lat = vp.lattice
        let sc = lat.col(atX: p.x)
        if scrubCol != sc { scrubCol = sc }
        var clip: UUID? = nil, zoomID: UUID? = nil, col: Int? = nil, cutID: UUID? = nil, musicID: UUID? = nil
        var cursor = NSCursor.arrow
        // Pending handles win.
        if let pc = model.pendingCut {
            let a = vp.x(pc.start), b = vp.x(pc.end)
            if abs(p.x - a) < 7 || abs(p.x - b) < 7 { cursor = .resizeLeftRight }
            else if p.x > a && p.x < b && p.y >= TimelineStrip.Lanes.clip { cursor = .pointingHand }
        }
        if p.y < TimelineStrip.Lanes.ruler {
            cursor = .openHand
        } else if p.y >= TimelineStrip.Lanes.clip && p.y < TimelineStrip.Lanes.zoom {
            for k in model.timeline.clips.reversed() {
                let a = vp.x(k.start), b = vp.x(k.end)
                if abs(p.x - a) < 7 || abs(p.x - b) < 7 { cursor = .resizeLeftRight; clip = k.id; break }
                if p.x >= a - 1 && p.x <= b + 1 { clip = k.id; break }
            }
        } else if p.y >= TimelineStrip.Lanes.zoom && p.y < TimelineStrip.Lanes.events {
            // Cut seam brackets.
            let tm = model.timeline.timeMap
            for cut in tm.cuts where cut.end > cut.start {
                let x = vp.x(tm.output(atSource: cut.end))
                if abs(p.x - x) < 8 { cutID = cut.id; cursor = .resizeLeftRight; break }
            }
            if cutID == nil {
                for z in model.timeline.zoom.reversed() {
                    let a = vp.x(tm.output(atSource: z.start)), b = vp.x(tm.output(atSource: z.end))
                    if p.x >= a - 7 && p.x <= b + 7 {
                        zoomID = z.id
                        if abs(p.x - a) < 7 || abs(p.x - b) < 7 { cursor = .resizeLeftRight }
                        break
                    }
                }
            }
        } else if p.y >= TimelineStrip.Lanes.events && p.y < TimelineStrip.Lanes.audio {
            var bestD: CGFloat = 6
            for m in outEvents() {
                let d = abs(vp.cx(m.t) - p.x)
                if d < bestD { bestD = d; col = vp.col(m.t) }
            }
            if col != nil { cursor = .pointingHand }
        } else if p.y >= TimelineStrip.Lanes.music && p.y < TimelineStrip.Lanes.music + TimelineStrip.Lanes.lane {
            for lane in musicLanes().reversed() {
                let a = vp.x(lane.placement), b = vp.x(lane.placement + musicDuration(for: lane))
                if p.x >= a - 7 && p.x <= b + 7 {
                    musicID = lane.id
                    if abs(p.x - a) < 7 || abs(p.x - b) < 7 { cursor = .resizeLeftRight }
                    break
                }
            }
        }
        if hoveredClip != clip { hoveredClip = clip }
        if hoveredMusic != musicID { hoveredMusic = musicID }
        if hoveredZoom != zoomID { hoveredZoom = zoomID }
        if hoveredCut != cutID { hoveredCut = cutID }
        if hoveredCol != col { hoveredCol = col }
        cursor.set()
    }

    // MARK: - Hit, drag (command path preserved)

    func hit(_ p: CGPoint, _ w: CGFloat) -> Drag {
        let vp = viewport(width: w)
        // Pending range first: handles, then body.
        if let pc = model.pendingCut {
            let a = vp.x(pc.start), b = vp.x(pc.end)
            if abs(p.x - a) < 7 { return Drag(kind: .pendingStart, id: nil, orig: nil, origClip: nil, origTap: nil, t0: pc.start, pending0: pc) }
            if abs(p.x - b) < 7 { return Drag(kind: .pendingEnd, id: nil, orig: nil, origClip: nil, origTap: nil, t0: pc.end, pending0: pc) }
            if p.x > a, p.x < b, p.y >= TimelineStrip.Lanes.clip {
                return Drag(kind: .pendingBody, id: nil, orig: nil, origClip: nil, origTap: nil, t0: vp.t(atX: p.x), pending0: pc)
            }
        }
        // Cut seam brackets (zoom lane): left = start edge, right = end edge.
        if p.y >= TimelineStrip.Lanes.zoom && p.y < TimelineStrip.Lanes.events {
            let tm = model.timeline.timeMap
            for cut in tm.cuts where cut.end > cut.start {
                let x = vp.x(tm.output(atSource: cut.end))
                if abs(p.x - x) < 8 {
                    // Left half moves the start edge, right half the end edge.
                    let kind: Drag.Kind = p.x < x ? .cutStart : .cutEnd
                    return Drag(kind: kind, id: cut.id, orig: nil, origClip: nil, origTap: nil, t0: vp.t(atX: p.x))
                }
            }
        }
        if p.y < TimelineStrip.Lanes.ruler {
            return Drag(kind: .pan, id: nil, orig: nil, origClip: nil, origTap: nil, t0: 0, o0: vp.origin)
        }
        // Clip edges before body: trim handles.
        if p.y >= TimelineStrip.Lanes.clip && p.y < TimelineStrip.Lanes.zoom {
            for clip in model.timeline.clips.reversed() {
                let a = vp.x(clip.start), b = vp.x(clip.end)
                if abs(p.x - a) < 7 { return Drag(kind: .clipStart, id: clip.id, orig: nil, origClip: clip, origTap: nil, t0: clip.start) }
                if abs(p.x - b) < 7 { return Drag(kind: .clipEnd, id: clip.id, orig: nil, origClip: clip, origTap: nil, t0: clip.end) }
                if p.x > a, p.x < b { return Drag(kind: .reorder, id: clip.id, orig: nil, origClip: clip, origTap: nil, t0: clip.start) }
            }
        }
        if p.y >= TimelineStrip.Lanes.zoom && p.y < TimelineStrip.Lanes.events {
            let tm = model.timeline.timeMap
            let t0 = vp.t(atX: p.x)
            for z in model.timeline.zoom.reversed() {
                let a = vp.x(tm.output(atSource: z.start)), b = vp.x(tm.output(atSource: z.end))
                if abs(p.x - a) < 7 { return Drag(kind: .left, id: z.id, orig: z, origClip: nil, origTap: nil, t0: t0) }
                if abs(p.x - b) < 7 { return Drag(kind: .right, id: z.id, orig: z, origClip: nil, origTap: nil, t0: t0) }
                if p.x > a, p.x < b { return Drag(kind: .move, id: z.id, orig: z, origClip: nil, origTap: nil, t0: t0) }
            }
        }
        if p.y >= TimelineStrip.Lanes.events && p.y < TimelineStrip.Lanes.audio {
            let tm = model.timeline.timeMap
            for tap in model.timeline.overlays.taps.reversed() {
                let tx = vp.cx(tm.output(atSource: tap.t))
                if abs(p.x - tx) < 8 { return Drag(kind: .tapMove, id: tap.id, orig: nil, origClip: nil, origTap: tap, t0: vp.t(atX: p.x)) }
            }
        }
        if p.y >= TimelineStrip.Lanes.music && p.y < TimelineStrip.Lanes.music + TimelineStrip.Lanes.lane {
            for lane in musicLanes().reversed() {
                let a = vp.x(lane.placement), b = vp.x(lane.placement + musicDuration(for: lane))
                if p.x >= a - 7 && p.x <= b + 7 {
                    let kind: Drag.Kind = abs(p.x - a) < 7 ? .musicLeft : (abs(p.x - b) < 7 ? .musicRight : .musicMove)
                    return Drag(kind: kind, id: lane.id, orig: nil, origClip: nil, origTap: nil, t0: vp.t(atX: p.x))
                }
            }
        }
        return Drag(kind: .seek, id: nil, orig: nil, origClip: nil, origTap: nil, t0: 0)
    }

    func snapTargets() -> [Double] {
        var xs: [Double] = []
        xs += outEvents().map(\.t)
        xs.append(model.playhead)
        for c in model.timeline.clips { xs.append(c.start); xs.append(c.end) }
        let tm = model.timeline.timeMap
        for cut in tm.cuts where cut.end > cut.start { xs.append(tm.output(atSource: cut.end)) }
        for z in model.timeline.zoom { xs.append(tm.output(atSource: z.start)); xs.append(tm.output(atSource: z.end)) }
        return xs
    }

    func snapTime(_ t: Double, dur: Double, vp: Viewport) -> Double {
        guard model.snapEnabled else { return t }
        let tol = 6 / max(Double(vp.pps), 0.001)
        var best: Double? = nil, bestD = tol
        for target in snapTargets() {
            let d = abs(target - t)
            if d < bestD { bestD = d; best = target }
        }
        return best ?? t
    }

    func change(_ v: DragGesture.Value, _ w: CGFloat) {
        let vp = viewport(width: w)
        let dur = model.timeline.compositionDuration, t = vp.t(atX: v.location.x)
        if drag == nil {
            drag = hit(v.startLocation, w)
            if drag?.kind == .seek { model.beginScrub() }
            if let d = drag, d.isMusic {
                musicDragOrigin = musicLanes().first { $0.id == d.id }
            }
            model.selection = TimelineStrip.dragSelectionID(drag?.id, isMusic: drag?.isMusic ?? false)
            // Clicking a marker seeks to it exactly.
            if drag?.kind == .seek, v.startLocation.y >= TimelineStrip.Lanes.events, v.startLocation.y < TimelineStrip.Lanes.audio {
                var bestT: Double? = nil, bestD: CGFloat = 6
                for m in outEvents() {
                    let d = abs(vp.cx(m.t) - v.startLocation.x)
                    if d < bestD { bestD = d; bestT = m.t }
                }
                if let bt = bestT { model.seek(bt); return }
            }
        }
        guard let d = drag else { return }
        // Ruler panning is already direct manipulation; don't apply a second
        // edge-scroll delta or move the viewport on a simple ruler click.
        if d.kind != .pan {
            let leftEdge = vp.lattice.x0, rightEdge = vp.lattice.x0 + vp.span
            if v.location.x < leftEdge + 16 { applyOrigin(vp.origin - vp.visible * 0.02, width: w) }
            else if v.location.x > rightEdge - 16 { applyOrigin(vp.origin + vp.visible * 0.02, width: w) }
        }
        switch d.kind {
        case .pan:
            let dx = v.translation.width
            if abs(dx) >= 3 { applyOrigin(d.o0 - Double(dx / vp.pps), width: w) }
        case .seek: model.scrub(to: viewport(width: w).t(atX: v.location.x))
        case .pendingStart:
            let snapped = snapTime(t, dur: dur, vp: vp)
            model.setPendingStart(snapped); model.seek(snapped)
        case .pendingEnd:
            let snapped = snapTime(t, dur: dur, vp: vp)
            model.setPendingEnd(snapped); model.seek(snapped)
        case .pendingBody:
            guard let p0 = d.pending0 else { return }
            let dt = t - d.t0
            let len = p0.length
            var ns = min(max(p0.start + dt, 0), max(model.timeline.timeMap.outputDuration - len, 0))
            ns = snapTime(ns, dur: dur, vp: vp)
            model.pendingCut = PendingCut(start: ns, end: ns + len, focused: p0.focused)
            model.seek(ns)
        case .cutStart, .cutEnd:
            guard let id = d.id else { return }
            let snapped = snapTime(t, dur: dur, vp: vp)
            model.moveCutEdge(id: id, isStart: d.kind == .cutStart, toOutput: snapped)
        case .clipStart, .clipEnd:
            guard let id = d.id else { return }
            let snapped = snapTime(t, dur: dur, vp: vp)
            model.trimClipEdge(id: id, isStart: d.kind == .clipStart, toOutput: snapped)
        case .seam:
            guard let id = d.id else { return }
            model.moveSeam(id: id, toOutput: t)
        case .move, .left, .right:
            guard let o = d.orig, let id = d.id else { return }
            let tm = model.timeline.timeMap, dt = t - d.t0
            let os = tm.output(atSource: o.start), oe = tm.output(atSource: o.end)
            let newStartOut: Double, newEndOut: Double
            switch d.kind {
            case .move:
                let len = oe - os, s = snapTime(min(max(os + dt, 0), dur - len), dur: dur, vp: vp)
                newStartOut = s; newEndOut = s + len
            case .left:
                newStartOut = snapTime(min(max(os + dt, 0), oe - 0.3), dur: dur, vp: vp)
                newEndOut = oe
            default:
                newStartOut = os
                newEndOut = snapTime(max(min(oe + dt, dur), os + 0.3), dur: dur, vp: vp)
            }
            let s = tm.source(atOutput: newStartOut), e = tm.source(atOutput: newEndOut)
            // Command path: reduce(.moveZoom) preserves origin->manual + effects.
            let ctx = ReduceContext(playhead: model.playhead, selection: id, duration: dur)
            model.edit(coalesce: true) { tl in _ = try? reduce(&tl, .moveZoom(id, start: s, end: e), ctx: ctx) }
        case .reorder:
            guard let id = d.id else { return }
            // Move the clip, then magneticNormalize reorders.
            let ctx = ReduceContext(playhead: model.playhead, selection: id, duration: dur)
            model.edit(coalesce: true) { tl in _ = try? reduce(&tl, .moveClip(id, start: t), ctx: ctx) }
        case .tapMove:
            guard let id = d.id, let tap = d.origTap else { return }
            let tm = model.timeline.timeMap
            model.moveTap(id: id, x: tap.x, y: tap.y, atSource: tm.source(atOutput: t))
        case .musicMove, .musicLeft, .musicRight:
            guard let id = d.id, let orig = musicDragOrigin else { return }
            let len = max(musicDuration(for: orig), 0.05)
            let full = musicDurations[id] ?? model.timeline.compositionDuration
            let ts = orig.trimStart ?? 0
            switch d.kind {
            case .musicMove:
                let newPlace = min(max(orig.placement + (t - d.t0), 0), max(model.timeline.compositionDuration - len, 0))
                model.updateMusicLane(id, placement: newPlace)
            case .musicRight:
                let maxLen = max(full - ts, 0.3)
                let newLen = min(max(snapTime(t, dur: dur, vp: vp) - orig.placement, 0.3), maxLen)
                model.updateMusicLane(id, trimDuration: newLen)
            case .musicLeft:
                let rightEdge = orig.placement + len
                let newPlace = min(max(snapTime(t, dur: dur, vp: vp), 0), rightEdge - 0.3)
                let shift = newPlace - orig.placement
                model.updateMusicLane(id, placement: newPlace, trimStart: max(0, ts + shift), trimDuration: rightEdge - newPlace)
            default:
                break
            }
        }
    }

    func stepClick(direction: Int) {
        let markers = outEvents().map(\.t).sorted()
        guard !markers.isEmpty else { return }
        let cur = model.playhead
        let target: Double?
        if direction > 0 { target = markers.first { $0 > cur + 0.001 } } else { target = markers.last { $0 < cur - 0.001 } }
        if let target { model.seek(target) }
    }
}
