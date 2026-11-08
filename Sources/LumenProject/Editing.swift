import Foundation

// MARK: - Recording segments (the magnetic main lane)

/// A visible strip of the recording: a contiguous source range with content,
/// bounded by a seam, a cut join, or a trimmed lane edge. `id` is the index in
/// the ordered list, stable for the current timeline state.
public struct RecordingSegment: Identifiable, Equatable, Sendable {
    public var id: Int
    public var start: Double      // SOURCE seconds
    public var end: Double
    public var outputStart: Double
    public var outputEnd: Double
    public var hasCutBefore: Bool
    public var hasSeamBefore: Bool
    public var hasCutAfter: Bool
    public var hasSeamAfter: Bool
    public var duration: Double { end - start }
}

public extension Timeline {
    /// Boundaries that partition the recording: trim edges, logical seams and
    /// cut edges. Sorted and de-duplicated to 0.1 ms.
    var recordingBoundaries: [Double] {
        let tm = timeMap
        var xs = [tm.trimStart, tm.trimEnd]
        xs += seams.map(\.t)
        for c in tm.cuts where c.end > c.start { xs.append(c.start); xs.append(c.end) }
        xs = xs.map { min(max($0, tm.trimStart), tm.trimEnd) }.sorted()
        var out: [Double] = []
        for x in xs where out.last.map({ $0.distance(to: x) > 0.0001 }) ?? true { out.append(x) }
        return out
    }

    /// The recording's visible strips in output order. A cut collapses its
    /// source range to zero output length, so the strips stay gapless.
    var recordingSegments: [RecordingSegment] {
        let tm = timeMap
        let bs = recordingBoundaries
        guard bs.count > 1 else { return [] }
        var out: [RecordingSegment] = []
        for i in 0..<(bs.count - 1) {
            let a = bs[i], b = bs[i + 1]
            guard b - a > 0.0001 else { continue }
            let mid = (a + b) / 2
            if tm.isCut(mid) { continue }
            let o0 = tm.output(atSource: a), o1 = tm.output(atSource: b)
            guard o1 - o0 > 0.0001 else { continue }
            let before = seams.contains { abs($0.t - a) < 0.0005 }
            let after = seams.contains { abs($0.t - b) < 0.0005 }
            let cutBefore = tm.cuts.contains { $0.end > $0.start && abs($0.end - a) < 0.0005 }
            let cutAfter = tm.cuts.contains { $0.end > $0.start && abs($0.start - b) < 0.0005 }
            out.append(RecordingSegment(id: out.count, start: a, end: b,
                                        outputStart: o0, outputEnd: o1,
                                        hasCutBefore: cutBefore || (out.last?.hasCutAfter ?? false),
                                        hasSeamBefore: before,
                                        hasCutAfter: cutAfter, hasSeamAfter: after))
        }
        // A cut join makes the next strip's leading edge a cut edge too.
        for i in out.indices.dropFirst() where out[i - 1].hasCutAfter { out[i].hasCutBefore = true }
        return out
    }

    func recordingSegment(atOutput t: Double) -> RecordingSegment? {
        recordingSegments.first { t >= $0.outputStart - 0.0005 && t < $0.outputEnd - 0.0005 }
            ?? recordingSegments.last
    }
}

public extension TimeMap {
    /// Cut edges expressed as OUTPUT seconds (both sides of a removed span sit
    /// on the same output instant — that is the seam).
    var cutJoins: [(cut: CutRange, output: Double)] {
        cuts.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
            .map { ($0, output(atSource: $0.end)) }
    }
}

// MARK: - Mutations used by the reducer

public enum EditError: Error, Equatable, Sendable {
    case emptyRange, removesEverything, tooShort
}

public extension Timeline {
    /// Add a logical split seam at a source instant.
    mutating func addSeam(atSource t: Double) throws {
        let tm = timeMap
        guard t > tm.trimStart + 0.0005, t < tm.trimEnd - 0.0005 else { throw EditError.tooShort }
        guard !tm.isCut(t) else { throw EditError.tooShort }
        guard !seams.contains(where: { abs($0.t - t) < 0.0005 }) else { return }
        seams.append(SplitSeam(t: t))
        seams.sort { $0.t < $1.t }
    }

    mutating func removeSeam(atSource t: Double, eps: Double = 0.05) {
        guard let i = seams.indices.min(by: { abs(seams[$0].t - t) < abs(seams[$1].t - t) }),
              abs(seams[i].t - t) <= eps else { return }
        seams.remove(at: i)
    }

    mutating func removeSeam(id: UUID) { seams.removeAll { $0.id == id } }

