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
        .frame(height: 128).background(RoundedRectangle(cornerRadius: 12).fill(Tok.surface))
        .accessibilityLabel("Timeline").accessibilityHint("Drag to seek. Drag a zoom segment to move or resize it.")
    }

    private func draw(_ c: inout GraphicsContext, _ size: CGSize) {
        let tl = model.timeline, dur = max(tl.timeMap.outputDuration, 0.001), w = size.width
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
        // zoom segments: auto = soft, manual = accent; selected = text-colored cap
        for z in tl.zoom {
            let r = CGRect(x: x(z.start), y: zoomLane.lowerBound, width: max(x(z.end) - x(z.start), 4), height: zoomLane.upperBound - zoomLane.lowerBound)
            fill(r, z.origin == .manual ? Tok.accent : Tok.accentSoft)
            fill(CGRect(x: r.minX, y: r.minY, width: 2, height: r.height), z.origin == .manual ? Tok.accentPressed : Tok.accentText)
            fill(CGRect(x: r.maxX - 2, y: r.minY, width: 2, height: r.height), z.origin == .manual ? Tok.accentPressed : Tok.accentText)
            if z.id == model.selection { fill(CGRect(x: r.minX, y: r.maxY - 3, width: r.width, height: 3), Tok.text) }
            c.draw(Text(String(format: "%.1f×", z.scale)).font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(z.origin == .manual ? Tok.onAccent : Tok.accentText), at: CGPoint(x: r.minX + 6, y: r.midY), anchor: .leading)
        }
        // speed ramps (source -> output)
        for r in tl.timeMap.ramps {
            let a = x(tl.timeMap.output(atSource: r.start)), b = x(tl.timeMap.output(atSource: r.end))
            fill(CGRect(x: a, y: rampLane.lowerBound, width: max(b - a, 3), height: 14), Tok.controlPressed)
            c.draw(Text(String(format: "%.0f×", r.speed)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text2), at: CGPoint(x: a + 4, y: 69), anchor: .leading)
        }
        // waveform tape: 4 pt cells, 2 pt gap, played = accent body
        let wave = model.session.waveform, ph = x(model.playhead)
        if !wave.isEmpty {
            var cx: CGFloat = 0
            while cx < w {
                let src = tl.timeMap.source(atOutput: Double(cx / w) * dur), i = min(max(Int(src * 100), 0), wave.count - 1)
                let rows = Int(wave[i].squareRoot() * 3.99)
                for k in -rows...rows { fill(CGRect(x: cx, y: 104 + CGFloat(k) * 4 - 2, width: 4, height: 3), cx < ph ? Ramp.o[3] : Tok.controlPressed) }
                cx += 6
            }
        }
        if let d = tl.derived { for k in d.clicks { fill(CGRect(x: x(k.t) - 1, y: 84, width: 2, height: 2), Tok.text2) } }
        fill(CGRect(x: ph.rounded() - 1, y: 4, width: 2, height: size.height - 8), Tok.text)     // playhead = white head
    }

    private func hit(_ p: CGPoint, _ w: CGFloat) -> Drag {
        let tl = model.timeline, dur = tl.timeMap.outputDuration
        func x(_ t: Double) -> CGFloat { CGFloat(t / max(dur, 0.001)) * w }
        if zoomLane.contains(p.y) {
            for z in tl.zoom.reversed() {
                if abs(p.x - x(z.start)) < 7 { return Drag(kind: .left, id: z.id, orig: z, t0: Double(p.x / w) * dur) }
                if abs(p.x - x(z.end)) < 7 { return Drag(kind: .right, id: z.id, orig: z, t0: Double(p.x / w) * dur) }
                if p.x > x(z.start), p.x < x(z.end) { return Drag(kind: .move, id: z.id, orig: z, t0: Double(p.x / w) * dur) }
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
                let dt = t - d.t0
                switch d.kind {
                case .move: let len = o.end - o.start, s = min(max(o.start + dt, 0), dur - len); tl.zoom[i].start = s; tl.zoom[i].end = s + len
                case .left: tl.zoom[i].start = min(max(o.start + dt, 0), o.end - 0.3)
                default: tl.zoom[i].end = max(min(o.end + dt, dur), o.start + 0.3)
                }
                tl.zoom[i].origin = .manual
            }
        }
    }
}