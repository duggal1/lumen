import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenDirector

extension TimelineStrip {
    // MARK: - Strip base + run layout

    /// A run of slats (clip or zoom): tall end caps, body, and a cleared hole so a label never sits on pixels.
    struct Run {
        var c0: Int, c1: Int
        var bodyH: CGFloat, capH: CGFloat, caps: Int
        var body: Color, cap: Color
        var label: String?
        var hole: Range<Int>
        var selected: Bool
    }

    func drawBase(_ c: GraphicsContext, _ size: CGSize, _ lat: TimelineStrip.Lattice, dust: Bool, holes: [Range<Int>] = []) {
        let strip = CGRect(x: TimelineStrip.Lattice.inset, y: 2, width: floor(size.width) - 2 * TimelineStrip.Lattice.inset, height: 36)
        c.fill(Path(roundedRect: strip, cornerRadius: 8), with: .color(Tok.well))
        guard dust else { return }
        var p = Path()
        for col in 0..<lat.cols where !holes.contains(where: { $0.contains(col) }) {
            p.addRect(CGRect(x: lat.x(col: col) + 1, y: TimelineStrip.Lanes.mid, width: 1, height: 1))
        }
        c.fillCells(p, Tok.controlPressed)
    }

    func drawEmpty(_ c: GraphicsContext, _ text: String) {
        c.draw(Text(text).font(TimelineStrip.Face.label).foregroundStyle(Tok.text2),
               at: CGPoint(x: TimelineStrip.Lattice.inset + 12, y: TimelineStrip.Lanes.mid), anchor: .leading)
    }

    func layoutRun(_ lat: TimelineStrip.Lattice, c0: Int, c1: Int, bodyH: CGFloat, capH: CGFloat, capCols: Int,
                   body: Color, cap: Color, labels: [String], truncate: Bool, selected: Bool) -> Run {
        let end = max(c1, c0 + 1)
        let caps = (end - c0) >= 2 * capCols + 1 ? capCols : 1
        let avail = end - c0 - 2 * caps - 2
        var label: String? = nil
        if avail > 0 {
            let w = CGFloat(avail) * TimelineStrip.Lattice.pitch
            label = truncate ? TimelineGeometry.truncated(labels[0], width: w)
                             : TimelineGeometry.firstFit(labels, width: w)
        }
        var hole = c0..<c0
        if let l = label {
            let n = Int((TimelineGeometry.textWidth(l) / TimelineStrip.Lattice.pitch).rounded(.up))
            hole = (c0 + caps)..<(c0 + caps + n + 2)
        }
        return Run(c0: c0, c1: end, bodyH: bodyH, capH: capH, caps: caps, body: body, cap: cap,
                   label: label, hole: hole, selected: selected)
    }

    func drawRun(_ c: GraphicsContext, _ lat: TimelineStrip.Lattice, _ r: Run) {
        var body = Path(), cap = Path()
        let yb = TimelineStrip.Lanes.mid - r.bodyH / 2, yc = TimelineStrip.Lanes.mid - r.capH / 2
        for col in r.c0..<r.c1 {
            let x = lat.x(col: col)
            if col < r.c0 + r.caps || col >= r.c1 - r.caps {
                cap.addRect(CGRect(x: x, y: yc, width: TimelineStrip.Lattice.cell, height: r.capH))
            } else if !r.hole.contains(col) {
                body.addRect(CGRect(x: x, y: yb, width: TimelineStrip.Lattice.cell, height: r.bodyH))
            }
        }
        c.fillCells(body, r.body)
        c.fillCells(cap, r.cap)
        if let l = r.label {
            c.draw(Text(l).font(TimelineStrip.Face.label).foregroundStyle(Tok.text),
                   at: CGPoint(x: lat.x(col: r.c0 + r.caps + 1), y: TimelineStrip.Lanes.mid), anchor: .leading)
        }
        if r.selected {
            let left = lat.x(col: r.c0), right = lat.x(col: r.c1 - 1) + TimelineStrip.Lattice.cell
            c.drawBrackets(around: CGRect(x: left, y: yb, width: right - left, height: r.bodyH), color: Tok.accent)
        }
    }

    // MARK: - Ruler

