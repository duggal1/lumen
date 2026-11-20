import Accelerate
import AppKit
import CoreGraphics
import Foundation

/// The timeline's pixel instrument, ported from Clove's `StorageBarRenderer`.
/// A 4pt lattice of square cells, dithered against a 4×4 Bayer matrix. A cell
/// belongs to whatever sits over its centre; when that changes the cell runs
/// white-hot (graphite) or deep-hot (paper) and cools back to its hue, so a
/// pan, a zoom or a new clip shows a bright marching front. Cleared cells shed
/// loose motes before the space goes dark.
///
/// The CPU only draws what changes. The view stacks the results on the GPU: a
/// blurred glow under, the dithered cells, then seams and motes on top.
final class TimelineDitherRenderer {
    struct Span {
        var col0: Int
        var col1: Int
        var hue: Int
        var level: Float
        init(_ c0: Int, _ c1: Int, _ hue: Int, _ level: Float = 1) {
            col0 = c0; col1 = c1; self.hue = hue; self.level = level
        }
    }

    struct Frame {
        /// Column spans per lane: 0 clips, 1 zoom, 2 events, 3 voice, 4 music.
        var spans: [[Span]]
        /// Voice peaks per column (0...1), mirrored into the voice band.
        var peaks: [Float]
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
    private let colors: [RGB], hot: [RGB], colorRefs: [CGColor]
    private let empty: RGB, emptyAlpha: Float, seam: CGColor

    private var kind: [Int8]
    private var heat: [Float]
    private var motes: [Mote] = []
    private var edges: [[Int]] = []

    private let cellsWidth: Int, cellsHeight: Int
    private let cells: UnsafeMutablePointer<UInt8>
    private let glowWidth: Int, glowHeight: Int
    private let glowPixels: UnsafeMutablePointer<UInt8>, glowScratch: UnsafeMutablePointer<UInt8>
    private let cellsContext: CGContext, glowContext: CGContext, overlayContext: CGContext

