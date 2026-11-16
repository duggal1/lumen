import SwiftUI
import AppKit

enum TimelineGeometry {
    static func cluster(xs: [Double], minGap: Double) -> [(center: Double, count: Int)] {
        guard !xs.isEmpty else { return [] }
        let sorted = xs.sorted()
        var out: [(center: Double, count: Int)] = []
        var start = 0
        var sum = sorted[0]
        for i in 1..<sorted.count {
            if sorted[i] - sorted[i - 1] < minGap { sum += sorted[i] }
            else {
                let c = (i - start)
                out.append((center: sum / Double(c), count: c))
                start = i; sum = sorted[i]
            }
        }
        let c = sorted.count - start
        out.append((center: sum / Double(c), count: c))
        return out
    }
    static func labelFits(width: CGFloat, text: String) -> Bool {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let w = (text as NSString).size(withAttributes: [.font: font]).width + 16
        return Double(w) <= Double(width)
    }
    static func columnPeak(wave: [Float], srcStart: Double, srcEnd: Double) -> Float {
        guard !wave.isEmpty, srcEnd > srcStart else { return 0 }
        let i0 = min(max(Int(srcStart * 100), 0), wave.count - 1)
        let i1 = min(max(Int(srcEnd * 100), i0 + 1), wave.count)
        var peak: Float = 0
        for i in i0..<i1 { peak = max(peak, abs(wave[i])) }
        return peak
    }
    static func bursts(times: [Double], gap: Double) -> [(start: Double, end: Double)] {
        guard !times.isEmpty else { return [] }
        let sorted = times.sorted()
        var out: [(start: Double, end: Double)] = []
        var s = sorted[0], last = sorted[0]
        for t in sorted.dropFirst() {
            if t - last > gap { out.append((start: s, end: last)); s = t }
            last = t
        }
        out.append((start: s, end: last))
        return out
    }
    static func triggerZoom(t: Double, zooms: [(start: Double, end: Double)]) -> Int? {
        zooms.firstIndex { t >= $0.start && t < $0.end }
    }
}

extension TimelineGeometry {

    static func textWidth(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]).width)
    }
    static func firstFit(_ options: [String], width: CGFloat) -> String? {
        options.first { textWidth($0) <= width }
    }
    static func truncated(_ s: String, width: CGFloat) -> String? {
        guard !s.isEmpty else { return nil }
        if textWidth(s) <= width { return s }
        var n = s.count - 1
        while n > 0 {
            let cand = String(s.prefix(n)) + "…"
            if textWidth(cand) <= width { return cand }
            n -= 1
        }
        return nil
    }
    /// `m:ss.t`, floored, so 59.96 never prints 0:60.0. Hours only when needed.
    static func timecode(_ t: Double, tenths: Bool) -> String {
        let total = Int(((max(t, 0) + 1e-6) * 10).rounded(.down))
        let h = total / 36000, m = (total / 600) % 60, s = (total / 10) % 60, d = total % 10
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return tenths ? base + String(format: ".%d", d) : base
    }
    /// Zoom depth as slat height: 8, 12, 16, 20, 24 pt body, caps 4 pt taller. All even, so they centre on whole pixels.
    static func zoomHeights(scale: Double) -> (body: CGFloat, cap: CGFloat) {
        let norm = min(max((scale - 1.1) / (4.0 - 1.1), 0), 1)
        let body = CGFloat(8 + 4 * Int((norm * 4).rounded()))
        return (body, body + 4)
    }
    /// Peak through dB (floor -54, ceiling -6) into 0...4 cells per half.
    static func level(peak: Float) -> Int {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(peak)
        let norm = min(max((db + 54) / 48, 0), 1)
        return Int((norm * 4).rounded())
    }
}

extension GraphicsContext {
    func fillCells(_ p: Path, _ color: Color) {
        fill(p, with: .color(color), style: FillStyle(antialiased: false))
    }
    /// Four corner brackets from cells: 2 pt thick, 8 pt arms, 4 pt outside the target.
    func drawBrackets(around r: CGRect, color: Color) {
        let o = r.insetBy(dx: -4, dy: -4), t: CGFloat = 2, a: CGFloat = 8
        var p = Path()
        for (x, sx) in [(o.minX, CGFloat(1)), (o.maxX, CGFloat(-1))] {
            for (y, sy) in [(o.minY, CGFloat(1)), (o.maxY, CGFloat(-1))] {
                p.addRect(CGRect(x: sx > 0 ? x : x - a, y: sy > 0 ? y : y - t, width: a, height: t))
                p.addRect(CGRect(x: sx > 0 ? x : x - t, y: sy > 0 ? y : y - a, width: t, height: a))
            }
        }
        fillCells(p, color)
    }
}

