import Foundation
import Testing
import AppKit
import CoreGraphics
@testable import LumenUI

/// Headless raster evidence for the two right-rail instruments: the music
/// waveform and the colorful export band. Both use the timeline's renderer.
@Suite("Right rail dither evidence")
struct DitherRailEvidence {
    @Test func writeInstruments() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent(".proof")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Music: a pink waveform with a real amplitude envelope.
        if let r = TimelineDitherRenderer(width: 600, height: 44, scale: 2, isDark: true,
                                          layout: TimelineDitherRenderer.waveformLayout) {
            let cols = max(1, Int((600 - 32) / 4))
            let peaks = (0..<cols).map { c -> Float in
                let v = abs(sin(Float(c) * 0.08) * cos(Float(c) * 0.021))
                return 0.08 + 0.85 * v
            }
            let f = TimelineDitherRenderer.Frame(spans: [[TimelineDitherRenderer.Span(0, cols, 5)]], peaks: peaks,
                clicks: [], head: 90, playing: false, reduced: true, dt: 0, t: 1)
            try composite(r.draw(f), dark: true, at: dir.appendingPathComponent("rail-waveform.png"))
        }

        // Export: six hues, a hot front at 62%.
        if let r = TimelineDitherRenderer(width: 600, height: 68, scale: 2, isDark: true,
                                          layout: TimelineDitherRenderer.Layout(bands: 1, top: 0, bandHeight: 68)) {
            let hues = [0, 1, 2, 3, 4, 5]
            let spans = hues.enumerated().map { TimelineDitherRenderer.Span($0.offset * 33, ($0.offset + 1) * 33, $0.element) }
            let peaks: [Float] = (0..<200).map { Float($0) <= 124 ? 1 : 0.32 }
            let f = TimelineDitherRenderer.Frame(spans: [spans], peaks: peaks, clicks: [],
                head: 124, playing: false, reduced: true, dt: 0, t: 0)
            try composite(r.draw(f), dark: true, at: dir.appendingPathComponent("rail-export-band.png"))
        }
    }

    private func composite(_ out: TimelineDitherRenderer.Output, dark: Bool, at url: URL) throws {
        let w = 1200, h = out.cells?.height ?? 136
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(srgbRed: dark ? 0.11 : 0.98, green: dark ? 0.115 : 0.98, blue: dark ? 0.13 : 0.99, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let glow = out.glow {
            ctx.interpolationQuality = .high
            ctx.setAlpha(dark ? 0.3 : 0.2)
            ctx.draw(glow, in: CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setAlpha(1)
        }
        ctx.interpolationQuality = .none
        if let cells = out.cells { ctx.draw(cells, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        if let overlay = out.overlay { ctx.draw(overlay, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        guard let image = ctx.makeImage() else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}
