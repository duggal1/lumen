import Foundation
import Metal
import CoreGraphics
import AppKit
import simd
import LumenCore
import LumenProject

public struct CustomCursor: Sendable { public var id: UInt16; public var png: Data; public var hot: SIMD2<Double> }

public enum CursorLibrary {
    private struct Row: Codable { var id: UInt16; var png: Data; var hotX: Double; var hotY: Double }
    /// Reads cursors.json written by CursorCatalog (hotspots in points).
    public static func load(from url: URL) -> [CustomCursor] {
        guard let d = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([Row].self, from: d) else { return [] }
        return rows.map { CustomCursor(id: $0.id, png: $0.png, hot: [$0.hotX, $0.hotY]) }
    }
}

/// Vector cursor art rasterized at 4x into a mip-mapped texture array. Each layer is a 32 pt box (128 px), top-left origin.
public final class CursorAtlas {
    public struct Entry { public var layer: Int; public var hot: SIMD2<Double> }   // hot normalized to the layer
    public let texture: MTLTexture
    private var map: [UInt16: Entry] = [:]
    static let px = 128, pts = 32.0

    public init?(device: MTLDevice, queue: MTLCommandQueue, pack: CursorPack, customs: [CustomCursor]) {
        let ids = StockCursor.allCases.map(\.rawValue) + customs.map(\.id)
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray; d.pixelFormat = .rgba8Unorm
        d.width = Self.px; d.height = Self.px; d.arrayLength = ids.count; d.mipmapLevelCount = 8
        d.usage = [.shaderRead, .renderTarget]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        texture = t
        for (i, id) in ids.enumerated() {
            var hot = SIMD2<Double>(2, 2)
            let bytes = Self.raster { c in
                if let s = StockCursor(rawValue: id) { hot = Self.art(c, pack, s) }
                else if let cc = customs.first(where: { $0.id == id }) { hot = Self.drawCustom(c, cc) }
            }
            t.replace(region: MTLRegionMake2D(0, 0, Self.px, Self.px), mipmapLevel: 0, slice: i, withBytes: bytes,
                      bytesPerRow: Self.px * 4, bytesPerImage: Self.px * Self.px * 4)
            map[id] = Entry(layer: i, hot: hot / Self.pts)
        }
        if let cb = queue.makeCommandBuffer(), let b = cb.makeBlitCommandEncoder() {
            b.generateMipmaps(for: t); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
    }

    public func entry(_ shape: UInt16) -> Entry? { map[shape] ?? map[StockCursor.arrow.rawValue] }

    private static func raster(_ draw: (CGContext) -> Void) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: px * px * 4)
        buf.withUnsafeMutableBytes { p in
            guard let c = CGContext(data: p.baseAddress, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            c.translateBy(x: 0, y: CGFloat(px)); c.scaleBy(x: 4, y: -4)          // top-left origin, units = points
            c.setLineJoin(.round); c.setLineCap(.round)
            draw(c)
        }
        return buf
    }

