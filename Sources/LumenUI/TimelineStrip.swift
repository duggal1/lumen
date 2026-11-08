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
    @State var hoveredCut: UUID?
    @State var hoveredCol: Int?   // event column under the pointer
    @State var scrubCol: Int?     // ghost line column
    @State var zoom: CGFloat = 1  // 1 = the default readable window
    @State var origin: Double = 0 // output second at the strip's left edge
    @State var panning = false

    struct Drag {
        enum Kind { case seek, move, left, right, reorder, tapMove, pan, pendingStart, pendingEnd, pendingBody, cutStart, cutEnd, clipStart, clipEnd, seam }
        var kind: Kind; var id: UUID?; var orig: ZoomSegment?; var origClip: TimelineClip?; var origTap: TapIndicator?
        var t0: Double; var o0: Double = 0
        var pending0: PendingCut?
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
            .overlay { pendingLayer(vp) }
            .overlay { seamLayer(vp) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { change($0, w) }.onEnded { _ in drag = nil })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                zoomBy(1 + CGFloat(value.magnification - 1) * 2, anchorX: value.startLocation.x, width: w)
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): setHover(at: p, width: w)
                case .ended:
                    hoveredZoom = nil; hoveredCol = nil; hoveredClip = nil; hoveredCut = nil; scrubCol = nil
                    NSCursor.arrow.set()
                }
            }
            .background(TimelineScrollCatcher(
                onScroll: { dx, dy, command in scroll(dx: dx, dy: dy, command: command, width: w) },
                onMagnify: { delta, x in zoomBy(1 + delta * 2, anchorX: x, width: w) }))
            .onChange(of: model.playhead) { _, t in follow(t, width: w) }
            .onChange(of: model.timelineFitRequest) { _, _ in
                // Fit-all: show the whole take at the minimum zoom.
                let dur = max(model.timeline.timeMap.outputDuration, 0.001)
                zoom = minZoom(width: w)
                origin = 0
                _ = dur
            }
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

}
