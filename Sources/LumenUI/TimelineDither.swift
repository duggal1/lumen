import AppKit
import CoreGraphics
import Foundation

/// Deterministic viewport raster. Panning is a projection change, not deletion.
final class TimelineDitherRenderer {
    struct Span: Equatable {
        var col0: Int
        var col1: Int
        var hue: Int
        var level: Float
        init(_ c0: Int, _ c1: Int, _ hue: Int, _ level: Float = 1) {
            col0 = c0; col1 = c1; self.hue = hue; self.level = level
        }
    }

    struct Frame: Equatable {
        /// Column spans per lane: 0 clips, 1 zoom, 2 events, 3 voice, 4 music.
        var spans: [[Span]]
        /// Voice peaks per column (0...1), mirrored into the voice band.
        var peaks: [Float]
        /// Real music source peaks, not synthesized decoration.
        var musicPeaks: [Float] = []
        /// Columns carrying a click or tap in the events band.
        var clicks: Set<Int>
        /// The playhead column, or -1.
        var head: Int
        var playing: Bool
        var reduced: Bool
        var dt: Double
        var t: Double
    }

    struct Output {
        let cells: CGImage?
        let glow: CGImage?
        let overlay: CGImage?
        let isWarm: Bool
    }

    static let pitch: CGFloat = 4
    static let cell: CGFloat = 3
    /// Matches `TimelineStrip.Lattice`: 8 pt card inset + 8 pt lattice pad.
    static let inset: CGFloat = 16
    static let top: CGFloat = 24  // the ruler sits above lane zero
    static let laneHeight: CGFloat = 40
    static let lanes = 5
    static let glowPad = 6
    private static let rowsPerLane = Int(laneHeight / pitch) // 10
    private static let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    /// Bayer 4×4, in the same order as Clove.
    private static let bayer: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { (Float($0) + 0.5) / 16 }

    /// Clove's `StorageHue` set, expressed in the same Display P3 space the
    /// pasted renderer draws into. Media roles keep their identity: clips
    /// blue, imports green, zoom orange, clicks violet, voice cyan, music pink,
    /// cuts rose, system grey.
    static let hues: [(Double, Double, Double)] = [
        (0.349, 0.612, 1.000), // 0 clip / blue
        (0.436, 0.855, 0.453), // 1 import / green
        (0.982, 0.558, 0.233), // 2 zoom / orange
        (0.639, 0.449, 1.000), // 3 clicks / violet
        (0.332, 0.826, 0.946), // 4 voice / cyan
        (0.946, 0.404, 0.691), // 5 music / pink
        (0.941, 0.328, 0.284), // 6 cut / rose
        (178 / 255, 186 / 255, 200 / 255), // 7 neutral
    ]
    /// Deeper on paper so dithered cells keep contrast outside graphite chrome.
    static let lightHues: [(Double, Double, Double)] = [
        (0.012, 0.471, 0.906), (0.000, 0.639, 0.227), (0.910, 0.404, 0.000),
        (0.533, 0.282, 0.882), (0.000, 0.627, 0.729), (0.878, 0.212, 0.580),
        (0.886, 0.208, 0.196), (0.557, 0.557, 0.573),
    ]

    let width: CGFloat, height: CGFloat, scale: CGFloat
    let isDark: Bool
    private let cols: Int
    private let rows: Int
    private let colors: [RGB]
    private let empty: RGB, emptyAlpha: Float, seam: CGColor

    private let cellsWidth: Int, cellsHeight: Int
    private let cells: UnsafeMutablePointer<UInt8>
    private let cellsContext: CGContext, overlayContext: CGContext

