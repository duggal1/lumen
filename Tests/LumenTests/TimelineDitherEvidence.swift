import Foundation
import Testing
import AppKit
import CoreGraphics
@testable import LumenUI

/// Writes the dither instrument's three layers, composited the way the NSView
/// stacks them, into .proof/ so the design can be inspected headlessly.
@Suite("Timeline dither evidence")
struct TimelineDitherEvidence {
    @Test func writeComposites() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent(".proof")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for dark in [true, false] {
            let r = try #require(TimelineDitherRenderer(width: 1000, height: 224, scale: 2, isDark: dark))
            let spans: [[TimelineDitherRenderer.Span]] = [
                [.init(2, 46, 0), .init(46, 92, 1), .init(120, 170, 0)],
                [.init(14, 60, 2), .init(100, 145, 2)],
                [.init(8, 36, 3, 0.7), .init(74, 82, 3, 0.7)],
                [.init(0, 233, 4)],
                [.init(150, 205, 5)],
            ]
            var peaks = [Float](repeating: 0, count: 233)
            for c in 0..<233 { peaks[c] = 0.18 + 0.55 * abs(sin(Float(c) * 0.11) * cos(Float(c) * 0.037)) }
            let f = TimelineDitherRenderer.Frame(spans: spans, peaks: peaks, clicks: [18, 40, 78, 130, 160, 190],
                head: 96, playing: false, reduced: true, dt: 1.0 / 60, t: 4)
            let out = r.draw(f)
            let w = 2000, h = 448
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(srgbRed: dark ? 0.106 : 0.98, green: dark ? 0.11 : 0.98, blue: dark ? 0.122 : 0.99, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            if let glow = out.glow {
                ctx.interpolationQuality = .high
                ctx.setAlpha(dark ? 0.3 : 0.2)
                ctx.draw(glow, in: CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setAlpha(1)
            }
            ctx.interpolationQuality = .none
            if let cells = out.cells { ctx.draw(cells, in: CGRect(x: 0, y: 0, width: w, height: h)) }
            ctx.interpolationQuality = .none
            if let overlay = out.overlay { ctx.draw(overlay, in: CGRect(x: 0, y: 0, width: w, height: h)) }
            guard let image = ctx.makeImage() else { return }
            let url = dir.appendingPathComponent(dark ? "timeline-dither-dark.png" : "timeline-dither-light.png")
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