    private static func drawCustom(_ c: CGContext, _ cc: CustomCursor) -> SIMD2<Double> {
        guard let img = NSImage(data: cc.png), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return cc.hot }
        let k = img.size.width > 36 ? 0.5 : 1.0                                   // assume 2x when the PNG carries no DPI
        let w = img.size.width * k, h = img.size.height * k, fit = min(1, pts / max(w, h))
        c.saveGState()
        c.translateBy(x: 0, y: h * fit); c.scaleBy(x: fit, y: -fit)
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        c.restoreGState()
        return cc.hot * fit
    }

    /// Returns the hotspot in points.
    private static func art(_ c: CGContext, _ pack: CursorPack, _ s: StockCursor) -> SIMD2<Double> {
        let ink = CGColor(gray: 0.05, alpha: 1), paper = CGColor(gray: 1, alpha: 1)
        c.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: CGColor(gray: 0, alpha: 0.45))
        func outline(_ p: CGPath, _ fill: CGColor, _ stroke: CGColor, _ w: CGFloat) {
            c.addPath(p); c.setFillColor(fill); c.setStrokeColor(stroke); c.setLineWidth(w); c.drawPath(using: .fillStroke)
        }
        func line(_ p: CGPath, _ w: CGFloat) {                                      // paper halo under ink
            c.addPath(p); c.setStrokeColor(paper); c.setLineWidth(w + 2.2); c.strokePath()
            c.addPath(p); c.setStrokeColor(ink); c.setLineWidth(w); c.strokePath()
        }
        if pack == .dot {
            outline(CGPath(ellipseIn: CGRect(x: 11, y: 11, width: 10, height: 10), transform: nil), ink, paper, 1.8); return [16, 16]
        }
        if pack == .ring {
            let p = CGPath(ellipseIn: CGRect(x: 7, y: 7, width: 18, height: 18), transform: nil); line(p, 1.6); return [16, 16]
        }
        switch s {
        case .arrow, .contextMenu:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 2, y: 2)); p.addLine(to: CGPoint(x: 2, y: 21)); p.addLine(to: CGPoint(x: 7, y: 16.5))
            p.addLine(to: CGPoint(x: 10.5, y: 24)); p.addLine(to: CGPoint(x: 13.5, y: 22.5)); p.addLine(to: CGPoint(x: 10, y: 15.5))
            p.addLine(to: CGPoint(x: 16.5, y: 15.5)); p.closeSubpath()
            switch pack {
            case .minimal: outline(p, paper, ink, 1.1)
            case .pro: outline(p, paper, ink, 1.7)
            default: outline(p, ink, paper, 1.5)
            }
            return [2, 2]
        case .iBeam:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 16, y: 6)); p.addLine(to: CGPoint(x: 16, y: 26))
            p.move(to: CGPoint(x: 12.5, y: 6)); p.addLine(to: CGPoint(x: 19.5, y: 6))
            p.move(to: CGPoint(x: 12.5, y: 26)); p.addLine(to: CGPoint(x: 19.5, y: 26)); line(p, 1.4); return [16, 16]
        case .pointingHand:
            let p = CGMutablePath()
            p.addRoundedRect(in: CGRect(x: 9, y: 3, width: 4.4, height: 15), cornerWidth: 2.2, cornerHeight: 2.2)
            p.addRoundedRect(in: CGRect(x: 7, y: 14, width: 16, height: 11), cornerWidth: 3.5, cornerHeight: 3.5)
            outline(p, paper, ink, 1.2); return [11.2, 3.5]
        case .openHand, .closedHand:
            outline(CGPath(roundedRect: CGRect(x: 8, y: 11, width: 16, height: 13), cornerWidth: 4, cornerHeight: 4, transform: nil), paper, ink, 1.3)
            return [16, 17]
        case .crosshair:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 16, y: 5)); p.addLine(to: CGPoint(x: 16, y: 27)); p.move(to: CGPoint(x: 5, y: 16)); p.addLine(to: CGPoint(x: 27, y: 16))
            line(p, 1.2); return [16, 16]
        case .resizeLeftRight, .resizeUpDown:
            c.saveGState()
            if s == .resizeUpDown { c.translateBy(x: 32, y: 0); c.rotate(by: .pi / 2) }
            let pts: [(CGFloat, CGFloat)] = [(4, 16), (10, 10), (10, 14), (22, 14), (22, 10), (28, 16), (22, 22), (22, 18), (10, 18), (10, 22)]
            let p = CGMutablePath(); p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
            for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
            p.closeSubpath(); outline(p, ink, paper, 1.3); c.restoreGState(); return [16, 16]
        case .notAllowed:
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: 7, y: 7, width: 18, height: 18))
            p.move(to: CGPoint(x: 10, y: 10)); p.addLine(to: CGPoint(x: 22, y: 22)); line(p, 2.4); return [16, 16]
        }
    }
}