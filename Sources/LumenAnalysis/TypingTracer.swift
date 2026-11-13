import Foundation
import LumenProject

/// Numbers that drive the pixel typing tracker. Pure values: no I/O, no clock.
public struct TypingTraceSettings: Sendable, Equatable {
    /// Samples per second the decoder aims for inside a burst. The decoder
    /// clamps this to the source frame rate; 10 Hz cannot tell a caret step
    /// from a line wrap, so the default is one sample per source frame up to
    /// 30 Hz.
    public var sampleHz: Double
    /// Longest plausible text line as a fraction of the source height. Taller
    /// changes are page animation or a panel, not a line of text.
    public var maxLineHeightFraction: Double
    /// Rows of tracking slack kept above and below the tracked line.
    public var bandSlackRows: Int
    /// Samples without line evidence before the tracker looks for a new line.
    public var missLimit: Int
    /// Minimum mean-luma move (0...255) for a tile to count as changed.
    public var tileThreshold: Int

    public init(sampleHz: Double = 30, maxLineHeightFraction: Double = 0.08, bandSlackRows: Int = 1,
                missLimit: Int = 8, tileThreshold: Int = 6) {
        self.sampleHz = sampleHz
        self.maxLineHeightFraction = maxLineHeightFraction
        self.bandSlackRows = bandSlackRows
        self.missLimit = missLimit
        self.tileThreshold = tileThreshold
    }

    public static let `default` = TypingTraceSettings()
}

/// Pixel-measured typing anchor (no AX dependency). Pure and unit-testable;
/// the AVAssetReader pipeline that builds the luma grids lives in the
/// analysis service and feeds this tracer.
///
/// The tracker keeps three pieces of state: the line of text it is following,
/// the caret column (the insertion point, in tile units) and the sign of the
/// ink. Every sample is then classified from the *signed* change of the tiles
/// at the caret rather than "the rightmost changed column", so a caret blink, a
/// backspace, a line wrap and a scroll are different observations instead of
/// the same one.
public enum TypingTracer {
    private struct Region {
        var c0: Int, c1: Int, r0: Int, r1: Int, area: Int
        var height: Int { r1 - r0 + 1 }
        var width: Int { c1 - c0 + 1 }
        var centerY: Double { Double(r0 + r1 + 1) / 2 }
    }