extension TimelineStrip {
    /// One column grid for every lane. Pitch 4, cell 3, gap 1: whole device pixels at 1x, 2x, 3x.
    struct Lattice {
        static let pitch: CGFloat = 4, cell: CGFloat = 3
        static let inset: CGFloat = 8   // strip inset from the card edge
        static let pad: CGFloat = 8     // lattice inset inside the strip
        let cols: Int
        let x0: CGFloat
        var span: CGFloat { CGFloat(cols) * Lattice.pitch }

        init(width: CGFloat) {
            let margin = Lattice.inset + Lattice.pad
            let inner = max(width - 2 * margin, Lattice.pitch)
            let n = max(Int(inner / Lattice.pitch), 1)
            cols = n
            x0 = margin + ((inner - CGFloat(n) * Lattice.pitch) / 2).rounded(.down)
        }
        func frac(_ t: Double, _ dur: Double) -> Double { min(max(t / max(dur, 0.001), 0), 1) }
        func col(_ t: Double, _ dur: Double) -> Int { min(Int(frac(t, dur) * Double(cols)), cols - 1) }
        func colEnd(_ t: Double, _ dur: Double) -> Int { min(Int((frac(t, dur) * Double(cols)).rounded(.up)), cols) }
        func col(atX x: CGFloat) -> Int { min(max(Int(((x - x0) / Lattice.pitch).rounded(.down)), 0), cols - 1) }
        func x(col: Int) -> CGFloat { x0 + CGFloat(col) * Lattice.pitch }
        func x(_ t: Double, _ dur: Double) -> CGFloat { x0 + CGFloat(frac(t, dur)) * span }
        func cx(_ t: Double, _ dur: Double) -> CGFloat { x(col: col(t, dur)) + Lattice.cell / 2 }
        func t(atX x: CGFloat, _ dur: Double) -> Double { Double(min(max((x - x0) / span, 0), 1)) * dur }
    }

    /// The visible window over the output timeline: `pps` points per second,
    /// `origin` = output second at the strip's left edge. Panning only moves
    /// `origin`; zooming moves `pps` and keeps the anchored second still.
    struct Viewport {
        let lattice: Lattice
        let pps: CGFloat
        let origin: Double
        let duration: Double
        var cols: Int { lattice.cols }
        var span: CGFloat { lattice.span }
        var visible: Double { Double(span / max(pps, 0.001)) }
        var maxOrigin: Double { max(0, duration - visible) }

        func x(_ t: Double) -> CGFloat { lattice.x0 + CGFloat(t - origin) * pps }
        func t(atX x: CGFloat) -> Double { origin + Double((x - lattice.x0) / pps) }
        /// Unclamped column, for runs that extend past either edge.
        func colFloor(_ t: Double) -> Int { Int((Double(t - origin) * Double(pps) / Double(Lattice.pitch)).rounded(.down)) }
        func colCeil(_ t: Double) -> Int { Int((Double(t - origin) * Double(pps) / Double(Lattice.pitch)).rounded(.up)) }
        /// Visible column nearest a time, clamped into the strip.
        func col(_ t: Double) -> Int { min(max(colFloor(t), 0), cols - 1) }
        func cx(_ t: Double) -> CGFloat { x(t) + Lattice.cell / 2 }
        func time(atCol col: Int) -> Double { origin + Double(col) * Double(Lattice.pitch) / Double(pps) }
        func clampOrigin(_ o: Double) -> Double { min(max(o, 0), maxOrigin) }
        var timeRange: ClosedRange<Double> { origin...(origin + visible) }
    }

    /// Ruler 24, then five lanes of 40 (strip 36, 2 pt air above and below).
    /// clip → zoom → events → audio (voice) → music (violet). = 224.
    enum Lanes {
        static let ruler: CGFloat = 24, lane: CGFloat = 40
        static let clip: CGFloat = 24, zoom: CGFloat = 64, events: CGFloat = 104, audio: CGFloat = 144, music: CGFloat = 184
        static let total: CGFloat = 224
        static let mid: CGFloat = 20   // strip centre inside a lane
    }

    enum Face {
        static let label = Font.system(size: 12, weight: .medium).monospacedDigit()
        static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
    }
}
