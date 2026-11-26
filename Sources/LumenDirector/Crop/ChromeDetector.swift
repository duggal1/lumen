import Foundation
import CoreGraphics
import os
import LumenCore

/// Vision fallback for locating the content area of a captured window when
/// Accessibility cannot describe an AXWebArea (untrusted AX, a native app, or
/// a browser that has not populated its tree yet).
///
/// Chrome (tab strip, address bar, toolbar, dock-adjacent bands) is dense in
/// horizontal/vertical edges; page body is sparse. The detector reduces an
/// edge map to a grid, finds the largest contiguous low-edge band on each
/// axis, and returns that band as a **true source-pixel crop rect** — the
/// compositor fits it to the output frame, nothing here is a camera zoom.
///
/// Pure and deterministic. Ownership: none. Threading: callable on any queue.
public enum ChromeDetector {
    private static let signpost = OSLog(subsystem: "com.lumen.studio", category: "crop.vision")

    public struct Settings: Sendable, Equatable {
        /// A row/column whose mean edge energy is strictly above this value is
        /// treated as chrome. 0.75 separates a solid toolbar from page text.
        public var chromeThreshold: Double
        /// Minimum run length, in grid cells, for a band to count as content.
        public var minExtent: Int

        public init(chromeThreshold: Double = 0.75, minExtent: Int = 2) {
            self.chromeThreshold = chromeThreshold
            self.minExtent = max(1, minExtent)
        }
    }

    /// Content band from a precomputed edge grid (row-major, `gridW` columns
    /// per row). Values are edge energies in 0...1. Returns `nil` when the grid
    /// is entirely chrome or malformed, so callers keep the full frame rather
    /// than guessing a crop.
    public static func contentRect(edges: [Float], gridW: Int, gridH: Int,
                                   window: PxRect, s: Settings = Settings()) -> PxRect? {
        os_signpost(.begin, log: signpost, name: "chrome.detect.grid")
        defer { os_signpost(.end, log: signpost, name: "chrome.detect.grid") }
        guard gridW > 1, gridH > 1, window.isValid, edges.count >= gridW * gridH else { return nil }
        let threshold = s.chromeThreshold.isFinite ? s.chromeThreshold : 0.75

        var rowEnergy = [Double](repeating: 0, count: gridH)
        var colEnergy = [Double](repeating: 0, count: gridW)
        for r in 0..<gridH {
            for c in 0..<gridW {
                let e = Double(edges[r * gridW + c])
                rowEnergy[r] += e / Double(gridW)
                colEnergy[c] += e / Double(gridH)
            }
        }
        // A band is content when it is NOT chrome.
        guard let rows = longestBand(rowEnergy.map { $0 <= threshold }, minExtent: s.minExtent),
              let cols = longestBand(colEnergy.map { $0 <= threshold }, minExtent: s.minExtent) else { return nil }
        let cellW = window.w / Double(gridW), cellH = window.h / Double(gridH)
        let rect = PxRect(x: window.x + Double(cols.lowerBound) * cellW,
                          y: window.y + Double(rows.lowerBound) * cellH,
                          w: Double(cols.count) * cellW,
                          h: Double(rows.count) * cellH)
        return rect.isValid ? rect.intersection(window) : nil
    }

    /// Sobel-magnitude edge grid from a small luminance image (one byte per
    /// pixel, row-major). Exposed so the live capture path can build the grid
    /// once and pass the SAME evidence through `CropPlanner.contentRect(fromEdges:)`
    /// that the offline path uses — no second detector implementation.
    public static func edgeGrid(pixels: [UInt8], width: Int, height: Int,
                                gridW: Int, gridH: Int) -> [Float]? {
        guard width > 2, height > 2, gridW > 1, gridH > 1,
              pixels.count >= width * height else { return nil }
        var edges = [Float](repeating: 0, count: gridW * gridH)
        var counts = [Int](repeating: 0, count: gridW * gridH)
        for y in 1..<(height - 1) {
            let gy = min((y * gridH) / height, gridH - 1)
            for x in 1..<(width - 1) {
                let gx = min((x * gridW) / width, gridW - 1)
                let idx = y * width + x
                let gxMag = Int(pixels[idx + 1]) - Int(pixels[idx - 1])
                let gyMag = Int(pixels[idx + width]) - Int(pixels[idx - width])
                let mag = min(255, abs(gxMag) + abs(gyMag))
                let cell = gy * gridW + gx
                edges[cell] += Float(mag) / 255.0
                counts[cell] += 1
            }
        }
        for i in edges.indices where counts[i] > 0 { edges[i] /= Float(counts[i]) }
        return edges
    }

    /// Content band from raw 8-bit luminance of a downsampled frame. Computes
    /// a Sobel-magnitude edge grid, then delegates to `contentRect(edges:...)`.
    /// This is the entry point for the capture-side fallback: it needs only
    /// pixels, which ScreenCaptureKit always provides even without AX.
    public static func contentRect(pixels: [UInt8], width: Int, height: Int,
                                   gridW: Int = 12, gridH: Int = 8,
                                   window: PxRect, s: Settings = Settings()) -> PxRect? {
        guard let edges = edgeGrid(pixels: pixels, width: width, height: height,
                                   gridW: gridW, gridH: gridH) else { return nil }
        return contentRect(edges: edges, gridW: gridW, gridH: gridH, window: window, s: s)
    }

    /// Longest contiguous run of `true` values at least `minExtent` long.
    /// Ties resolve to the earliest run so the result is bit-for-bit stable.
    static func longestBand(_ flags: [Bool], minExtent: Int) -> Range<Int>? {
        var best: Range<Int>?
        var start: Int?
        for i in 0...flags.count {
            let on = i < flags.count && flags[i]
            if on, start == nil { start = i }
            if !on, let a = start {
                let run = a..<i
                if run.count >= minExtent,
                   best == nil || run.count > best!.count { best = run }
                start = nil
            }
        }
        return best
    }
}