    init?(width: CGFloat, height: CGFloat, scale: CGFloat, isDark: Bool) {
        self.width = max(40, width.rounded(.down))
        self.height = height
        self.scale = min(2, max(1, scale))
        self.isDark = isDark
        cols = max(1, Int((self.width - 2 * Self.inset) / Self.pitch))
        rows = Self.rowsPerLane * Self.lanes
        let palette = isDark ? Self.hues : Self.lightHues
        colors = palette.map { RGB(r: Float($0.0 * 255), g: Float($0.1 * 255), b: Float($0.2 * 255)) }
        empty = isDark ? RGB(r: 255, g: 255, b: 255) : RGB(r: 0, g: 0, b: 0)
        emptyAlpha = isDark ? 18 : 24
        seam = isDark ? CGColor(gray: 1, alpha: 0.6) : CGColor(gray: 0, alpha: 0.22)
        cellsWidth = Int((self.width * self.scale).rounded())
        cellsHeight = Int((height * self.scale).rounded())
        cells = .allocate(capacity: cellsWidth * cellsHeight * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let c1 = CGContext(data: cells, width: cellsWidth, height: cellsHeight, bitsPerComponent: 8,
                                 bytesPerRow: cellsWidth * 4, space: Self.space, bitmapInfo: info),
              let c3 = CGContext(data: nil, width: cellsWidth, height: cellsHeight, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: Self.space, bitmapInfo: info) else {
            cells.deallocate()
            return nil
        }
        cellsContext = c1; overlayContext = c3
    }

    deinit { cells.deallocate() }

    /// Rasterizes one frame into deterministic cell and seam layers.
    @_optimize(speed)
    func draw(_ f: Frame) -> Output {
        let insetF = Float(Self.inset), topF = Float(Self.top), laneF = Float(Self.laneHeight)
        let pitch = Float(Self.pitch)
        let s = Float(scale)
        let px = s * pitch
        let lit = max(2, Int((3 * s).rounded()))
        let dim = max(1, Int((1.5 * s).rounded()))
        let litOff = Int(((px - Float(lit)) / 2).rounded())
        let dimOff = Int(((px - Float(dim)) / 2).rounded())
        memset(cells, 0, cellsWidth * cellsHeight * 4)

        // Per-lane column ownership, resolved once per frame.
        var resolved = f.spans.map { spans -> [Int] in
            var row = [Int](repeating: -1, count: cols)
            for span in spans {
                let from = max(0, span.col0), to = min(cols, span.col1)
                guard to > from else { continue }
                for c in from..<to { row[c] = span.hue }
            }
            return row
        }
        // A frame with fewer lanes must never index past the lane table.
        while resolved.count < Self.lanes { resolved.append([Int](repeating: -1, count: cols)) }

        for lane in 0..<Self.lanes {
            let owners = resolved[lane]
            if lane == 3 || lane == 4 {
                // Preserve the lane's 40 pt height and 4 pt time lattice.
                // A finer vertical amplitude grid makes the real waveform
                // readable even at quiet levels, without inventing signal.
                let cell = max(1, Int((1.5 * s).rounded()))
                let gap = max(1, Int((2 * s).rounded()))
                let labelSpace: Float = lane == 4 ? 12 : 0
                let middle = Int((topF + Float(lane) * laneF + laneF / 2 + labelSpace / 2) * s)
                let maxSteps = max(1, Int((laneF / 2 - 2 - labelSpace / 2) * s) / gap)
                let c = colors[lane == 3 ? 4 : 5]
                let peaks = lane == 3 ? f.peaks : f.musicPeaks
                for col in 0..<cols {
                    guard owners[col] >= 0, col < peaks.count, peaks[col].isFinite else { continue }
                    let peak = min(max(peaks[col], 0), 1)
                    let x = Int((insetF + Float(col) * pitch) * s) + dimOff
                    let steps = Int((peak * Float(maxSteps)).rounded(.up))
                    guard peak > 0.005, steps > 0 else {
                        put(x, middle, cell, empty.r, empty.g, empty.b, 40)
                        continue
                    }
                    for step in 0..<steps {
                        let fraction = Float(step) / Float(max(maxSteps - 1, 1))
                        let alpha: Float = 255 - 36 * fraction
                        put(x, middle - (step + 1) * gap, cell, c.r, c.g, c.b, alpha)
                        put(x, middle + step * gap, cell, c.r, c.g, c.b, alpha)
                    }
                }
                continue
            }
            for r in 0..<Self.rowsPerLane {
                for col in 0..<cols {
                    var want = owners[col]
                    var base: Float = 1
                    // Clicks are one tall violet slat in the events band.
                    if lane == 2, f.clicks.contains(col) { want = 3; base = 1 }

                    let xf = insetF + Float(col) * pitch
                    let x0 = Int(xf * s)
                    let laneTop = topF + Float(lane) * laneF
                    let yf = laneTop + Float(r) * pitch
                    let y0 = Int(yf * s)
                    guard want >= 0 else {
                        put(x0 + dimOff, y0 + dimOff, dim, empty.r, empty.g, empty.b, emptyAlpha)
                        continue
                    }
                    guard colors.indices.contains(want) else { continue }
                    let c = colors[want]
                    // Bright, mirrored audio amplitude; the other lanes keep
                    // their existing Bayer identity and media-role hues.
                    let threshold = Self.bayer[(r & 3) * 4 + (col & 3)]
                    let level: Float = 0.64 + 0.22 * base
                    if level > threshold || (f.playing && col == f.head) {
                        put(x0 + litOff, y0 + litOff, lit, c.r, c.g, c.b, 250)
                    } else {
                        put(x0 + dimOff, y0 + dimOff, dim, c.r, c.g, c.b, 90)
                    }
                }
            }
        }
        // The cell context is backed by the raw buffers above.
        // `makeImage()` is copy-on-write, so handing those images to the view
        // would leave CoreAnimation reading memory this renderer owns and
        // frees on replacement. Copy into contexts that own their storage:
        // the returned images must outlive this renderer.
        return Output(cells: ownedImage(cellsContext, width: cellsWidth, height: cellsHeight),
                      glow: nil, overlay: drawOverlay(resolved), isWarm: false)
    }

    private func ownedImage(_ source: CGContext, width: Int, height: Int) -> CGImage? {
        guard let snapshot = source.makeImage(),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: Self.space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(snapshot, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Seams between neighbouring media roles.
    @_optimize(speed)
    private func drawOverlay(_ edges: [[Int]]) -> CGImage? {
        overlayContext.clear(CGRect(x: 0, y: 0, width: cellsWidth, height: cellsHeight))
        let ctx = overlayContext
        ctx.setLineWidth(scale)
        let p = Float(Self.pitch)
        let insetF = Float(Self.inset)
        let topF = Float(Self.top)
        let laneF = Float(Self.laneHeight)
        let scaleF = Float(scale)
        for lane in 0..<min(Self.lanes, edges.count) {
            let owners = edges[lane]
            guard owners.count == cols else { continue }
            for col in 1..<cols where owners[col] >= 0 && owners[col] != owners[col - 1] {
                let xf = (insetF + Float(col) * p) * scaleF
                let yf = (topF + Float(lane) * laneF + p) * scaleF
                let h = Float(Self.rowsPerLane) * p * scaleF - 2 * scaleF
                ctx.beginPath()
                ctx.setStrokeColor(seam.copy(alpha: seam.alpha * 0.45) ?? seam)
                ctx.move(to: CGPoint(x: CGFloat(xf), y: CGFloat(yf)))
                ctx.addLine(to: CGPoint(x: CGFloat(xf), y: CGFloat(yf + h)))
                ctx.strokePath()
            }
        }
        return ctx.makeImage()
    }

    @_optimize(speed) @inline(__always)
    private func put(_ x0: Int, _ y0: Int, _ size: Int, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
        let alpha = max(0, min(255, a)), f = alpha / 255
        let pr = UInt8(min(255, r * f)), pg = UInt8(min(255, g * f)), pb = UInt8(min(255, b * f))
        let pa = UInt8(alpha)
        let xe = min(cellsWidth, x0 + size), ye = min(cellsHeight, y0 + size)
        guard x0 >= 0, y0 >= 0, x0 < xe, y0 < ye else { return }
        for y in y0..<ye {
            var o = (y * cellsWidth + x0) * 4
            for _ in x0..<xe {
                cells[o] = pr; cells[o + 1] = pg; cells[o + 2] = pb; cells[o + 3] = pa; o += 4
            }
        }
    }

}

private struct RGB { let r: Float, g: Float, b: Float }