    @ViewBuilder func rulerLane() -> some View {
        let tm = model.timeline.timeMap, dur = max(tm.outputDuration, 0.001)
        Canvas { c, size in
            let lat = TimelineStrip.Lattice(width: size.width)
            let stepS: Double = dur > 120 ? 30 : dur > 40 ? 10 : dur > 12 ? 5 : dur > 3 ? 0.5 : 0.2
            let sub = stepS / 5
            let showSub = Double(lat.span) * sub / dur >= 6
            var major = Path(), minor = Path()
            var k = 0
            while Double(k) * stepS <= dur + 1e-9 {
                let t = Double(k) * stepS
                let x = lat.x(col: lat.col(t, dur)) + 1
                major.addRect(CGRect(x: x, y: 16, width: 1, height: 8))
                if showSub {
                    for j in 1..<5 {
                        let ts = t + Double(j) * sub
                        if ts < dur { minor.addRect(CGRect(x: lat.x(col: lat.col(ts, dur)) + 1, y: 20, width: 1, height: 4)) }
                    }
                }
                let label = TimelineGeometry.timecode(t, tenths: stepS < 1)
                let w = ceil((label as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width)
                let flip = x + 4 + w > size.width - TimelineStrip.Lattice.inset
                c.draw(Text(label).font(TimelineStrip.Face.mono).foregroundStyle(Tok.text2),
                       at: CGPoint(x: flip ? x - 3 : x + 4, y: 8), anchor: flip ? .trailing : .leading)
                k += 1
            }
            c.fillCells(minor, Tok.controlPressed)
            c.fillCells(major, Tok.text2)
        }
        .frame(height: TimelineStrip.Lanes.ruler)
        .accessibilityHidden(true)
    }

    // MARK: - Clips

    @ViewBuilder func clipLane() -> some View {
        let tl = model.timeline
        let dur = max(tl.compositionDuration, 0.001)
        Canvas { c, size in
            let lat = TimelineStrip.Lattice(width: size.width)
            var runs: [Run] = []
            for clip in tl.clips {
                let sel = clip.id == model.selection, hov = clip.id == hoveredClip
                let tone: Color = sel ? StripInk.hot : (hov ? StripInk.cellHover : StripInk.cell)
                runs.append(layoutRun(lat, c0: lat.col(clip.start, dur), c1: lat.colEnd(clip.end, dur),
                                      bodyH: 24, capH: 28, capCols: 1, body: tone,
                                      cap: sel ? StripInk.hotDeep : tone,
                                      labels: [clip.name], truncate: true, selected: sel))
            }
            drawBase(c, size, lat, dust: !tl.clips.isEmpty, holes: runs.map(\.hole))
            if tl.clips.isEmpty { drawEmpty(c, "No clips. Import a clip or split at the playhead.") }
            for r in runs where !r.selected { drawRun(c, lat, r) }
            for r in runs where r.selected { drawRun(c, lat, r) }
        }
        .frame(height: TimelineStrip.Lanes.lane)
        .accessibilityLabel(clipAccessibility())
    }

    func clipAccessibility() -> String {
        let tl = model.timeline
        guard !tl.clips.isEmpty else { return "No clips" }
        return tl.clips.map { String(format: "Clip %@ %.1f to %.1f seconds", $0.name, $0.start, $0.end) }.joined(separator: ". ")
    }

    // MARK: - Zoom

    @ViewBuilder func zoomLane() -> some View {
        let tl = model.timeline, tm = tl.timeMap, dur = max(tm.outputDuration, 0.001)
        Canvas { c, size in
            let lat = TimelineStrip.Lattice(width: size.width)
            var runs: [Run] = []
            for z in tl.zoom {
                let zs = tm.output(atSource: z.start), ze = tm.output(atSource: z.end)
                guard ze > zs else { continue }
                let sel = z.id == model.selection, hov = z.id == hoveredZoom
                let h = TimelineGeometry.zoomHeights(scale: z.scale)
                let base: Color = z.origin == .auto ? StripInk.hot : StripInk.hotDeep
                let raised = sel || hov
                let tag = String(format: "%.1f×", z.scale)
                let labels: [String] = z.origin == .auto ? [tag + " Auto", tag] : [tag]
                runs.append(layoutRun(lat, c0: lat.col(zs, dur), c1: lat.colEnd(ze, dur),
                                      bodyH: h.body, capH: h.cap, capCols: raised ? 2 : 1,
                                      body: base, cap: raised ? StripInk.hotDeep : base,
                                      labels: labels, truncate: false, selected: sel))
            }
            drawBase(c, size, lat, dust: !tl.zoom.isEmpty, holes: runs.map(\.hole))
            if tl.zoom.isEmpty { drawEmpty(c, "No zoom segments. Press Z to add one at the playhead.") }
            // Cuts: a dotted rose column where footage was removed.
            var cuts = Path()
            for cut in tm.cuts {
                let x = lat.x(col: lat.col(tm.output(atSource: cut.start), dur))
                var y: CGFloat = 6
                while y + 3 <= 34 {
                    cuts.addRect(CGRect(x: x, y: y, width: TimelineStrip.Lattice.cell, height: 3))
                    y += 4
                }
            }
            c.fillCells(cuts, Tok.statusBad)
            for r in runs where !r.selected { drawRun(c, lat, r) }
            for r in runs where r.selected { drawRun(c, lat, r) }
        }
        .frame(height: TimelineStrip.Lanes.lane)
        .accessibilityLabel(zoomAccessibility())
    }

    func zoomAccessibility() -> String {
        let tm = model.timeline.timeMap
        let items = model.timeline.zoom.map { z -> String in
            let o = tm.output(atSource: z.start), e = tm.output(atSource: z.end)
            return String(format: "Zoom %.1f× %.1f to %.1f seconds, %@", z.scale, o, e, z.origin == .auto ? "automatic" : "manual")
        }
        return items.isEmpty ? "No zoom segments" : items.joined(separator: ". ")
    }

    // MARK: - Events

    /// Reserves a label hole to the right of `col` (or left, when allowed). Nil when it does not fit.
    func place(_ text: String, at col: Int, cols: Int, avoid: Set<Int>, left: Bool) -> (hole: Range<Int>, start: Int)? {
        let n = Int((TimelineGeometry.textWidth(text) / TimelineStrip.Lattice.pitch).rounded(.up))
        let right = (col + 1)..<(col + n + 3)
        if right.upperBound <= cols, !right.contains(where: { avoid.contains($0) }) { return (right, col + 2) }
        guard left, col - n - 2 >= 0 else { return nil }
        return ((col - n - 2)..<col, col - 1 - n)
    }

    @ViewBuilder func eventsLane() -> some View {
        let tm = model.timeline.timeMap, dur = max(tm.outputDuration, 0.001)
        Canvas { c, size in
            let lat = TimelineStrip.Lattice(width: size.width)
            let markers = outEvents()
            let spans = autoZoomSpansOut()
            let focus = focusSpan()
            var byCol: [Int: [Marker]] = [:]
            for m in markers { byCol[lat.col(m.t, dur), default: []].append(m) }
            let occupied = Set(byCol.keys)

            // Labels first: each reserves a hole that clears dust and neighbouring slats.
            var labels: [(text: String, start: Int, color: Color)] = []
            var holes: [Range<Int>] = []
            for (col, ms) in byCol {
                if col == hoveredCol {
                    let text = TimelineGeometry.timecode(ms[0].t, tenths: true) + " " + ms[0].kind
                    if let p = place(text, at: col, cols: lat.cols, avoid: [], left: true) {
                        labels.append((text: text, start: p.start, color: Tok.text)); holes.append(p.hole)
                    }
                } else if ms.count > 1 {
                    let text = "×\(ms.count)"
                    if let p = place(text, at: col, cols: lat.cols, avoid: occupied, left: false) {
                        labels.append((text: text, start: p.start, color: Tok.text2)); holes.append(p.hole)
                    }
                }
            }

            drawBase(c, size, lat, dust: !markers.isEmpty, holes: holes)
            if markers.isEmpty { drawEmpty(c, "No clicks. Zoom needs a click to trigger.") }

            // Typing bursts: runs of low cells.
            var typing = Path()
            for b in TimelineGeometry.bursts(times: keyOutputs(), gap: 0.5) {
                let c0 = lat.col(b.start, dur), c1 = max(lat.colEnd(b.end, dur), c0 + 1)
                for col in c0..<c1 { typing.addRect(CGRect(x: lat.x(col: col), y: 28, width: TimelineStrip.Lattice.cell, height: 4)) }
            }
            c.fillCells(typing, StripInk.cell)

            // Solid slat = click, dotted slat = tap. Orange = it caused a zoom. Grey = it did not.
            var head = Path(), focused = Path(), trig = Path(), idle = Path()
            for (col, ms) in byCol {
                let isHover = col == hoveredCol
                if !isHover && holes.contains(where: { $0.contains(col) }) { continue }
                let x = lat.x(col: col)
                let tap = ms.contains { $0.isTap }
                var inFocus = false
                if let f = focus { inFocus = ms.contains { !$0.isTap && $0.t >= f.start && $0.t < f.end } }
                let triggered = ms.contains { !$0.isTap && TimelineGeometry.triggerZoom(t: $0.t, zooms: spans) != nil }
                var p = Path()
                if tap {
                    for i in 0..<4 { p.addRect(CGRect(x: x, y: 8 + 4 * CGFloat(i), width: TimelineStrip.Lattice.cell, height: 3)) }
                } else {
                    p.addRect(CGRect(x: x, y: 8, width: TimelineStrip.Lattice.cell, height: 16))
                }
                if isHover { head.addPath(p) }
                else if tap { trig.addPath(p) }
                else if inFocus { focused.addPath(p) }
                else if triggered { trig.addPath(p) }
                else { idle.addPath(p) }
            }
            c.fillCells(idle, StripInk.cell)
            c.fillCells(trig, StripInk.hot)
            c.fillCells(focused, StripInk.hotDeep)
            c.fillCells(head, Tok.text)

            for l in labels {
                c.draw(Text(l.text).font(TimelineStrip.Face.label).foregroundStyle(l.color),
                       at: CGPoint(x: lat.x(col: l.start), y: 16), anchor: .leading)
            }
        }
        .frame(height: TimelineStrip.Lanes.lane)
        .accessibilityLabel("\(clickCount()) clicks")
        .accessibilityHint("Press left or right bracket to step between clicks")
    }

    // MARK: - Audio: mirrored cell tape, 4 rows each side, silence is a dotted midline

    @ViewBuilder func audioLane() -> some View {
        let tm = model.timeline.timeMap, dur = max(tm.outputDuration, 0.001)
        Canvas { c, size in
            let lat = TimelineStrip.Lattice(width: size.width)
            let wave = model.session.waveform
            drawBase(c, size, lat, dust: false)
            if wave.isEmpty { drawEmpty(c, "No audio. Speech will appear here."); return }
            let ph = lat.x(model.playhead, dur)
            var played = Path(), tips = Path(), idle = Path(), ramp = Path(), quiet = Path()
            for col in 0..<lat.cols {
                let t0 = Double(col) / Double(lat.cols) * dur, t1 = Double(col + 1) / Double(lat.cols) * dur
                let peak = TimelineGeometry.columnPeak(wave: wave, srcStart: tm.source(atOutput: t0), srcEnd: tm.source(atOutput: t1))
                let level = TimelineGeometry.level(peak: peak)
                let x = lat.x(col: col)
                if level == 0 {
                    quiet.addRect(CGRect(x: x, y: 19, width: TimelineStrip.Lattice.cell, height: 2))
                    continue
                }
                let inRamp = tm.ramps.contains { s in
                    let a = tm.output(atSource: s.start), b = tm.output(atSource: s.end)
                    return t0 >= a && t0 <= b
                }
                let isPlayed = x < ph
                for k in 0..<level {
                    let up = CGRect(x: x, y: 16 - 4 * CGFloat(k), width: TimelineStrip.Lattice.cell, height: 3)
                    let dn = CGRect(x: x, y: 21 + 4 * CGFloat(k), width: TimelineStrip.Lattice.cell, height: 3)
                    let isTip = k == level - 1
                    if inRamp { ramp.addRect(up); ramp.addRect(dn) }
                    else if isPlayed && isTip { tips.addRect(up); tips.addRect(dn) }
                    else if isPlayed { played.addRect(up); played.addRect(dn) }
                    else { idle.addRect(up); idle.addRect(dn) }
                }
            }
            c.fillCells(quiet, Tok.controlPressed)
            c.fillCells(ramp, Tok.controlPressed)
            c.fillCells(idle, StripInk.cell)
            c.fillCells(played, StripInk.hot)
            c.fillCells(tips, StripInk.hotDeep)
        }
        .frame(height: TimelineStrip.Lanes.lane)
        .accessibilityHidden(true)
    }
}