    /// Drag a logical split seam. It never changes the output; it only moves
    /// where one strip ends and the next begins. Clamped to a frame inside its
    /// neighbouring boundaries and outside every cut.
    mutating func moveSeam(id: UUID, toSource raw: Double, frame: Double) throws {
        guard let i = seams.firstIndex(where: { $0.id == id }) else { throw EditError.tooShort }
        let tm = timeMap
        let lower = max(i > 0 ? seams[i - 1].t + frame : tm.trimStart + frame, tm.trimStart + frame)
        let upper = min(i + 1 < seams.count ? seams[i + 1].t - frame : tm.trimEnd - frame, tm.trimEnd - frame)
        guard upper >= lower else { throw EditError.tooShort }
        let t = min(max(raw, lower), upper)
        guard !tm.isCut(t) else { throw EditError.tooShort }
        seams[i].t = t
    }

    /// Remove an OUTPUT range from the recording: the one conceptual cut.
    /// Everything inside is gone, the gap closes, anchored content inside is
    /// removed and content straddling an edge is trimmed back to the survivor.
    mutating func removeOutputRange(_ a0: Double, _ b0: Double, frame: Double) throws {
        let tm = timeMap
        let live = max(tm.outputDuration, 0)
        guard live > frame else { throw EditError.removesEverything }
        let a = min(max(a0, 0), live), b = min(max(b0, 0), live)
        guard b - a >= frame * 0.999 else { throw EditError.tooShort }
        guard live - (b - a) >= frame * 0.999 else { throw EditError.removesEverything }
        let srcA = tm.source(atOutput: a), srcB = tm.source(atOutput: b)
        guard srcB - srcA > 0.0005 else { throw EditError.tooShort }
        // Content first, the new cut last: trimAnchoredContent also folds cuts
        // that overlap the removed span, so appending before it would delete
        // the very cut this command exists to create.
        trimAnchoredContent(removedSource: srcA...srcB)
        seams.removeAll { $0.t >= srcA - 0.0005 && $0.t <= srcB + 0.0005 }
        timeMap.cuts.append(CutRange(start: srcA, end: srcB, origin: .manual))
        timeMap.cuts = Self.merged(timeMap.cuts)
        rippleSoundtrack(afterOutput: a, by: -(b - a))
    }

    /// Move one edge of an existing cut. Widening removes more source, narrowing
    /// restores it. A cut that collapses to one frame or less becomes a join.
    mutating func trimCut(id: UUID, isStart: Bool, toSource raw: Double, frame: Double) throws {
        guard let i = timeMap.cuts.firstIndex(where: { $0.id == id }) else { throw EditError.tooShort }
        let original = timeMap.cuts[i]
        let tm = timeMap
        let speed = max(abs(tm.speed(atOutput: tm.output(atSource: isStart ? original.start : original.end))), 0.01)
        let minGap = frame * speed
        var cut = original
        if isStart {
            cut.start = min(max(raw, tm.trimStart), cut.end - minGap)
        } else {
            cut.end = min(max(raw, cut.start + minGap), tm.trimEnd)
        }
        guard cut.end - cut.start > 0 else { throw EditError.tooShort }
        // Take the edited cut out of the trim so the fold cannot eat it, then
        // put it back with its identity. Narrowing (the cut grows) removes the
        // extra content; widening only restores source and leaves survivors
        // alone, since content destroyed by the original cut is gone for good.
        timeMap.cuts.remove(at: i)
        if isStart, cut.start > original.start {
            trimAnchoredContent(removedSource: original.start...cut.start)
        } else if !isStart, cut.end < original.end {
            trimAnchoredContent(removedSource: cut.end...original.end)
        }
        timeMap.cuts.append(cut)
        timeMap.cuts = Self.merged(timeMap.cuts)
        seams.removeAll { $0.t >= cut.start - 0.0005 && $0.t <= cut.end + 0.0005 }
    }

    /// Ripple-delete one visible strip of the recording.
    mutating func removeSegment(atOutput t: Double, frame: Double) throws {
        guard let s = recordingSegment(atOutput: t) else { throw EditError.tooShort }
        try removeOutputRange(s.outputStart, s.outputEnd, frame: frame)
    }

    /// Cut from the previous seam/cut join to the next one (Split-then-delete).
    mutating func segmentBounds(atOutput t: Double) -> (start: Double, end: Double)? {
        guard let s = recordingSegment(atOutput: t) else { return nil }
        return (s.outputStart, s.outputEnd)
    }

    static func merged(_ cuts: [CutRange]) -> [CutRange] {
        let sorted = cuts.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var out: [CutRange] = []
        for c in sorted {
            if var last = out.last, c.start <= last.end + 0.0005 {
                last.end = max(last.end, c.end)
                out[out.count - 1] = CutRange(id: last.id, start: last.start, end: last.end, origin: last.origin)
            } else { out.append(c) }
        }
        return out
    }