    init?(width: CGFloat, height: CGFloat, scale: CGFloat, isDark: Bool) {
        self.width = max(40, width.rounded(.down))
        self.height = height
        self.scale = min(2, max(1, scale))
        self.isDark = isDark
        cols = max(1, Int((self.width - 2 * Self.inset) / Self.pitch))
        rows = Self.rowsPerLane * Self.lanes
        let palette = isDark ? Self.hues : Self.lightHues
        colors = palette.map { RGB(r: Float($0.0 * 255), g: Float($0.1 * 255), b: Float($0.2 * 255)) }
        // White-hot on graphite; on paper white would vanish, so cells run deep.
        hot = colors.map { isDark ? RGB(r: 255, g: 255, b: 255) : RGB(r: $0.r * 0.42, g: $0.g * 0.42, b: $0.b * 0.42) }
        colorRefs = palette.map { CGColor(colorSpace: Self.space, components: [$0.0, $0.1, $0.2, 1]) ?? CGColor(gray: 1, alpha: 1) }
        empty = isDark ? RGB(r: 255, g: 255, b: 255) : RGB(r: 0, g: 0, b: 0)
        emptyAlpha = isDark ? 18 : 24
        seam = isDark ? CGColor(gray: 1, alpha: 0.6) : CGColor(gray: 0, alpha: 0.22)
        kind = [Int8](repeating: -1, count: cols * rows)
        heat = [Float](repeating: 0, count: cols * rows)

        cellsWidth = Int((self.width * self.scale).rounded())
        cellsHeight = Int((height * self.scale).rounded())
        cells = .allocate(capacity: cellsWidth * cellsHeight * 4)
        glowWidth = cols + Self.glowPad * 2
        glowHeight = rows + Self.glowPad * 2
        glowPixels = .allocate(capacity: glowWidth * glowHeight * 4)
        glowScratch = .allocate(capacity: glowWidth * glowHeight * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let c1 = CGContext(data: cells, width: cellsWidth, height: cellsHeight, bitsPerComponent: 8,
                                 bytesPerRow: cellsWidth * 4, space: Self.space, bitmapInfo: info),
              let c2 = CGContext(data: glowPixels, width: glowWidth, height: glowHeight, bitsPerComponent: 8,
                                 bytesPerRow: glowWidth * 4, space: Self.space, bitmapInfo: info),
              let c3 = CGContext(data: nil, width: cellsWidth, height: cellsHeight, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: Self.space, bitmapInfo: info) else {
            cells.deallocate(); glowPixels.deallocate(); glowScratch.deallocate()
            return nil
        }
        cellsContext = c1; glowContext = c2; overlayContext = c3
    }

    deinit { cells.deallocate(); glowPixels.deallocate(); glowScratch.deallocate() }

    /// Rasterizes one frame into the three compositing layers.
    @_optimize(speed)
    func draw(_ f: Frame) -> Output {
        let insetF = Float(Self.inset), topF = Float(Self.top), laneF = Float(Self.laneHeight)
        let cool = Float(exp(-f.dt / 0.42))
        let dt = Float(f.dt)
        let drift = Float(f.t) * 0.28
        let pitch = Float(Self.pitch)
        let s = Float(scale)
        let px = s * pitch
        let lit = max(2, Int((3 * s).rounded()))
        let dim = max(1, Int((1.5 * s).rounded()))
        let litOff = Int(((px - Float(lit)) / 2).rounded())
        let dimOff = Int(((px - Float(dim)) / 2).rounded())
        memset(cells, 0, cellsWidth * cellsHeight * 4)
        memset(glowPixels, 0, glowWidth * glowHeight * 4)

        // Per-lane column ownership, resolved once per frame.
        edges = f.spans.map { spans in
            var row = [Int](repeating: -1, count: cols)
            for span in spans {
                for c in max(0, span.col0)..<min(cols, span.col1) { row[c] = span.hue }
            }
            return row
        }

        var lc = 0
        for lane in 0..<Self.lanes {
            let owners = edges[lane]
            for r in 0..<Self.rowsPerLane {
                let row = lane * Self.rowsPerLane + r
                for col in 0..<cols {
                    let n = row * cols + col
                    var want = owners[col]
                    var base: Float = 1
                    // Voice is a mirrored peak tape rather than a flat run.
                    if lane == 3, want >= 0, col < f.peaks.count {
                        let peak = f.peaks[col]
                        let fromMid = abs(Float(r) - 4.5) / 4.5
                        want = peak > 0.02 && fromMid <= peak ? want : -1
                        base = 0.7 + 0.3 * peak
                    }
                    // Clicks are one tall violet slat in the events band.
                    if lane == 2, f.clicks.contains(col) { want = 3; base = 1 }

                    let had = kind[n]
                    if had != want {
                        if had >= 0, had != 6, motes.count < 900, Float.random(in: 0..<1) < 0.32 {
                            let mx = insetF + Float(col) * pitch + pitch / 2
                            let laneTop = topF + Float(lane) * laneF
                            let my = laneTop + Float(r) * pitch + pitch / 2
                            motes.append(Mote(x: mx,
                                              y: my,
                                              vx: (Float.random(in: 0..<1) - 0.5) * 22,
                                              vy: -(16 + Float.random(in: 0..<1) * 52),
                                              age: 0, life: 0.5 + Float.random(in: 0..<1) * 0.8, hue: had))
                        }
                        kind[n] = Int8(want)
                        // Reduce Motion (and the very first frame) show the
                        // finished frame directly instead of a hot reveal.
                        heat[n] = want >= 0 && !f.reduced ? 1 : 0
                    } else if heat[n] > 0 {
                        heat[n] *= cool
                        if heat[n] < 0.001 { heat[n] = 0 }
                    }

                    let xf = insetF + Float(col) * pitch
                    let x0 = Int(xf * s)
                    let laneTop = topF + Float(lane) * laneF
                    let yf = laneTop + Float(r) * pitch
                    let y0 = Int(yf * s)
                    guard want >= 0 else {
                        put(x0 + dimOff, y0 + dimOff, dim, empty.r, empty.g, empty.b, emptyAlpha)
                        lc += 1
                        continue
                    }
                    let edge = exp(-min(Float(r), 9 - Float(r)) / 3.2)
                    let cloud = Self.noise(Float(col) * 0.05 - drift, Float(r) * 0.12 + drift * 0.3) * 0.6
                    let level = -0.02 + 0.52 * edge + 0.34 * Self.smooth(Self.clamp01((cloud - 0.4) / 0.4)) * base
                        + 0.58 * heat[n] + 0.2 * base
                    let threshold = Self.bayer[(r & 3) * 4 + (col & 3)]
                    let c = colors[want]
                    if level > threshold || f.playing && col == f.head {
                        let wt = min(1, heat[n] * 0.95)
                        let target = hot[want]
                        let rr = c.r + (target.r - c.r) * wt
                        let gg = c.g + (target.g - c.g) * wt
                        let bb = c.b + (target.b - c.b) * wt
                        put(x0 + litOff, y0 + litOff, lit, rr, gg, bb, 240)
                        let q = ((row + Self.glowPad) * glowWidth + col + Self.glowPad) * 4
                        glowPixels[q] = UInt8(min(255, rr * 0.9))
                        glowPixels[q + 1] = UInt8(min(255, gg * 0.9))
                        glowPixels[q + 2] = UInt8(min(255, bb * 0.9))
                        glowPixels[q + 3] = 165
                    } else {
                        put(x0 + dimOff, y0 + dimOff, dim, c.r, c.g, c.b, 68)
                    }
                    lc += 1
                }
            }
        }
        _ = lc
        blurGlow()
        let overlay = drawOverlay(dt: dt)
        // Motes spawned this frame and cells still cooling both keep the loop alive.
        var warm = !motes.isEmpty
        if !warm {
            for n in 0..<kind.count where heat[n] > 0.02 { warm = true; break }
        }
        return Output(cells: cellsContext.makeImage(), glow: glowContext.makeImage(), overlay: overlay, isWarm: warm)
    }

    /// Seams between neighbouring hues, and the motes rising off cleared cells.
    @_optimize(speed)
    private func drawOverlay(dt: Float) -> CGImage? {
        overlayContext.clear(CGRect(x: 0, y: 0, width: cellsWidth, height: cellsHeight))
        let ctx = overlayContext
        ctx.setLineWidth(scale)
        let p = Float(Self.pitch)
        let insetF = Float(Self.inset)
        let topF = Float(Self.top)
        let laneF = Float(Self.laneHeight)
        let scaleF = Float(scale)
        for lane in 0..<Self.lanes {
            let owners = edges[lane]
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
        var index = 0
        while index < motes.count {
            motes[index].age += dt
            if motes[index].age >= motes[index].life {
                motes.swapAt(index, motes.count - 1); motes.removeLast(); continue
            }
            var m = motes[index]
            m.vy -= 26 * dt
            m.vx *= exp(-dt * 1.5)
            m.x += m.vx * dt
            m.y += m.vy * dt
            motes[index] = m
            let u = m.age / m.life
            let c = colors[Int(m.hue)]
            let rr = CGFloat(c.r / 255), gg = CGFloat(c.g / 255), bb = CGFloat(c.b / 255)
            let alpha = CGFloat(pow(1 - u, 1.4))
            ctx.setFillColor(red: rr, green: gg, blue: bb, alpha: alpha)
            let shrink = CGFloat(1 - u * 0.4)
            let size = 3 * scale * shrink
            let mx = CGFloat((m.x * 2).rounded() / 2) * scale
            let my = CGFloat((m.y * 2).rounded() / 2) * scale
            ctx.fill(CGRect(x: mx - size / 2, y: my - size / 2, width: size, height: size))
            index += 1
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

    /// Three 5×5 box passes in SIMD: the pasted renderer's soft CSS-like blur.
    private func blurGlow() {
        var src = vImage_Buffer(data: glowPixels, height: vImagePixelCount(glowHeight), width: vImagePixelCount(glowWidth), rowBytes: glowWidth * 4)
        var tmp = vImage_Buffer(data: glowScratch, height: vImagePixelCount(glowHeight), width: vImagePixelCount(glowWidth), rowBytes: glowWidth * 4)
        let flags = vImage_Flags(kvImageEdgeExtend)
        vImageBoxConvolve_ARGB8888(&src, &tmp, nil, 0, 0, 5, 5, nil, flags)
        vImageBoxConvolve_ARGB8888(&tmp, &src, nil, 0, 0, 5, 5, nil, flags)
        vImageBoxConvolve_ARGB8888(&src, &tmp, nil, 0, 0, 5, 5, nil, flags)
        memcpy(glowPixels, glowScratch, glowWidth * glowHeight * 4)
    }

    @inline(__always) private static func clamp01(_ v: Float) -> Float { v < 0 ? 0 : v > 1 ? 1 : v }
    @inline(__always) private static func smooth(_ t: Float) -> Float { t * t * (3 - 2 * t) }
    @_optimize(speed) @inline(__always)
    private static func hash(_ x: Int32, _ y: Int32) -> Float {
        var h = UInt32(bitPattern: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / 16_777_216
    }
    @_optimize(speed) @inline(__always)
    private static func noise(_ x: Float, _ y: Float) -> Float {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int32(fx), iy = Int32(fy)
        let u = smooth(x - fx), v = smooth(y - fy)
        let a = hash(ix, iy), b = hash(ix &+ 1, iy), c = hash(ix, iy &+ 1), d = hash(ix &+ 1, iy &+ 1)
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }
}

private struct RGB { let r: Float, g: Float, b: Float }
private struct Mote { var x: Float, y: Float, vx: Float, vy: Float, age: Float, life: Float, hue: Int8 }
