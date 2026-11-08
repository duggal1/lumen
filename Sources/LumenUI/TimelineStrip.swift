import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenDirector

/// The timeline as five strips on one column lattice. Chrome is flat and 1-bit; orange is data.
struct TimelineStrip: View {
    let model: EditorModel
    @State var drag: Drag?
    @State var hoveredZoom: UUID?
    @State var hoveredClip: UUID?
    @State var hoveredCol: Int?   // event column under the pointer
    @State var scrubCol: Int?     // ghost line column

    struct Drag { enum Kind { case seek, move, left, right, reorder, tapMove }; var kind: Kind; var id: UUID?; var orig: ZoomSegment?; var origClip: TimelineClip?; var origTap: TapIndicator?; var t0: Double }
    struct Marker { var t: Double; var kind: String; var isTap: Bool }

    var body: some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                rulerLane()
                clipLane()
                zoomLane()
                eventsLane()
                audioLane()
            }
            .overlay { threadLayer() }
            .overlay { GhostLine(col: drag == nil ? scrubCol : nil) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { change($0, g.size.width) }.onEnded { _ in drag = nil })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): setHover(at: p, width: g.size.width)
                case .ended:
                    hoveredZoom = nil; hoveredCol = nil; hoveredClip = nil; scrubCol = nil
                    NSCursor.arrow.set()
                }
            }
            .onKeyPress("[") { stepClick(direction: -1); return .handled }
            .onKeyPress("]") { stepClick(direction: 1); return .handled }
            .focusable()
            .focusEffectDisabled()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline")
            .accessibilityHint("Drag to seek. Drag a zoom segment to move or resize it. Bracket keys step between clicks.")
            .accessibilityValue(eventsSummary())
        }
        .frame(height: Lanes.total)
        .overlay { PlayheadLine(model: model) }
        .background(RoundedRectangle(cornerRadius: 16).fill(Tok.surface))
    }

    // MARK: - Shared model reads

    func outEvents() -> [Marker] {
        let tl = model.timeline, tm = tl.timeMap
        var markers: [Marker] = []
        if let d = tl.derived {
            markers += d.clicks.map { Marker(t: $0.t, kind: "Click", isTap: false) }
        }
        markers += tl.overlays.taps.map { Marker(t: tm.output(atSource: $0.t), kind: "Tap", isTap: true) }
        return markers.sorted { $0.t < $1.t }
    }
    func clickCount() -> Int { outEvents().count }
    func eventsSummary() -> String { "\(clickCount()) clicks" }
    func keyOutputs() -> [Double] {
        let tm = model.timeline.timeMap
        return model.session.input.events
            .filter { $0.kind == .keyDown && !tm.isCut($0.t) }
            .map { tm.output(atSource: $0.t) }
            .sorted()
    }
    func autoZoomSpansOut() -> [(start: Double, end: Double)] {
        let tm = model.timeline.timeMap
        return model.timeline.zoom.filter { $0.origin == .auto }
            .map { (start: tm.output(atSource: $0.start), end: tm.output(atSource: $0.end)) }
    }
    /// The zoom the pointer is on, else the selected one.
    func focusZoom() -> ZoomSegment? {
        guard let id = hoveredZoom ?? model.selection else { return nil }
        return model.timeline.zoom.first { $0.id == id }
    }
    func focusSpan() -> (start: Double, end: Double)? {
        guard let z = focusZoom() else { return nil }
        let tm = model.timeline.timeMap
        return (start: tm.output(atSource: z.start), end: tm.output(atSource: z.end))
    }

    // MARK: - Overlays

    struct PlayheadLine: View {
        let model: EditorModel
        @Environment(\.displayScale) private var displayScale
        var body: some View {
            let paused = model.playhead
            TimelineView(.animation(paused: !model.isPlaying)) { _ in
                Canvas { context, size in
                    let lat = TimelineStrip.Lattice(width: size.width)
                    let s = displayScale > 0 ? displayScale : 2
                    let t = model.isPlaying ? model.clock.time(at: HostClock.now()) : paused
                    let px = (lat.x(t, model.duration) * s).rounded() / s
                    context.fillCells(Path(CGRect(x: px - 1, y: 4, width: 2, height: size.height - 8)), Tok.text)
                }
            }.allowsHitTesting(false)
        }
    }

    /// Ghost scrub line: 1x2 dashes on the lattice column under the pointer.
    struct GhostLine: View {
        let col: Int?
        var body: some View {
            Canvas { c, size in
                guard let col else { return }
                let lat = TimelineStrip.Lattice(width: size.width)
                var p = Path()
                var y = TimelineStrip.Lanes.ruler
                while y + 2 <= size.height - 4 {
                    p.addRect(CGRect(x: lat.x(col: col) + 1, y: y, width: 1, height: 2))
                    y += 4
                }
                c.fillCells(p, Tok.text2)
            }.allowsHitTesting(false)
        }
    }

    /// Cause threads: dotted line from the focused zoom down to the clicks inside it.
    @ViewBuilder func threadLayer() -> some View {
        Canvas { c, size in
            guard let z = focusZoom() else { return }
            let lat = TimelineStrip.Lattice(width: size.width)
            let tm = model.timeline.timeMap, dur = max(tm.outputDuration, 0.001)
            let zs = tm.output(atSource: z.start), ze = tm.output(atSource: z.end)
            let top = TimelineStrip.Lanes.zoom + TimelineStrip.Lanes.mid + TimelineGeometry.zoomHeights(scale: z.scale).cap / 2
            let bottom = TimelineStrip.Lanes.events + 8
            var p = Path()
            for m in outEvents() where !m.isTap && m.t >= zs && m.t < ze {
                let x = lat.x(col: lat.col(m.t, dur)) + 1
                var y = top + 2
                while y + 2 <= bottom - 2 {
                    p.addRect(CGRect(x: x, y: y, width: 1, height: 2))
                    y += 4
                }
            }
            c.fillCells(p, StripInk.hot)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Hover

    func setHover(at p: CGPoint, width: CGFloat) {
        let lat = TimelineStrip.Lattice(width: width)
        let sc = lat.col(atX: p.x)
        if scrubCol != sc { scrubCol = sc }
        let tm = model.timeline.timeMap, dur = max(tm.outputDuration, 0.001)
        var clip: UUID? = nil, zoom: UUID? = nil, col: Int? = nil
        var cursor = NSCursor.arrow
        if p.y >= TimelineStrip.Lanes.clip && p.y < TimelineStrip.Lanes.zoom {
            let cd = max(model.timeline.compositionDuration, 0.001)
            for k in model.timeline.clips.reversed() {
                if p.x >= lat.x(k.start, cd) - 1 && p.x <= lat.x(k.end, cd) + 1 { clip = k.id; break }
            }
        } else if p.y >= TimelineStrip.Lanes.zoom && p.y < TimelineStrip.Lanes.events {
            for z in model.timeline.zoom.reversed() {
                let a = lat.x(tm.output(atSource: z.start), dur), b = lat.x(tm.output(atSource: z.end), dur)
                if p.x >= a - 7 && p.x <= b + 7 {
                    zoom = z.id
                    if abs(p.x - a) < 7 || abs(p.x - b) < 7 { cursor = .resizeLeftRight }
                    break
                }
            }
        } else if p.y >= TimelineStrip.Lanes.events && p.y < TimelineStrip.Lanes.audio {
            var bestD: CGFloat = 6
            for m in outEvents() {
                let d = abs(lat.cx(m.t, dur) - p.x)
                if d < bestD { bestD = d; col = lat.col(m.t, dur) }
            }
            if col != nil { cursor = .pointingHand }
        }
        if hoveredClip != clip { hoveredClip = clip }
        if hoveredZoom != zoom { hoveredZoom = zoom }
        if hoveredCol != col { hoveredCol = col }
        cursor.set()
    }

    // MARK: - Hit, drag (command path preserved)

    func hit(_ p: CGPoint, _ w: CGFloat) -> Drag {
        let lat = TimelineStrip.Lattice(width: w)
        let tm = model.timeline.timeMap, dur = max(tm.outputDuration, 0.001)
        if p.y >= TimelineStrip.Lanes.clip && p.y < TimelineStrip.Lanes.zoom {
            let cd = max(model.timeline.compositionDuration, 0.001)
            for clip in model.timeline.clips.reversed() {
                let a = lat.x(clip.start, cd), b = lat.x(clip.end, cd)
                if p.x > a, p.x < b { return Drag(kind: .reorder, id: clip.id, origClip: clip, t0: clip.start) }
            }
        }
        if p.y >= TimelineStrip.Lanes.zoom && p.y < TimelineStrip.Lanes.events {
            let t0 = lat.t(atX: p.x, dur)
            for z in model.timeline.zoom.reversed() {
                let a = lat.x(tm.output(atSource: z.start), dur), b = lat.x(tm.output(atSource: z.end), dur)
                if abs(p.x - a) < 7 { return Drag(kind: .left, id: z.id, orig: z, t0: t0) }
                if abs(p.x - b) < 7 { return Drag(kind: .right, id: z.id, orig: z, t0: t0) }
                if p.x > a, p.x < b { return Drag(kind: .move, id: z.id, orig: z, t0: t0) }
            }
        }
        if p.y >= TimelineStrip.Lanes.events && p.y < TimelineStrip.Lanes.audio {
            for tap in model.timeline.overlays.taps.reversed() {
                let tx = lat.cx(tm.output(atSource: tap.t), dur)
                if abs(p.x - tx) < 8 { return Drag(kind: .tapMove, id: tap.id, origTap: tap, t0: lat.t(atX: p.x, dur)) }
            }
        }
        return Drag(kind: .seek, id: nil, orig: nil, t0: 0)
    }

    func snapTime(_ t: Double, dur: Double, lat: TimelineStrip.Lattice) -> Double {
        let tol = 6 * dur / max(Double(lat.span), 1)
        var best: Double? = nil, bestD = tol
        for m in outEvents() {
            let d = abs(m.t - t)
            if d < bestD { bestD = d; best = m.t }
        }
        return best ?? t
    }

    func change(_ v: DragGesture.Value, _ w: CGFloat) {
        let lat = TimelineStrip.Lattice(width: w)
        let dur = model.timeline.compositionDuration, t = lat.t(atX: v.location.x, dur)
        if drag == nil {
            drag = hit(v.startLocation, w)
            model.selection = drag?.id
            // Clicking a marker seeks to it exactly.
            if drag?.kind == .seek, v.startLocation.y >= TimelineStrip.Lanes.events, v.startLocation.y < TimelineStrip.Lanes.audio {
                var bestT: Double? = nil, bestD: CGFloat = 6
                for m in outEvents() {
                    let d = abs(lat.cx(m.t, dur) - v.startLocation.x)
                    if d < bestD { bestD = d; bestT = m.t }
                }
                if let bt = bestT { model.seek(bt); return }
            }
        }
        guard let d = drag else { return }
        switch d.kind {
        case .seek: model.seek(t)
        case .move, .left, .right:
            guard let o = d.orig, let id = d.id else { return }
            let tm = model.timeline.timeMap, dt = t - d.t0
            let os = tm.output(atSource: o.start), oe = tm.output(atSource: o.end)
            let newStartOut: Double, newEndOut: Double
            switch d.kind {
            case .move:
                let len = oe - os, s = snapTime(min(max(os + dt, 0), dur - len), dur: dur, lat: lat)
                newStartOut = s; newEndOut = s + len
            case .left:
                newStartOut = snapTime(min(max(os + dt, 0), oe - 0.3), dur: dur, lat: lat)
                newEndOut = oe
            default:
                newStartOut = os
                newEndOut = snapTime(max(min(oe + dt, dur), os + 0.3), dur: dur, lat: lat)
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