    public static func trace(burst: (t0: Double, t1: Double), ts: [Double], grids: [LumaTiles],
                             anchor: SIMD2<Double>?, srcH: Double,
                             settings: TypingTraceSettings = .default) -> TypingTrace? {
        guard ts.count == grids.count, ts.count >= 2, let base = grids.first else { return nil }
        let cols = base.cols, rows = base.rows
        guard cols >= 2, rows >= 1, base.tile > 0 else { return nil }
        let tile = Double(base.tile)
        let maxLineRows = max(Int((settings.maxLineHeightFraction * srcH / tile).rounded()), 1)
        let slack = max(settings.bandSlackRows, 0)
        let threshold = max(settings.tileThreshold, 1)

        func delta(_ k: Int) -> [Int] {
            let previous = grids[max(k - 1, 0)].mean, current = grids[k].mean
            var out = [Int](repeating: 0, count: current.count)
            for i in current.indices { out[i] = Int(current[i]) - Int(previous[i]) }
            return out
        }

        // Ink sign: +1 when appearing text darkens a tile, -1 when it lightens
        // it (dark appearance). Seeded from the first typed glyph and reused.
        var ink = 1
        func appeared(_ d: [Int], _ i: Int) -> Bool { d[i] * ink <= -threshold }
        func vanished(_ d: [Int], _ i: Int) -> Bool { d[i] * ink >= threshold }

        /// `test` receives the tile index.
        func mask(_ d: [Int], _ test: (Int) -> Bool) -> [Bool] {
            var out = [Bool](repeating: false, count: d.count)
            for i in d.indices where test(i) { out[i] = true }
            return out
        }

        func components(_ m: [Bool]) -> [Region] {
            var seen = [Bool](repeating: false, count: m.count), out: [Region] = []
            for start in m.indices where m[start] && !seen[start] {
                var box = Region(c0: start % cols, c1: start % cols, r0: start / cols, r1: start / cols, area: 0)
                var stack = [start]
                seen[start] = true
                while let i = stack.popLast() {
                    let c = i % cols, r = i / cols
                    box.c0 = min(box.c0, c); box.c1 = max(box.c1, c)
                    box.r0 = min(box.r0, r); box.r1 = max(box.r1, r)
                    box.area += 1
                    if c > 0, m[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
                    if c + 1 < cols, m[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
                    if r > 0, m[i - cols], !seen[i - cols] { seen[i - cols] = true; stack.append(i - cols) }
                    if r + 1 < rows, m[i + cols], !seen[i + cols] { seen[i + cols] = true; stack.append(i + cols) }
                }
                out.append(box)
            }
            return out
        }

        func meanDelta(_ region: Region, _ d: [Int]) -> Double {
            var sum = 0.0, n = 0
            for r in region.r0...region.r1 {
                for c in region.c0...region.c1 {
                    let i = r * cols + c
                    if m(d, i) { sum += Double(d[i]); n += 1 }
                }
            }
            return n > 0 ? sum / Double(n) : 0
        }
        // Hot-cell test used only for seeding (polarity unknown yet).
        func m(_ d: [Int], _ i: Int) -> Bool { abs(d[i]) >= threshold }

        func lineLike(_ b: Region) -> Bool {
            b.height <= maxLineRows && b.width <= max(cols / 3, 4)
        }

        /// A typed glyph changes one tile; a page animation changes a block.
        func seedPlausible(_ b: Region) -> Bool {
            b.area <= max(4, cols / 8)
        }

        // A left edge that held still on the previous sample is text; an edge
        // that moves every frame is page animation. The bonus is only used when
        // the tracker has to choose or re-choose a line.
        var leftHistory: [Int: Int] = [:]
        var previousLefts: [Int: Int] = [:]

        func seed(_ regions: [Region], near: Double?) -> Region? {
            let candidates = regions.filter { lineLike($0) && seedPlausible($0) }
            guard !candidates.isEmpty else { return nil }
            if let near, near.isFinite {
                return candidates.min { abs($0.centerY * tile - near) < abs($1.centerY * tile - near) }
            }
            // Stable means the same left edge was there on the previous sample.
            let stable = { (region: Region) -> Bool in previousLefts[region.c0] != nil }
            if let held = candidates.filter(stable).max(by: { $0.area < $1.area }) { return held }
            return candidates.sorted { a, b in a.area != b.area ? a.area > b.area : a.r0 < b.r0 }.first
        }

        func bandRows(_ top: Int, _ height: Int) -> ClosedRange<Int> {
            let lo = max(top - slack, 0), hi = min(top + height - 1 + slack, rows - 1)
            return min(lo, hi)...max(lo, hi)
        }

        func columnRange(_ a: Int, _ b: Int) -> ClosedRange<Int>? {
            let lo = max(a, 0), hi = min(b, cols - 1)
            return lo <= hi ? lo...hi : nil
        }

        func anyAt(_ d: [Int], column: Int, rows range: ClosedRange<Int>, _ test: (Int) -> Bool) -> Bool {
            guard column >= 0, column < cols else { return false }
            for r in range where test(r * cols + column) { return true }
            return false
        }

        func rightmost(_ d: [Int], rows range: ClosedRange<Int>, columns: ClosedRange<Int>, _ test: (Int) -> Bool) -> Int? {
            let lo = max(columns.lowerBound, 0), hi = min(columns.upperBound, cols - 1)
            guard lo <= hi else { return nil }
            for c in stride(from: hi, through: lo, by: -1) {
                for r in range where test(r * cols + c) { return c }
            }
            return nil
        }

        /// The largest signed change in one column of the band.
        func strongest(_ d: [Int], column: Int, rows range: ClosedRange<Int>) -> Int {
            guard column >= 0, column < cols else { return 0 }
            var best = 0
            for r in range {
                let value = d[r * cols + column]
                if abs(value) > abs(best) { best = value }
            }
            return best
        }

        func scrollShift(_ regions: [Region], top: Int, height: Int, left: Int, maxRows: Int) -> Int? {
            let center = Double(top) + Double(height) / 2
            for distance in 1...max(maxRows, 1) {
                for region in regions where lineLike(region) && abs(Double(region.c0) - Double(left)) <= 4 {
                    let delta = region.centerY - center
                    if abs(delta + Double(distance)) < 0.5 { return -distance }
                    if abs(delta - Double(distance)) < 0.5 { return distance }
                }
            }
            return nil
        }

        // ---- tracker state ----
        var lineTop = -1, lineRows = 1, caret = -1, left = 0
        var miss = 0
        var unstable = 0
        /// Typical |delta| of a typed glyph tile; a caret bar is a fraction of it.
        var inkMagnitude = 0
        var lastY = 0.0
        var samples: [TypingTrace.Sample] = []
        // A caret step never jumps more than a few tiles; a moving page does.
        let unstableJump = 5
        let unstableLimit = 3

        func adopt(_ region: Region) {
            lineTop = region.r0
            lineRows = max(region.height, 1)
            left = max(region.c0, 0)
            caret = region.c1 + 1
            miss = 0
            unstable = 0
        }

        func append(_ t: Double, x: Double, y: Double, confidence: Float, evidence: TypingTrace.Evidence) {
            lastY = y
            samples.append(.init(t: t, x: x, y: y, confidence: confidence, evidence: evidence))
        }

        /// A sample for the tracked line at the current caret column.
        func appendLine(_ t: Double, confidence: Float, evidence: TypingTrace.Evidence) {
            let range = bandRows(lineTop, lineRows)
            let y = Double(range.lowerBound + range.upperBound + 1) / 2 * tile
            append(t, x: Double(caret) * tile, y: y, confidence: confidence, evidence: evidence)
        }

        for k in 1..<ts.count {
            let d = delta(k)
            previousLefts = leftHistory
            // Every line-like change is remembered by its left edge so the next
            // choice can prefer an edge that is not moving.
            for region in components(mask(d) { appeared(d, $0) }) where lineLike(region) {
                leftHistory[region.c0] = k
            }

            if lineTop < 0 {
                let hot = mask(d) { abs(d[$0]) >= threshold }
                guard let chosen = seed(components(hot), near: anchor?.y) else {
                    if !samples.isEmpty {
                        append(ts[k], x: Double(caret + 1) * tile, y: lastY, confidence: 0.15, evidence: .held)
                    }
                    continue
                }
                // Polarity is measured, not assumed: light-on-dark screens exist.
                let sign = meanDelta(chosen, d)
                if sign > 0 { ink = -1 } else if sign < 0 { ink = 1 }
                inkMagnitude = max(Int(abs(sign)), threshold + 1)
                adopt(chosen)
                appendLine(ts[k], confidence: 0.90, evidence: .caret)
                continue
            }

            let appearMask = mask(d) { appeared(d, $0) }
            let appearComps = components(appearMask)
            let vanishComps = components(mask(d) { vanished(d, $0) })
            let range = bandRows(lineTop, lineRows)

            var confidence: Float = 0.2
            var evidence: TypingTrace.Evidence = .held
            var found = false
            var next = caret

            // The signed change at a column decides what happened there: ink
            // appearing is a glyph (or the caret), ink leaving is a deletion.
            let atCaret = strongest(d, column: caret, rows: range)
            let atPrev = caret - 1 >= 0 ? strongest(d, column: caret - 1, rows: range) : 0
            let barLimit = max(Int(Double(inkMagnitude) * 0.45), 1)

            if abs(atCaret) >= threshold, abs(atCaret) > barLimit, atCaret * ink < 0 {
                next = caret + 1; confidence = 0.95; evidence = .caret; found = true
                inkMagnitude = Int(Double(inkMagnitude) * 0.7 + Double(abs(atCaret)) * 0.3)
            } else if abs(atPrev) >= threshold, abs(atPrev) > barLimit, atPrev * ink < 0 {
                next = caret - 1; confidence = 0.70; evidence = .caret; found = true   // caret moved left
            } else if abs(atPrev) >= threshold, abs(atPrev) > barLimit {
                next = caret - 1; confidence = 0.65; evidence = .backspace; found = true
            } else if abs(atCaret) >= threshold {
                confidence = 0.40; evidence = .blink; found = true      // the caret toggled in place
            } else if let columns = columnRange(left, caret - 2),
                      let mid = rightmost(d, rows: range, columns: columns, { appeared(d, $0) }) {
                // A glyph appearing far from the caret is another surface
                // animating, not typing: it is evidence against this line.
                if abs(mid - caret) > unstableJump {
                    unstable += 1
                    confidence = 0.15; evidence = .held
                } else {
                    next = mid + 1; confidence = 0.70; evidence = .caret; found = true
                }
            } else if let columns = columnRange(left, caret - 1),
                      let gone = rightmost(d, rows: range, columns: columns, { vanished(d, $0) }) {
                if abs(gone - caret) > unstableJump {
                    unstable += 1
                    confidence = 0.15; evidence = .held
                } else {
                    next = min(caret, gone); confidence = 0.55; evidence = .backspace; found = true
                }
            }

            // Three samples whose changes jump across the line mean this is not
            // a caret: drop the band and choose again, now that a stable left
            // edge has been seen.
            if unstable >= unstableLimit {
                lineTop = -1
                miss = 0
                unstable = 0
                continue
            }

            // A newline: text begins just under the tracked line, near its left edge.
            if !found {
                let below = appearComps.filter {
                    lineLike($0) && $0.r0 >= lineTop + lineRows && $0.r0 <= lineTop + lineRows + maxLineRows + 1
                        && abs($0.c0 - left) <= 4
                }.sorted { $0.r0 < $1.r0 }
                if let wrap = below.first {
                    adopt(wrap)
                    next = caret
                    confidence = 0.90; evidence = .lineWrap; found = true
                }
            }

            // A scroll: the whole line moves vertically with its content.
            if !found {
                let motion = appearComps + vanishComps
                if let shift = scrollShift(motion, top: lineTop, height: lineRows, left: left,
                                           maxRows: 4 * maxLineRows) {
                    lineTop += shift
                    confidence = 0.50; evidence = .scroll; found = true
                }
            }

            // Lost the line (field changed, scrolled away): look again near it.
            if !found {
                miss += 1
                if miss >= settings.missLimit {
                    let limit = 4 * max(lineRows, 1) * Int(tile)
                    let near = appearComps.filter { lineLike($0) && abs($0.centerY * tile - lastY) <= Double(limit) }
                    if let again = seed(near, near: lastY) {
                        adopt(again)
                        confidence = 0.45; evidence = .reacquired; found = true
                    }
                }
            }

            if found {
                caret = min(max(next, 0), cols - 1)
                unstable = 0
            } else {
                confidence = 0.15; evidence = .held
            }
            appendLine(ts[k], confidence: confidence, evidence: evidence)
        }

        guard !samples.isEmpty, lineTop >= 0 else { return nil }
        let box = CGRect(x: Double(left) * tile, y: Double(lineTop) * tile,
                         width: max(Double(caret - left + 1) * tile, tile),
                         height: Double(lineRows) * tile)
        return TypingTrace(t0: burst.t0, t1: burst.t1, rect: box, samples: samples, line: box)
    }
}