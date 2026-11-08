import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenDirector

extension TimelineStrip {
    /// Pending cut range: bracket handles at each end, body in the diff token.
    /// The one novel idea on this screen: the range *is* the readout — the
    /// gap is drawn before anything is removed, so the cut is visible while
    /// it is still reversible.
    @ViewBuilder func pendingLayer(_ vp: Viewport) -> some View {
        Canvas { c, size in
            guard let p = model.pendingCut else { return }
            let x0 = vp.x(p.start), x1 = vp.x(p.end)
            guard x1 > x0 else { return }
            let y0 = TimelineStrip.Lanes.clip, y1 = TimelineStrip.Lanes.audio + TimelineStrip.Lanes.lane
            // Body: 1-bit lattice shimmer in the status-bad token.
            var body = Path()
            var x = x0
            while x + 4 <= x1 {
                for y in stride(from: y0, through: y1, by: 4) {
                    body.addRect(CGRect(x: x + 1, y: y + 20, width: 1, height: 2))
                }
                x += 4
            }
            c.fillCells(body, Tok.statusBad)
            // Bracket handles: 2pt thick, 8pt arms (pixel language).
            let h: CGFloat = 8
            var caps = Path()
            for (cx, dir) in [(x0, CGFloat(1)), (x1, CGFloat(-1))] {
                let top = y0 + 4, bot = y1 - 4
                caps.addRect(CGRect(x: dir > 0 ? cx : cx - 2, y: top, width: 2, height: h))
                caps.addRect(CGRect(x: dir > 0 ? cx : cx - h, y: top, width: h, height: 2))
                caps.addRect(CGRect(x: dir > 0 ? cx : cx - 2, y: bot - h, width: 2, height: h))
                caps.addRect(CGRect(x: dir > 0 ? cx : cx - h, y: bot - 2, width: h, height: 2))
            }
            c.fillCells(caps, Tok.statusBad)
            _ = size
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Seam handles for existing cuts: two brackets at the join so either
    /// edge can be dragged (widen restores, narrow cuts more).
    @ViewBuilder func seamLayer(_ vp: Viewport) -> some View {
        Canvas { c, _ in
            let tm = model.timeline.timeMap
            for cut in tm.cuts where cut.end > cut.start {
                let t = tm.output(atSource: cut.end)
                guard t >= vp.origin - 0.1, t <= vp.origin + vp.visible + 0.1 else { continue }
                let x = vp.x(t)
                let y0 = TimelineStrip.Lanes.zoom, y1 = TimelineStrip.Lanes.events
                var p = Path()
                // Left bracket (start edge) and right bracket (end edge).
                for off in [-4, 2] {
                    let cx = x + CGFloat(off)
                    p.addRect(CGRect(x: cx, y: y0 + 4, width: 2, height: 8))
                    p.addRect(CGRect(x: cx, y: y1 - 12, width: 2, height: 8))
                }
                c.fillCells(p, Tok.statusBad)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
