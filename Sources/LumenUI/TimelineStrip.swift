import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenDirector

/// The timeline as five strips on one column lattice. Chrome is flat and 1-bit;
/// hue marks the data role: orange audio, purple zoom, fuchsia clicks, blue
/// clips, green imports, rose cuts.
///
/// The strip is a fixed-size window over the output timeline. Trackpad
/// horizontal scroll pans, command-scroll or pinch zooms around the pointer,
/// and dragging the ruler pans. Playback keeps the head in view.
struct TimelineStrip: View {
    let model: EditorModel
    @State var drag: Drag?
    @State var hoveredZoom: UUID?
    @State var hoveredClip: UUID?
    @State var hoveredCol: Int?   // event column under the pointer
    @State var scrubCol: Int?     // ghost line column
    @State var zoom: CGFloat = 1  // 1 = the default readable window
    @State var origin: Double = 0 // output second at the strip's left edge
    @State var panning = false

    struct Drag {
        enum Kind { case seek, move, left, right, reorder, tapMove, pan }
        var kind: Kind; var id: UUID?; var orig: ZoomSegment?; var origClip: TimelineClip?; var origTap: TapIndicator?
        var t0: Double; var o0: Double = 0
    }
    struct Marker { var t: Double; var kind: String; var isTap: Bool }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let vp = viewport(width: w)
            VStack(spacing: 0) {
                rulerLane(vp)
                clipLane(vp)
                zoomLane(vp)
                eventsLane(vp)
                audioLane(vp)
            }
            .overlay { threadLayer(vp) }
            .overlay { GhostLine(vp: vp, col: drag == nil ? scrubCol : nil) }
            .overlay { PlayheadLine(model: model, vp: vp) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { change($0, w) }.onEnded { _ in drag = nil })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                zoomBy(1 + CGFloat(value.magnification - 1) * 2, anchorX: value.startLocation.x, width: w)
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): setHover(at: p, width: w)
                case .ended:
                    hoveredZoom = nil; hoveredCol = nil; hoveredClip = nil; scrubCol = nil
                    NSCursor.arrow.set()
                }
            }
            .background(TimelineScrollCatcher(
                onScroll: { dx, dy, command in scroll(dx: dx, dy: dy, command: command, width: w) },
                onMagnify: { delta, x in zoomBy(1 + delta * 2, anchorX: x, width: w) }))
            .onChange(of: model.playhead) { _, t in follow(t, width: w) }
            .onKeyPress("[") { stepClick(direction: -1); return .handled }
            .onKeyPress("]") { stepClick(direction: 1); return .handled }
            .focusable()
            .focusEffectDisabled()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline")
            .accessibilityHint("Scroll sideways to pan. Pinch or hold Command and scroll to zoom. Drag a zoom segment to move or resize it.")
            .accessibilityValue(eventsSummary())
        }
        .frame(height: Lanes.total)
        .background(RoundedRectangle(cornerRadius: 16).fill(Tok.surface))
    }

    // MARK: - Viewport

    /// 30 seconds is the widest default window: a 5-minute take stays readable
    /// and panning (not crushing) reveals the rest. Short takes fit whole.
    static let defaultWindow: Double = 30

    func viewport(width: CGFloat) -> Viewport {
        let lat = Lattice(width: width)
        let dur = max(model.timeline.timeMap.outputDuration, 0.001)
        let pps = lat.span / CGFloat(min(dur, Self.defaultWindow)) * zoom
        let visible = Double(lat.span / max(pps, 0.001))
        return Viewport(lattice: lat, pps: pps, origin: min(max(origin, 0), max(0, dur - visible)), duration: dur)
    }

    func minZoom(width: CGFloat) -> CGFloat {
        let dur = max(model.timeline.timeMap.outputDuration, 0.001)
        return min(1, CGFloat(Self.defaultWindow / dur))
    }

    func applyOrigin(_ o: Double, width: CGFloat) {
        let vp = viewport(width: width)
        origin = vp.clampOrigin(o)
    }

    /// Trackpad pan. Horizontal wins when both axes are present; a plain
    /// vertical wheel also pans time, which is what a mouse with one wheel
    /// expects over a timeline.
    func scroll(dx: CGFloat, dy: CGFloat, command: Bool, width: CGFloat) {
        let vp = viewport(width: width)
        if command {
            zoomBy(1 - dy * 0.012, anchorX: width / 2, width: width)
            return
        }
        let delta = abs(dx) >= abs(dy) ? dx : dy
        guard abs(delta) > 0.001 else { return }
        applyOrigin(vp.origin - Double(delta / vp.pps), width: width)
    }

    func zoomBy(_ factor: CGFloat, anchorX: CGFloat, width: CGFloat) {
        let before = viewport(width: width)
        let anchorTime = before.t(atX: min(max(anchorX, before.lattice.x0), width - Lattice.inset))
        let lo = minZoom(width: width)
        zoom = min(max(zoom * factor, lo), 12)
        let after = viewport(width: width)
        let o = anchorTime - Double((anchorX - after.lattice.x0) / after.pps)
        applyOrigin(o, width: width)
    }

    /// Keep the head in view while playing: nudge only when it crosses 80% or
    /// leaves the left edge, so the strip does not crawl every frame.
    func follow(_ t: Double, width: CGFloat) {
        guard model.isPlaying else { return }
        let vp = viewport(width: width)
        let x = vp.x(t)
        let left = vp.lattice.x0
        if x > left + vp.span * 0.8 || x < left {
            applyOrigin(t - vp.visible * 0.2, width: width)
        }
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
        let vp: TimelineStrip.Viewport
        @Environment(\.displayScale) private var displayScale
        var body: some View {
            // Read both sources in body, not inside Canvas: observation only
            // tracks body reads, and the line must move on seek as well as play.
            let playing = model.isPlaying
            let paused = model.playhead
            TimelineView(.animation(paused: !playing)) { _ in
                Canvas { context, size in
                    let s = displayScale > 0 ? displayScale : 2
                    let t = playing ? model.clock.time(at: HostClock.now()) : paused
                    let x = vp.x(t)
                    guard x >= 0, x <= size.width else { return }
                    let px = (x * s).rounded() / s
                    context.fillCells(Path(CGRect(x: px - 1, y: 4, width: 2, height: size.height - 8)), Tok.text)
                }
            }
            // Restart the display schedule on play/pause; a paused schedule that
            // is merely unpaused can keep its last frame on macOS.
            .id(playing)
            .allowsHitTesting(false)
        }
    }

    /// Ghost scrub line: 1x2 dashes on the lattice column under the pointer.
    struct GhostLine: View {
        let vp: TimelineStrip.Viewport
        let col: Int?
        var body: some View {
            Canvas { c, size in
                guard let col else { return }
                var p = Path()
                var y = TimelineStrip.Lanes.ruler
                while y + 2 <= size.height - 4 {
                    p.addRect(CGRect(x: vp.lattice.x(col: col) + 1, y: y, width: 1, height: 2))
                    y += 4
                }
                c.fillCells(p, Tok.text2)
            }.allowsHitTesting(false)
        }
    }

    /// Cause threads: dotted line from the focused zoom down to the clicks inside it.
    @ViewBuilder func threadLayer(_ vp: Viewport) -> some View {
        Canvas { c, size in
            guard let z = focusZoom() else { return }
            let tm = model.timeline.timeMap
            let zs = tm.output(atSource: z.start), ze = tm.output(atSource: z.end)
            let top = TimelineStrip.Lanes.zoom + TimelineStrip.Lanes.mid + TimelineGeometry.zoomHeights(scale: z.scale).cap / 2
            let bottom = TimelineStrip.Lanes.events + 8
            var p = Path()
            for m in outEvents() where !m.isTap && m.t >= zs && m.t < ze {
                guard m.t >= vp.origin - 0.2, m.t <= vp.origin + vp.visible + 0.2 else { continue }
                let x = vp.x(m.t) + 1
                var y = top + 2
                while y + 2 <= bottom - 2 {
                    p.addRect(CGRect(x: x, y: y, width: 1, height: 2))
                    y += 4
                }
            }
            c.fillCells(p, StripInk.zoom)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Hover

    func setHover(at p: CGPoint, width: CGFloat) {
        let vp = viewport(width: width)
        let lat = vp.lattice
        let sc = lat.col(atX: p.x)
        if scrubCol != sc { scrubCol = sc }
        var clip: UUID? = nil, zoomID: UUID? = nil, col: Int? = nil
        var cursor = NSCursor.arrow
        if p.y < TimelineStrip.Lanes.ruler {
            cursor = .openHand
        } else if p.y >= TimelineStrip.Lanes.clip && p.y < TimelineStrip.Lanes.zoom {
            for k in model.timeline.clips.reversed() {
                if p.x >= vp.x(k.start) - 1 && p.x <= vp.x(k.end) + 1 { clip = k.id; break }
            }
        } else if p.y >= TimelineStrip.Lanes.zoom && p.y < TimelineStrip.Lanes.events {
            for z in model.timeline.zoom.reversed() {
                let tm = model.timeline.timeMap
                let a = vp.x(tm.output(atSource: z.start)), b = vp.x(tm.output(atSource: z.end))
                if p.x >= a - 7 && p.x <= b + 7 {
                    zoomID = z.id
                    if abs(p.x - a) < 7 || abs(p.x - b) < 7 { cursor = .resizeLeftRight }
                    break
                }
            }
        } else if p.y >= TimelineStrip.Lanes.events && p.y < TimelineStrip.Lanes.audio {
            var bestD: CGFloat = 6
            for m in outEvents() {
                let d = abs(vp.cx(m.t) - p.x)
                if d < bestD { bestD = d; col = vp.col(m.t) }
            }
            if col != nil { cursor = .pointingHand }
        }
        if hoveredClip != clip { hoveredClip = clip }
        if hoveredZoom != zoomID { hoveredZoom = zoomID }
        if hoveredCol != col { hoveredCol = col }
        cursor.set()
    }

    // MARK: - Hit, drag (command path preserved)

    func hit(_ p: CGPoint, _ w: CGFloat) -> Drag {
        let vp = viewport(width: w)
        if p.y < TimelineStrip.Lanes.ruler {
            return Drag(kind: .pan, id: nil, orig: nil, origClip: nil, origTap: nil, t0: 0, o0: vp.origin)
        }
        if p.y >= TimelineStrip.Lanes.clip && p.y < TimelineStrip.Lanes.zoom {
            for clip in model.timeline.clips.reversed() {
                let a = vp.x(clip.start), b = vp.x(clip.end)
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
        return Drag(kind: .seek, id: nil, orig: nil, origClip: nil, origTap: nil, t0: 0)
    }

    func snapTime(_ t: Double, dur: Double, vp: Viewport) -> Double {
        let tol = 6 / max(Double(vp.pps), 0.001)
        var best: Double? = nil, bestD = tol
        for m in outEvents() {
            let d = abs(m.t - t)
            if d < bestD { bestD = d; best = m.t }
        }
        return best ?? t
    }

    func change(_ v: DragGesture.Value, _ w: CGFloat) {
        let vp = viewport(width: w)
        let dur = model.timeline.compositionDuration, t = vp.t(atX: v.location.x)
        if drag == nil {
            drag = hit(v.startLocation, w)
            model.selection = drag?.id
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
        switch d.kind {
        case .pan:
            let dx = v.location.x - v.startLocation.x
            applyOrigin(d.o0 - Double(dx / vp.pps), width: w)
        case .seek: model.seek(vp.t(atX: v.location.x))
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

/// Local scroll monitor: pan and zoom over the strip without stealing clicks.
/// Trackpad deltas arrive at display rate with the system's own momentum, so
/// the strip moves the exact distance the fingers did.
struct TimelineScrollCatcher: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat, Bool) -> Void
    var onMagnify: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = Catcher()
        v.onScroll = onScroll
        v.onMagnify = onMagnify
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let c = v as? Catcher else { return }
        c.onScroll = onScroll
        c.onMagnify = onMagnify
    }

    final class Catcher: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
        var onMagnify: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let w = self.window, event.window === w else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                switch event.type {
                case .scrollWheel:
                    self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, event.modifierFlags.contains(.command))
                    return nil
                case .magnify:
                    self.onMagnify?(event.magnification, p.x)
                    return nil
                default:
                    return event
                }
            }
        }

        deinit { removeMonitor() }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
