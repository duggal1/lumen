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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Timeline").accessibilityHint("Drag to seek. Drag a zoom segment to move or resize it.")
    }

    private func draw(_ c: inout GraphicsContext, _ size: CGSize) {
        let tl = model.timeline, tm = tl.timeMap, dur = max(tm.outputDuration, 0.001), w = size.width
        func x(_ t: Double) -> CGFloat { CGFloat(t / dur) * w }
        func fill(_ r: CGRect, _ col: Color) { c.fill(Path(r), with: .color(col), style: FillStyle(antialiased: false)) }
        // ruler
        let stepS = dur > 120 ? 30.0 : dur > 40 ? 10.0 : dur > 12 ? 5.0 : 1.0
        var t = 0.0
        while t <= dur {
            fill(CGRect(x: x(t).rounded(), y: 14, width: 1, height: 5), Tok.text2)
            c.draw(Text(String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text2),
                   at: CGPoint(x: x(t) + 4, y: 8), anchor: .leading)
            t += stepS
        }
        // zoom segments (stored in SOURCE time, drawn in OUTPUT time): auto = soft, manual = accent; selected = text-colored cap
        for z in tl.zoom {
            let zs = tm.output(atSource: z.start), ze = tm.output(atSource: z.end)
            guard ze > zs else { continue }
            let r = CGRect(x: x(zs), y: zoomLane.lowerBound, width: max(x(ze) - x(zs), 4), height: zoomLane.upperBound - zoomLane.lowerBound)
            fill(r, z.origin == .manual ? Tok.accent : Tok.accentSoft)
            fill(CGRect(x: r.minX, y: r.minY, width: 2, height: r.height), z.origin == .manual ? Tok.accentPressed : Tok.accentText)
            fill(CGRect(x: r.maxX - 2, y: r.minY, width: 2, height: r.height), z.origin == .manual ? Tok.accentPressed : Tok.accentText)
            if z.id == model.selection { fill(CGRect(x: r.minX, y: r.maxY - 3, width: r.width, height: 3), Tok.text) }
            c.draw(Text(String(format: "%.1f×", z.scale)).font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(z.origin == .manual ? Tok.onAccent : Tok.accentText), at: CGPoint(x: r.minX + 6, y: r.midY), anchor: .leading)
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
        if let d = tl.derived { for k in d.clicks { fill(CGRect(x: x(k.t) - 1, y: 84, width: 2, height: 2), Tok.text2) } }
    }

    /// Smooth playhead line: it reads the clock at display rate, while the
    /// heavy strip canvas (waveform + segments) redraws only at ~12 Hz.
    private struct PlayheadLine: View {
        let model: EditorModel
        var body: some View {
            let paused = model.playhead
            TimelineView(.animation(paused: !model.isPlaying)) { _ in
                Canvas { context, size in
                    let t = model.isPlaying ? model.clock.time(at: HostClock.now()) : paused
                    let x = (CGFloat(t / max(model.duration, 0.001)) * size.width).rounded()
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
