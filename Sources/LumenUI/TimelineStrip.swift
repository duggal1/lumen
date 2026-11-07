import SwiftUI
import LumenCore
import LumenProject
import LumenDirector

struct TimelineStrip: View {
    let model: EditorModel
    @State private var drag: Drag?
    private struct Drag { enum Kind { case seek, move, left, right }; var kind: Kind; var id: UUID?; var orig: ZoomSegment?; var t0: Double }
    private let zoomLane: ClosedRange<CGFloat> = 26...58, rampLane: ClosedRange<CGFloat> = 62...80

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, size in draw(&ctx, size) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { change($0, g.size.width) }.onEnded { _ in drag = nil })
        }
        .frame(height: 128)
        .overlay { PlayheadLine(model: model) }
        .background(RoundedRectangle(cornerRadius: 12).fill(Tok.surface))
        .accessibilityLabel("Timeline").accessibilityHint("Drag to seek. Drag a zoom segment to move or resize it.")
    }

    private func draw(_ c: inout GraphicsContext, _ size: CGSize) {
        let tl = model.timeline, tm = tl.timeMap, dur = max(tm.outputDuration, 0.001), w = size.width
        func x(_ t: Double) -> CGFloat { CGFloat(t / dur) * w }
        func fill(_ r: CGRect, _ col: Color) { c.fill(Path(r), with: .color(col), style: FillStyle(antialiased: false)) }
        // Ruler ticks adapt to clip length (sub-second for short clips).
        // Labels stay inside the strip: the last tick anchors trailing.
        let stepS = dur > 120 ? 30.0 : dur > 40 ? 10.0 : dur > 12 ? 5.0 : dur > 3 ? 0.5 : 0.25
        var t = 0.0
        while t <= dur {
            let tx = x(t).rounded()
            fill(CGRect(x: tx, y: 14, width: 1, height: 5), Tok.text2)
            let label = stepS < 1 ? String(format: "%.2f", t) : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
            let isLast = t + stepS > dur
            c.draw(Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text2),
                   at: CGPoint(x: isLast ? tx - 4 : tx + 4, y: 8), anchor: isLast ? .trailing : .leading)
            t += stepS
        }
        // Zoom lane empty state.
        if tl.zoom.isEmpty {
            c.draw(Text("No zoom segments — Add zoom to focus a moment.")
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text2),
                   at: CGPoint(x: 6, y: zoomLane.upperBound - 8), anchor: .leading)
        }
        // zoom segments (stored in SOURCE time, drawn in OUTPUT time): auto = soft, manual = accent; selected = text-colored cap
        for z in tl.zoom {
            let zs = tm.output(atSource: z.start), ze = tm.output(atSource: z.end)
            guard ze > zs else { continue }
            let r = CGRect(x: x(zs), y: zoomLane.lowerBound, width: max(x(ze) - x(zs), 4), height: zoomLane.upperBound - zoomLane.lowerBound)
            // Auto zooms are violet (Screen Studio), manual zooms stay orange.
            fill(r, z.origin == .manual ? Tok.accent : Tok.zoomSoft)
            // Visible drag handles: 6 pt opaque grips (not 2 pt caps).
            let handleCol = z.origin == .manual ? Tok.accentPressed : Tok.zoom
            fill(CGRect(x: r.minX, y: r.minY, width: 6, height: r.height), handleCol)
            fill(CGRect(x: r.maxX - 6, y: r.minY, width: 6, height: r.height), handleCol)
            if z.id == model.selection { fill(CGRect(x: r.minX, y: r.maxY - 3, width: r.width, height: 3), Tok.text) }
            c.draw(Text(String(format: "%.1f×", z.scale)).font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(z.origin == .manual ? Tok.onAccent : Tok.zoomText), at: CGPoint(x: r.minX + 10, y: r.midY), anchor: .leading)
        }
        // speed ramps (source -> output)
        for r in tm.ramps {
            let a = x(tm.output(atSource: r.start)), b = x(tm.output(atSource: r.end))
            fill(CGRect(x: a, y: rampLane.lowerBound, width: max(b - a, 3), height: 14), Tok.controlPressed)
            c.draw(Text(String(format: "%.0f×", r.speed)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text2), at: CGPoint(x: a + 4, y: 69), anchor: .leading)
        }
        // cuts: thin accent ticks at the join
        for cut in tm.cuts { fill(CGRect(x: x(tm.output(atSource: cut.start)) - 1, y: 62, width: 2, height: 18), Tok.statusBad) }
        // waveform tape: 4 pt cells, 2 pt gap, played = accent body
        let wave = model.session.waveform, ph = x(model.playhead)
        if !wave.isEmpty {
            var cx: CGFloat = 0
            while cx < w {
                let src = tm.source(atOutput: Double(cx / w) * dur), i = min(max(Int(src * 100), 0), wave.count - 1)
                let rows = Int(wave[i].squareRoot() * 3.99)
                for k in -rows...rows { fill(CGRect(x: cx, y: 104 + CGFloat(k) * 4 - 2, width: 4, height: 3), cx < ph ? Ramp.o[3] : Tok.controlPressed) }
                cx += 6
            }
        }
        // Clicks are editable events, not barely visible 2 px dots.
        // Recorded clicks are orange; manual taps (Tools > Add tap) are
        // fuchsia so the two are never confused on the timeline.
        // Unified dedupe: a Click and a Tap at the same output time share
        // one chip (Tap wins) or a ×N cluster; never two overprints.
        func badge(at center: CGFloat, label: String, soft: Color, ink: Color) {
            let w: CGFloat = label.contains("×") ? 44 : 40
            let rect = CGRect(x: center - w / 2, y: 82, width: w, height: 18)
            c.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(soft))
            c.draw(Text(label).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ink),
                   at: CGPoint(x: rect.midX, y: rect.midY))
        }
        if let d = tl.derived {
            var events: [(t: Double, label: String, soft: Color, ink: Color)] = d.clicks.map { (t: $0.t, label: "Click", soft: Tok.accentSoft, ink: Tok.accentText) }
            events += tl.overlays.taps.map { (t: tm.output(atSource: $0.t), label: "Tap", soft: Tok.tapSoft, ink: Tok.tapText) }
            events.sort { $0.t < $1.t }
            var lastBadgeX: CGFloat = -100
            var pending: [(t: Double, label: String, soft: Color, ink: Color)] = []
            var pendingCenter: CGFloat = 0
            func flushPending() {
                if pending.isEmpty { return }
                let label = pending.count > 1 ? "×\(pending.count)" : pending[0].label
                // Tap wins colour when a cluster mixes Click + Tap.
                let tap = pending.first { $0.label == "Tap" }
                let soft = tap?.soft ?? pending[0].soft
                let ink = tap?.ink ?? pending[0].ink
                badge(at: pendingCenter, label: label, soft: soft, ink: ink)
                lastBadgeX = pendingCenter
                pending.removeAll()
            }
            for ev in events {
                let center = max(20, min(x(ev.t), w - 20))
                if !pending.isEmpty, center - lastBadgeX < 44, center - pendingCenter < 44 {
                    // Same chip width: merge into a cluster (Tap wins colour).
                    pending.append(ev)
                    continue
                }
                flushPending()
                // Chip must clear the previous chip by a full chip width.
                if center - lastBadgeX < 44 { continue }
                pending = [ev]; pendingCenter = center
            }
            flushPending()
        }
    }

    /// Smooth playhead line: it reads the clock at display rate, while the
    /// heavy strip canvas (waveform + segments) redraws only at ~12 Hz.
    /// Inset so the 2 pt line never clips at the strip edge.
    private struct PlayheadLine: View {
        let model: EditorModel
        var body: some View {
            let paused = model.playhead
            TimelineView(.animation(paused: !model.isPlaying)) { _ in
                Canvas { context, size in
                    let t = model.isPlaying ? model.clock.time(at: HostClock.now()) : paused
                    let x = min(max((CGFloat(t / max(model.duration, 0.001)) * size.width).rounded(), 2), size.width - 2)
                    context.fill(Path(CGRect(x: x - 1, y: 4, width: 2, height: size.height - 8)),
                                 with: .color(Tok.text), style: FillStyle(antialiased: false))
                }
            }.allowsHitTesting(false)
        }
    }

    private func hit(_ p: CGPoint, _ w: CGFloat) -> Drag {
        let tl = model.timeline, tm = tl.timeMap, dur = tm.outputDuration
        func x(_ t: Double) -> CGFloat { CGFloat(t / max(dur, 0.001)) * w }
        if zoomLane.contains(p.y) {
            for z in tl.zoom.reversed() {
                let a = x(tm.output(atSource: z.start)), b = x(tm.output(atSource: z.end))
                if abs(p.x - a) < 7 { return Drag(kind: .left, id: z.id, orig: z, t0: Double(p.x / w) * dur) }
                if abs(p.x - b) < 7 { return Drag(kind: .right, id: z.id, orig: z, t0: Double(p.x / w) * dur) }
                if p.x > a, p.x < b { return Drag(kind: .move, id: z.id, orig: z, t0: Double(p.x / w) * dur) }
            }
        }
        return Drag(kind: .seek, id: nil, orig: nil, t0: 0)
    }

    private func change(_ v: DragGesture.Value, _ w: CGFloat) {
        let dur = model.timeline.timeMap.outputDuration, t = min(max(Double(v.location.x / w) * dur, 0), dur)
        if drag == nil { drag = hit(v.startLocation, w); model.selection = drag?.id }
        guard let d = drag else { return }
        switch d.kind {
        case .seek: model.seek(t)
        case .move, .left, .right:
            guard let o = d.orig, let id = d.id else { return }
            model.edit(coalesce: true) { tl in
                guard let i = tl.zoom.firstIndex(where: { $0.id == id }) else { return }
                let tm = tl.timeMap, dt = t - d.t0
                let os = tm.output(atSource: o.start), oe = tm.output(atSource: o.end)
                switch d.kind {
                case .move:
                    let len = oe - os, s = min(max(os + dt, 0), dur - len)
                    tl.zoom[i].start = tm.source(atOutput: s); tl.zoom[i].end = tm.source(atOutput: s + len)
                case .left: tl.zoom[i].start = tm.source(atOutput: min(max(os + dt, 0), oe - 0.3))
                default: tl.zoom[i].end = tm.source(atOutput: max(min(oe + dt, dur), os + 0.3))
                }
                tl.zoom[i].origin = .manual
            }
        }
    }
}