    /// Music/voice-over lanes are bound to the soundtrack, not to content: a
    /// ripple that shortens the timeline moves later lanes left with it and
    /// clamps anything inside the removed span to the new seam. They never
    /// follow picture content.
    mutating func rippleSoundtrack(afterOutput start: Double, by delta: Double) {
        for i in audio.lanes.indices {
            let p = audio.lanes[i].placement
            if p >= start { audio.lanes[i].placement = max(p + delta, 0) }
        }
    }

    // MARK: Anchored content

    /// Remove content anchored to a source span; split anything straddling it.
    /// Masks keep their keys, zooms/ramps/layouts/loupes/highlights/texts keep
    /// their surviving parts. Captions follow source words through TimeMap.
    mutating func trimAnchoredContent(removedSource r: ClosedRange<Double>) {
        let a = r.lowerBound, b = r.upperBound
        func survivors(_ s: Double, _ e: Double) -> [(Double, Double)] {
            if e <= a || s >= b { return [(s, e)] }
            var out: [(Double, Double)] = []
            if s < a - 0.0005 { out.append((s, a)) }
            if e > b + 0.0005 { out.append((b, e)) }
            return out
        }
        overlays.masks = overlays.masks.flatMap { m -> [Mask] in
            survivors(m.start, m.end).enumerated().map { i, span in
                Mask(id: i == 0 ? m.id : UUID(), start: span.0, end: span.1, mode: m.mode,
                     keys: maskKeys(m.keys, in: span.0...span.1), origin: m.origin,
                     approved: m.approved, category: m.category, padding: m.padding)
            }
        }
        zoom = zoom.flatMap { z -> [ZoomSegment] in
            survivors(z.start, z.end).enumerated().map { i, span in
                ZoomSegment(id: i == 0 ? z.id : UUID(), start: span.0, end: span.1, scale: z.scale,
                            focus: z.focus, easing: z.easing, origin: z.origin)
            }
        }
        timeMap.cuts = timeMap.cuts.flatMap { c -> [CutRange] in
            survivors(c.start, c.end).enumerated().map { i, span in
                CutRange(id: i == 0 ? c.id : UUID(), start: span.0, end: span.1, origin: c.origin)
            }
        }
        timeMap.ramps = timeMap.ramps.flatMap { x -> [SpeedRamp] in
            survivors(x.start, x.end).map { SpeedRamp(start: $0.0, end: $0.1, speed: x.speed, origin: x.origin) }
        }
        overlays.highlights = overlays.highlights.flatMap { h -> [Highlight] in
            survivors(h.start, h.end).enumerated().map { i, span in
                Highlight(id: i == 0 ? h.id : UUID(), start: span.0, end: span.1, x: h.x, y: h.y, w: h.w, h: h.h,
                          style: h.style, dim: h.dim)
            }
        }
        overlays.loupes = overlays.loupes.flatMap { l -> [Loupe] in
            survivors(l.start, l.end).enumerated().map { i, span in
                Loupe(id: i == 0 ? l.id : UUID(), start: span.0, end: span.1, x: l.x, y: l.y, follow: l.follow,
                      radius: l.radius, magnification: l.magnification, round: l.round, cx: l.cx, cy: l.cy,
                      border: l.border, shadow: l.shadow)
            }
        }
        layouts = layouts.flatMap { s -> [LayoutSegment] in
            survivors(s.start, s.end).enumerated().map { i, span in
                LayoutSegment(id: i == 0 ? s.id : UUID(), start: span.0, end: span.1, kind: s.kind)
            }
        }
        overlays.texts = overlays.texts.flatMap { t -> [TextBlock] in
            survivors(t.start, t.end).enumerated().map { i, span in
                TextBlock(id: i == 0 ? t.id : UUID(), start: span.0, end: span.1, text: t.text,
                          x: t.x, y: t.y, size: t.size, color: t.color)
            }
        }
    }

    /// Keys inside a surviving half, always non-empty: endpoint interpolation is
    /// not stored, so the nearest boundary key travels with the half.
    private func maskKeys(_ keys: [MaskKey], in range: ClosedRange<Double>) -> [MaskKey] {
        let sorted = keys.sorted { $0.t < $1.t }
        var kept = sorted.filter { $0.t >= range.lowerBound - 0.0005 && $0.t <= range.upperBound + 0.0005 }
        if kept.isEmpty {
            if let near = sorted.min(by: { abs($0.t - range.lowerBound) < abs($1.t - range.lowerBound) }) {
                kept = [near]
            }
        }
        return kept
    }
}
