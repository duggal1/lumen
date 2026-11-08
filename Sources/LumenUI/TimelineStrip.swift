import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenDirector

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

struct TimelineStrip: View {
    let model: EditorModel
    @State private var drag: Drag?
    @State private var hoveredZoom: UUID?
    @State private var hoveredMarker: Marker?
    @State private var hoveredClip: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    private struct Drag { enum Kind { case seek, move, left, right, reorder }; var kind: Kind; var id: UUID?; var orig: ZoomSegment?; var origClip: TimelineClip?; var t0: Double }
    private struct Marker { var t: Double; var kind: String; var isTap: Bool }
    // Fixed lane heights, top to bottom: ruler, clip (magnetic), zoom, events, audio.
    private let hRuler: CGFloat = 20, hClip: CGFloat = 28, hZoom: CGFloat = 28
    private let hEvents: CGFloat = 32, hAudio: CGFloat = 32

    var body: some View {
        GeometryReader { g in
            VStack(spacing: 0) {
                rulerLane(width: g.size.width)
                clipLane(width: g.size.width)
                zoomLane(width: g.size.width)
                eventsLane(width: g.size.width)
                audioLane(width: g.size.width)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { change($0, g.size.width) }.onEnded { _ in drag = nil })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): setHover(at: p, width: g.size.width)
                case .ended:
                    hoveredZoom = nil; hoveredMarker = nil; hoveredClip = nil
                    NSCursor.arrow.set()
                }
            }
            .onKeyPress("[") { stepClick(direction: -1); return .handled }
            .onKeyPress("]") { stepClick(direction: 1); return .handled }
            .focusable()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline")
            .accessibilityHint("Drag to seek. Drag a zoom segment to move or resize it. Bracket keys step between clicks.")
            .accessibilityValue(eventsSummary())
        }
        .frame(height: hRuler + hClip + hZoom + hEvents + hAudio)
        .overlay { PlayheadLine(model: model) }
        .background(RoundedRectangle(cornerRadius: 12).fill(Tok.surface))
    }

    // MARK: - Shared mapping (fit-to-width through the time map)

    private func x(_ t: Double, _ dur: Double, _ w: CGFloat) -> CGFloat {
        CGFloat(t / max(dur, 0.001)) * w
    }
    private func outEvents() -> [Marker] {
        let tl = model.timeline, tm = tl.timeMap
        var markers: [Marker] = []
        if let d = tl.derived {
            markers += d.clicks.map { Marker(t: $0.t, kind: "Click", isTap: false) }
        }
        markers += tl.overlays.taps.map { Marker(t: tm.output(atSource: $0.t), kind: "Tap", isTap: true) }
        return markers.sorted { $0.t < $1.t }
    }
    private func clickCount() -> Int { outEvents().count }
    private func eventsSummary() -> String { "\(clickCount()) clicks" }
    private func keyOutputs() -> [Double] {
        let tm = model.timeline.timeMap
        return model.session.input.events
            .filter { $0.kind == .keyDown && !tm.isCut($0.t) }
            .map { tm.output(atSource: $0.t) }
            .sorted()
    }
    private func autoZoomSpansOut() -> [(start: Double, end: Double)] {
        let tm = model.timeline.timeMap
        return model.timeline.zoom.filter { $0.origin == .auto }
            .map { (start: tm.output(atSource: $0.start), end: tm.output(atSource: $0.end)) }
    }

    // MARK: - Ruler

    @ViewBuilder private func rulerLane(width: CGFloat) -> some View {
        let tm = model.timeline.timeMap, dur = max(tm.outputDuration, 0.001)
        Canvas { c, size in
            let w = size.width
            let stepS: Double = dur > 120 ? 30 : dur > 40 ? 10 : dur > 12 ? 5 : dur > 3 ? 0.5 : 0.25
            func fill(_ r: CGRect, _ col: Color) { c.fill(Path(r), with: .color(col), style: FillStyle(antialiased: false)) }
            var t = 0.0
            while t <= dur + 1e-9 {
                let tx = x(t, dur, w).rounded()
                fill(CGRect(x: tx, y: 14, width: 1, height: 5), Tok.text2)
                let label = stepS < 1 ? String(format: "%.2f", t) : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
                let isLast = t + stepS > dur
                c.draw(Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text2),
                       at: CGPoint(x: isLast ? tx - 4 : tx + 4, y: 8), anchor: isLast ? .trailing : .leading)
                t += stepS
            }
        }
        .frame(height: hRuler)
        .accessibilityHidden(true)
    }

    // MARK: - Clip lane (magnetic main lane)

    @ViewBuilder private func clipLane(width: CGFloat) -> some View {
        let tl = model.timeline
        let dur = max(tl.compositionDuration, 0.001)
        Canvas { c, size in
            let w = size.width
            func fill(_ r: CGRect, _ col: Color) { c.fill(Path(r), with: .color(col), style: FillStyle(antialiased: false)) }
            if tl.clips.isEmpty {
                c.draw(Text("No clips — Import a clip or split at the playhead.")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text2),
                       at: CGPoint(x: 6, y: hClip / 2), anchor: .leading)
            }
            for clip in tl.clips {
                let a = x(clip.start, dur, w), b = x(clip.end, dur, w)
                let r = CGRect(x: a + 1, y: 4, width: max(b - a - 2, 4), height: hClip - 8)
                let isSelected = clip.id == model.selection
                let isHovered = clip.id == hoveredClip
                let base: Color = isSelected ? Tok.selection.opacity(0.55) : Tok.controlPressed.opacity(0.85)
                c.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(base))
                c.stroke(Path(roundedRect: r, cornerRadius: 5),
                         with: .color(isSelected ? Tok.text : Tok.text2.opacity(isHovered ? 0.9 : 0.5)), lineWidth: isSelected ? 2 : 1)
                if TimelineGeometry.labelFits(width: r.width, text: clip.name) || isHovered {
                    c.draw(Text(clip.name).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Tok.text), at: CGPoint(x: r.minX + 6, y: r.midY), anchor: .leading)
                }
                if isSelected { fill(CGRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 2), Tok.text) }
            }
            // Snap indicator
            if let d = drag, d.kind == .reorder, d.id != nil {
                // hint text could be added here; drag itself is the indicator
            }
        }
        .frame(height: hClip)
        .accessibilityLabel(clipAccessibility())
    }

    private func clipAccessibility() -> String {
        let tl = model.timeline
        guard !tl.clips.isEmpty else { return "No clips" }
        return tl.clips.map { String(format: "Clip %@ %.1f to %.1f seconds", $0.name, $0.start, $0.end) }.joined(separator: ". ")
    }

    // MARK: - Zoom

    @ViewBuilder private func zoomLane(width: CGFloat) -> some View {
        let tl = model.timeline, tm = tl.timeMap, dur = max(tm.outputDuration, 0.001)
        Canvas { c, size in
            let w = size.width
            func fill(_ r: CGRect, _ col: Color) { c.fill(Path(r), with: .color(col), style: FillStyle(antialiased: false)) }
            if tl.zoom.isEmpty {
                c.draw(Text("No zoom segments — Add zoom to focus a moment.")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text2),
                       at: CGPoint(x: 6, y: hZoom / 2), anchor: .leading)
            }
            // Cause threads: faint segment from lane bottom up to each triggering block.
            let spans = autoZoomSpansOut()
            for cut in tm.cuts {
                let cx = x(tm.output(atSource: cut.start), dur, w)
                fill(CGRect(x: cx - 1, y: 2, width: 2, height: hZoom - 4), Tok.statusBad)
            }
            for m in outEvents() where !m.isTap {
                if TimelineGeometry.triggerZoom(t: m.t, zooms: spans) != nil {
                    let mx = x(m.t, dur, w)
                    c.stroke(Path(CGRect(x: mx, y: hZoom - 4, width: 0.5, height: 4)), with: .color(Tok.text2.opacity(0.35)), lineWidth: 1)
                }
            }
            for z in tl.zoom {
                let zs = tm.output(atSource: z.start), ze = tm.output(atSource: z.end)
                guard ze > zs else { continue }
                let rawW = x(ze, dur, w) - x(zs, dur, w)
                // 1px inset each side guarantees the 2px neighbour gap.
                let r = CGRect(x: x(zs, dur, w) + 1, y: 4, width: max(rawW - 2, 4), height: 20)
                let norm = min(max((z.scale - 1.1) / (4.0 - 1.1), 0), 1)
                let isSelected = z.id == model.selection, isHovered = z.id == hoveredZoom
                let base = Tok.selection.opacity((z.origin == .manual ? 0.32 : 0.28) + 0.55 * norm)
                c.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(base))
                c.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(isSelected ? Tok.text : Tok.selection.opacity(isHovered ? 0.9 : 0.65)), lineWidth: isSelected ? 2 : 1)
                if isHovered {
                    fill(CGRect(x: r.minX, y: r.minY, width: 6, height: r.height), Tok.selection.opacity(0.95))
                    fill(CGRect(x: r.maxX - 6, y: r.minY, width: 6, height: r.height), Tok.selection.opacity(0.95))
                }
                let glyph = z.origin == .auto ? "A" : "M"
                let label = String(format: "%.1f×", z.scale) + " " + glyph
                if TimelineGeometry.labelFits(width: r.width, text: label) || isHovered {
                    c.draw(Text(label).font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Tok.text), at: CGPoint(x: r.minX + 8, y: r.midY), anchor: .leading)
                }
                if isSelected { fill(CGRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 2), Tok.text) }
            }
        }
        .frame(height: hZoom)
        .accessibilityLabel(zoomAccessibility())
    }

    private func zoomAccessibility() -> String {
        let tm = model.timeline.timeMap
        let items = model.timeline.zoom.map { z -> String in
            let o = tm.output(atSource: z.start), e = tm.output(atSource: z.end)
            return String(format: "Zoom %.1f× %.1f to %.1f seconds, %@", z.scale, o, e, z.origin == .auto ? "automatic" : "manual")
        }
        return items.isEmpty ? "No zoom segments" : items.joined(separator: ". ")
    }

    // MARK: - Events

    @ViewBuilder private func eventsLane(width: CGFloat) -> some View {
        let tm = model.timeline.timeMap, dur = max(tm.outputDuration, 0.001)
        Canvas { c, size in
            let w = size.width
            let spans = autoZoomSpansOut()
            // Faint trigger threads (events-lane half: lane top -> head).
            for m in outEvents() where !m.isTap {
                if TimelineGeometry.triggerZoom(t: m.t, zooms: spans) != nil {
                    let mx = x(m.t, dur, w)
                    c.stroke(Path(CGRect(x: mx, y: 0, width: 0.5, height: 10)), with: .color(Tok.text2.opacity(0.35)), lineWidth: 1)
                }
            }
            // Typing bursts: short rounded bars.
            for b in TimelineGeometry.bursts(times: keyOutputs(), gap: 0.5) {
                let a = x(b.start, dur, w), bw = max(x(b.end, dur, w) - a, 6)
                let r = CGRect(x: a, y: 23, width: bw, height: 6)
                c.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(Tok.text2.opacity(0.65)))
            }
            // Clusters at 6px: one marker map, no per-marker views.
            let markers = outEvents()
            if markers.isEmpty {
                c.draw(Text("No clicks — Zoom needs a click to trigger.")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text2.opacity(0.7)),
                       at: CGPoint(x: 6, y: 12), anchor: .leading)
            }
            let xs = markers.map { Double(x($0.t, dur, w)) }
            let clusters = TimelineGeometry.cluster(xs: xs, minGap: 6)
            // Map cluster centres back to representative markers for kind/trigger.
            for cl in clusters {
                let cx = CGFloat(cl.center)
                let members = markers.filter { abs(x($0.t, dur, w) - cx) < 30 }
                let rep = members.first ?? markers.first ?? Marker(t: dur * cl.center / max(w, 1), kind: "Click", isTap: false)
                let isTap = members.contains(where: { $0.isTap })
                let triggered = !isTap && TimelineGeometry.triggerZoom(t: rep.t, zooms: spans) != nil
                let alpha: Double = rep.isTap ? 1 : (triggered ? 1 : 0.45)
                let dim = Tok.tap.opacity(alpha)
                let isHover = hoveredMarker != nil && abs(x(hoveredMarker!.t, dur, w) - cx) < 6
                let headR: CGFloat = isHover ? 4 : 3
                c.stroke(Path(CGRect(x: cx, y: 10, width: 1, height: 16)), with: .color(dim), lineWidth: 1)
                let head = Path(ellipseIn: CGRect(x: cx - headR, y: 7 - headR, width: headR * 2, height: headR * 2))
                if isTap {
                    c.stroke(head, with: .color(dim), lineWidth: 1.5)
                } else {
                    c.fill(head, with: .color(isHover ? Tok.text : dim))
                }
                if cl.count > 1 {
                    c.draw(Text("×\(cl.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(dim),
                           at: CGPoint(x: cx + 6, y: 7), anchor: .leading)
                }
                if isHover {
                    let label = String(format: "%.1f s · %@", rep.t, rep.kind)
                    c.draw(Text(label).font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text),
                           at: CGPoint(x: min(cx + 6, w - 80), y: 7), anchor: .leading)
                }
            }
        }
        .frame(height: hEvents)
        .accessibilityLabel("\(clickCount()) clicks")
        .accessibilityHint("Press left or right bracket to step between clicks")
    }

    // MARK: - Audio

    @ViewBuilder private func audioLane(width: CGFloat) -> some View {
        let tm = model.timeline.timeMap, dur = max(tm.outputDuration, 0.001)
        Canvas { c, size in
            let w = size.width, h = size.height
            let scale: CGFloat = displayScale > 0 ? displayScale : 2
            func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
            let wave = model.session.waveform, ph = x(model.playhead, dur, w)
            if wave.isEmpty {
                c.draw(Text("No audio — Speech will appear here.")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text2),
                       at: CGPoint(x: 6, y: h / 2), anchor: .leading)
                return
            }
            let cellW: CGFloat = max(snap(4), 1), step: CGFloat = cellW + max(snap(2), 1)
            let cellH: CGFloat = max(snap(3), 1), dotGap: CGFloat = snap(1)
            let mid = h / 2, maxRows = Int(mid / (cellH + dotGap))
            var cx: CGFloat = 0
            while cx < w {
                let t0 = Double(cx / max(w, 1)) * dur, t1 = Double(min(cx + step, w) / max(w, 1)) * dur
                let src0 = tm.source(atOutput: t0), src1 = tm.source(atOutput: t1)
                let peak = TimelineGeometry.columnPeak(wave: wave, srcStart: src0, srcEnd: src1)
                let inRamp = tm.ramps.contains { s in
                    let a = tm.output(atSource: s.start), b = tm.output(atSource: s.end)
                    return t0 >= a && t0 <= b
                }
                let rows = min(Int(peak.squareRoot() * Float(maxRows)), maxRows)
                let col: Color
                if inRamp { col = Tok.controlPressed.opacity(0.7) }
                else if peak < 0.05 { col = Tok.controlPressed }
                else { col = cx < ph ? Tok.accent : Tok.accent.opacity(0.55) }
                for k in -rows...rows {
                    let r = CGRect(x: snap(cx), y: snap(mid + CGFloat(k) * (cellH + dotGap) - cellH / 2), width: cellW, height: cellH)
                    c.fill(Path(r), with: .color(col), style: FillStyle(antialiased: false))
                }
                cx += step
            }
        }
        .frame(height: hAudio)
        .accessibilityHidden(true)
    }

    // MARK: - Playhead (crosses every lane)

    private struct PlayheadLine: View {
        let model: EditorModel
        var body: some View {
            let paused = model.playhead
            TimelineView(.animation(paused: !model.isPlaying)) { _ in
                Canvas { context, size in
                    let t = model.isPlaying ? model.clock.time(at: HostClock.now()) : paused
                    let xx = min(max((CGFloat(t / max(model.duration, 0.001)) * size.width).rounded(), 2), size.width - 2)
                    context.fill(Path(CGRect(x: xx - 1, y: 4, width: 2, height: size.height - 8)),
                                 with: .color(Tok.text), style: FillStyle(antialiased: false))
                }
            }.allowsHitTesting(false)
        }
    }

    // MARK: - Hit, hover, drag (command path preserved)

    private func setHover(at p: CGPoint, width: CGFloat) {
        let yClip0 = hRuler, yZoom0 = yClip0 + hClip, yEvents0 = yZoom0 + hZoom, yAudio0 = yEvents0 + hEvents
        let tm = model.timeline.timeMap, dur = max(tm.outputDuration, 0.001)
        if p.y >= yClip0 && p.y < yZoom0 {
            var hitClip: UUID? = nil
            for clip in model.timeline.clips.reversed() {
                let a = x(clip.start, dur, width), b = x(clip.end, dur, width)
                if p.x >= a - 1 && p.x <= b + 1 { hitClip = clip.id; break }
            }
            hoveredClip = hitClip
            NSCursor.arrow.set()
            return
        }
        if p.y >= yZoom0 && p.y < yEvents0 {
            var hitZoom: UUID? = nil
            for z in model.timeline.zoom.reversed() {
                let a = x(tm.output(atSource: z.start), dur, width), b = x(tm.output(atSource: z.end), dur, width)
                if p.x >= a - 7 && p.x <= b + 7 { hitZoom = z.id; break }
            }
            if hoveredZoom != hitZoom {
                if reduceMotion { hoveredZoom = hitZoom }
                else { withAnimation(Motion.hoverIn) { hoveredZoom = hitZoom } }
            }
            var nearEdge = false
            for z in model.timeline.zoom.reversed() where z.id == hitZoom {
                let a = x(tm.output(atSource: z.start), dur, width), b = x(tm.output(atSource: z.end), dur, width)
                nearEdge = abs(p.x - a) < 7 || abs(p.x - b) < 7
            }
            if nearEdge { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            return
        }
        hoveredZoom = nil
        if p.y >= yEvents0 && p.y < yAudio0 {
            var best: Marker? = nil
            var bestD: CGFloat = 6
            for m in outEvents() {
                let d = abs(x(m.t, dur, width) - p.x)
                if d < bestD { bestD = d; best = m }
            }
            hoveredMarker = best
            if best != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            return
        }
        hoveredMarker = nil
        NSCursor.arrow.set()
    }

    private func hit(_ p: CGPoint, _ w: CGFloat) -> Drag {
        let yClip0 = hRuler, yZoom0 = yClip0 + hClip
        let tm = model.timeline.timeMap, dur = max(tm.outputDuration, 0.001)
        func xx(_ t: Double) -> CGFloat { CGFloat(t / max(dur, 0.001)) * w }
        if p.y >= yClip0 && p.y < yZoom0 {
            for clip in model.timeline.clips.reversed() {
                let a = xx(clip.start), b = xx(clip.end)
                if p.x > a, p.x < b { return Drag(kind: .reorder, id: clip.id, origClip: clip, t0: clip.start) }
            }
        }
        if p.y >= yZoom0 && p.y < yZoom0 + hZoom {
            for z in model.timeline.zoom.reversed() {
                let a = xx(tm.output(atSource: z.start)), b = xx(tm.output(atSource: z.end))
                if abs(p.x - a) < 7 { return Drag(kind: .left, id: z.id, orig: z, t0: Double(p.x / w) * dur) }
                if abs(p.x - b) < 7 { return Drag(kind: .right, id: z.id, orig: z, t0: Double(p.x / w) * dur) }
                if p.x > a, p.x < b { return Drag(kind: .move, id: z.id, orig: z, t0: Double(p.x / w) * dur) }
            }
        }
        return Drag(kind: .seek, id: nil, orig: nil, t0: 0)
    }

    private func snapTime(_ t: Double, dur: Double, w: CGFloat) -> Double {
        let tol = 6 * dur / max(w, 1)
        var best: Double? = nil, bestD = tol
        for m in outEvents() {
            let d = abs(m.t - t)
            if d < bestD { bestD = d; best = m.t }
        }
        return best ?? t
    }

    private func change(_ v: DragGesture.Value, _ w: CGFloat) {
        let dur = model.timeline.compositionDuration, t = min(max(Double(v.location.x / w) * dur, 0), dur)
        if drag == nil {
            drag = hit(v.startLocation, w)
            model.selection = drag?.id
            // Clicking a marker seeks to it exactly.
            if drag?.kind == .seek {
                let yClip0 = hRuler, yZoom0 = yClip0 + hClip, yEvents0 = yZoom0 + hZoom
                if v.startLocation.y >= yEvents0 && v.startLocation.y < yEvents0 + hEvents {
                    var bestT: Double? = nil, bestD: CGFloat = 6
                    for m in outEvents() {
                        let d = abs(x(m.t, dur, w) - v.startLocation.x)
                        if d < bestD { bestD = d; bestT = m.t }
                    }
                    if let bt = bestT { model.seek(bt); return }
                }
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
                let len = oe - os, s = snapTime(min(max(os + dt, 0), dur - len), dur: dur, w: w)
                newStartOut = s; newEndOut = s + len
            case .left:
                newStartOut = snapTime(min(max(os + dt, 0), oe - 0.3), dur: dur, w: w)
                newEndOut = oe
            default:
                newStartOut = os
                newEndOut = snapTime(max(min(oe + dt, dur), os + 0.3), dur: dur, w: w)
            }
            let s = tm.source(atOutput: newStartOut), e = tm.source(atOutput: newEndOut)
            // Command path: reduce(.moveZoom) preserves origin->manual + effects.
            let ctx = ReduceContext(playhead: model.playhead, selection: id, duration: dur)
            model.edit(coalesce: true) { tl in _ = try? reduce(&tl, .moveZoom(id, start: s, end: e), ctx: ctx) }
        case .reorder:
            guard let id = d.id else { return }
            // drag reorder: move the clip, then magneticNormalize reorders
            let target = t
            let ctx = ReduceContext(playhead: model.playhead, selection: id, duration: dur)
            model.edit(coalesce: true) { tl in _ = try? reduce(&tl, .moveClip(id, start: target), ctx: ctx) }
        }
    }

    private func stepClick(direction: Int) {
        let markers = outEvents().map(\.t).sorted()
        guard !markers.isEmpty else { return }
        let cur = model.playhead
        let target: Double?
        if direction > 0 { target = markers.first { $0 > cur + 0.001 } } else { target = markers.last { $0 < cur - 0.001 } }
        if let target { model.seek(target) }
    }
}
