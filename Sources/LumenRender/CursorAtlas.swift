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
    public static func load(from url: URL) -> [CustomCursor] {
        guard let d = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([Row].self, from: d) else { return [] }
        return rows.map { CustomCursor(id: $0.id, png: $0.png, hot: [$0.hotX, $0.hotY]) }
    }
}

/// Minimal SVG path parser (M L H V C S Q A Z, absolute + relative) -> CGPath, in the SVG's own units.
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let s = Array(d.utf8)
        var i = 0
        let out = CGMutablePath()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastC: CGPoint?, lastQ: CGPoint?
        var cmd: UInt8 = 0
        func isSep(_ c: UInt8) -> Bool { c == 32 || c == 44 || c == 10 || c == 9 || c == 13 }
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func skip() { while i < s.count && isSep(s[i]) { i += 1 } }
        func num() -> CGFloat? {
            skip()
            guard i < s.count else { return nil }
            var j = i
            if s[j] == 45 || s[j] == 43 { j += 1 }
            var dot = false, digits = false
            while j < s.count {
                if isDigit(s[j]) { digits = true; j += 1 }
                else if s[j] == 46 && !dot { dot = true; j += 1 }
                else { break }
            }
            guard digits else { return nil }
            if j < s.count, s[j] == 101 || s[j] == 69 {
                var k = j + 1
                if k < s.count, s[k] == 45 || s[k] == 43 { k += 1 }
                if k < s.count, isDigit(s[k]) { while k < s.count && isDigit(s[k]) { k += 1 }; j = k }
            }
            let v = Double(String(decoding: s[i..<j], as: UTF8.self)) ?? 0
            i = j
            return CGFloat(v)
        }
        func flag() -> Bool? {
            skip()
            guard i < s.count, s[i] == 48 || s[i] == 49 else { return nil }
            let v = s[i] == 49
            i += 1
            return v
        }
        while true {
            skip()
            guard i < s.count else { break }
            let ch = s[i]
            if (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) { cmd = ch; i += 1 } else if cmd == 0 { break }
            let rel = cmd >= 97
            let up = rel ? cmd - 32 : cmd
            func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            let keepC = up == UInt8(ascii: "C") || up == UInt8(ascii: "S")
            let keepQ = up == UInt8(ascii: "Q")
            switch up {
            case UInt8(ascii: "M"):
                guard let x = num(), let y = num() else { return out }
                let p = P(x, y); out.move(to: p); cur = p; start = p
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "L"):
                guard let x = num(), let y = num() else { return out }
                let p = P(x, y); out.addLine(to: p); cur = p
            case UInt8(ascii: "H"):
                guard let x = num() else { return out }
                let p = CGPoint(x: rel ? cur.x + x : x, y: cur.y); out.addLine(to: p); cur = p
            case UInt8(ascii: "V"):
                guard let y = num() else { return out }
                let p = CGPoint(x: cur.x, y: rel ? cur.y + y : y); out.addLine(to: p); cur = p
            case UInt8(ascii: "C"):
                guard let a = num(), let b = num(), let c = num(), let d2 = num(), let x = num(), let y = num() else { return out }
                let c1 = P(a, b), c2 = P(c, d2), p = P(x, y)
                out.addCurve(to: p, control1: c1, control2: c2); lastC = c2; cur = p
            case UInt8(ascii: "S"):
                guard let c = num(), let d2 = num(), let x = num(), let y = num() else { return out }
                let c1 = lastC.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = P(c, d2), p = P(x, y)
                out.addCurve(to: p, control1: c1, control2: c2); lastC = c2; cur = p
            case UInt8(ascii: "Q"):
                guard let a = num(), let b = num(), let x = num(), let y = num() else { return out }
                let c = P(a, b), p = P(x, y)
                out.addQuadCurve(to: p, control: c); lastQ = c; cur = p
            case UInt8(ascii: "A"):
                guard let rx = num(), let ry = num(), let rot = num(), let large = flag(), let sweep = flag(), let x = num(), let y = num() else { return out }
                let p = P(x, y)
                arc(out, from: cur, rx: rx, ry: ry, rot: rot, large: large, sweep: sweep, to: p); cur = p
            case UInt8(ascii: "Z"):
                out.closeSubpath(); cur = start; cmd = 0
            default:
                return out
            }
            if !keepC { lastC = nil }
            if !keepQ { lastQ = nil }
        }
        _ = lastQ
        return out
    }

    private static func arc(_ path: CGMutablePath, from p0: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat, rot: CGFloat,
                            large: Bool, sweep: Bool, to p1: CGPoint) {
        if p0 == p1 { return }
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 { path.addLine(to: p1); return }
        let phi = rot * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lam > 1 { let k = lam.squareRoot(); rx *= k; ry *= k }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        guard den > 0 else { path.addLine(to: p1); return }
        let co = (large == sweep ? CGFloat(-1) : CGFloat(1)) * max(0, num / den).squareRoot()
        let cxp = co * rx * y1 / ry, cyp = -co * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2
        let cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2
        let th1 = atan2((y1 - cyp) / ry, (x1 - cxp) / rx)
        let th2 = atan2((-y1 - cyp) / ry, (-x1 - cxp) / rx)
        var dth = th2 - th1
        if !sweep && dth > 0 { dth -= 2 * .pi } else if sweep && dth < 0 { dth += 2 * .pi }
        let n = max(Int(ceil(abs(dth) / (.pi / 2))), 1)
        let d = dth / CGFloat(n), t = 4 / 3 * tan(d / 4)
        func map(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: cx + rx * cp * u - ry * sp * v, y: cy + rx * sp * u + ry * cp * v) }
        var a = th1
        for _ in 0..<n {
            let b = a + d
            path.addCurve(to: map(cos(b), sin(b)),
                          control1: map(cos(a) - t * sin(a), sin(a) + t * cos(a)),
                          control2: map(cos(b) + t * sin(b), sin(b) - t * cos(b)))
            a = b
        }
    }
}

/// Vector cursor art rasterized at 8x into a mip-mapped texture array. Each layer is a 32 pt box (256 px), top-left origin.
/// Every layer is the custom Lumen arrow, except the hand shapes, which use the custom Lumen hand.
public final class CursorAtlas {
    public struct Entry { public var layer: Int; public var hot: SIMD2<Double> }   // hot normalized to the layer
    public let texture: MTLTexture
    private var map: [UInt16: Entry] = [:]
    static let px = 256, pts = 32.0

    static let arrowD = "M9.80282 4.62973 15.8364 6.99069C19.3164 8.35243 21.0564 9.03329 20.9987 10.1133 20.941 11.1934 19.1251 11.6886 15.4933 12.6791 14.412 12.974 13.8713 13.1215 13.4964 13.4963 13.1215 13.8712 12.9741 14.4119 12.6791 15.4933 11.6887 19.125 11.1934 20.9409 10.1134 20.9986 9.03335 21.0563 8.35249 19.3163 6.99075 15.8363L4.62979 9.80276C3.20411 6.15934 2.49127 4.33764 3.41448 3.41442 4.3377 2.49121 6.15941 3.20405 9.80282 4.62973Z"
    static let handD = "M224,104v50.93c0,46.2-36.85,84.55-83,85.06A83.71,83.71,0,0,1,80.6,215.4C58.79,192.33,34.15,136,34.15,136a16,16,0,0,1,6.53-22.23c7.66-4,17.1-.84,21.4,6.62l21,36.44a6.09,6.09,0,0,0,6,3.09l.12,0A8.19,8.19,0,0,0,96,151.74V32a16,16,0,0,1,16.77-16c8.61.4,15.23,7.82,15.23,16.43V104a8,8,0,0,0,8.53,8,8.17,8.17,0,0,0,7.47-8.25V88a16,16,0,0,1,16.77-16c8.61.4,15.23,7.82,15.23,16.43V112a8,8,0,0,0,8.53,8,8.17,8.17,0,0,0,7.47-8.25v-7.28c0-8.61,6.62-16,15.23-16.43A16,16,0,0,1,224,104Z"

    public init?(device: MTLDevice, queue: MTLCommandQueue, pack: CursorPack, customs: [CustomCursor]) {
        let ids = StockCursor.allCases.map(\.rawValue)
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray; d.pixelFormat = .rgba8Unorm
        d.width = Self.px; d.height = Self.px; d.arrayLength = ids.count + customs.count; d.mipmapLevelCount = 9
        d.usage = [.shaderRead, .renderTarget]
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        texture = t
        for (i, id) in ids.enumerated() {
            var hot = SIMD2<Double>(3.5, 3.5)
            let bytes = Self.raster { c in
                if let s = StockCursor(rawValue: id) { hot = Self.art(c, pack, s) }
            }
            t.replace(region: MTLRegionMake2D(0, 0, Self.px, Self.px), mipmapLevel: 0, slice: i, withBytes: bytes,
                      bytesPerRow: Self.px * 4, bytesPerImage: Self.px * Self.px * 4)
            map[id] = Entry(layer: i, hot: hot / Self.pts)
        }
        // Captured system cursors that have no stock equivalent keep their real
        // artwork instead of silently falling back to the Lumen arrow.
        for (j, custom) in customs.enumerated() {
            guard let (bytes, hot) = Self.customRaster(custom) else { continue }
            let layer = ids.count + j
            t.replace(region: MTLRegionMake2D(0, 0, Self.px, Self.px), mipmapLevel: 0, slice: layer, withBytes: bytes,
                      bytesPerRow: Self.px * 4, bytesPerImage: Self.px * Self.px * 4)
            map[custom.id] = Entry(layer: layer, hot: hot)
        }
        if let cb = queue.makeCommandBuffer(), let b = cb.makeBlitCommandEncoder() {
            b.generateMipmaps(for: t); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
    }

    /// Uses the same rasterizer and arrow artwork as the exported cursor.
    public static func previewImage(pack: CursorPack) -> NSImage? {
        let bytes = raster { context in _ = art(context, pack, .arrow) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: px, height: px, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: px * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: pts, height: pts))
    }

    /// Rasterizes one captured cursor PNG into the same 32 pt box as the stock
    /// art. The hotspot is remapped through the fit rect so the click point
    /// stays exact even when the bitmap is scaled.
    private static func customRaster(_ cursor: CustomCursor) -> ([UInt8], SIMD2<Double>)? {
        guard let image = NSImage(data: cursor.png) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        guard iw > 0, ih > 0 else { return nil }
        let s = min(pts / iw, pts / ih)
        let w = iw * s, h = ih * s
        let x0 = (pts - w) / 2, y0 = (pts - h) / 2
        var buf = [UInt8](repeating: 0, count: px * px * 4)
        buf.withUnsafeMutableBytes { p in
            guard let c = CGContext(data: p.baseAddress, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let k = CGFloat(px) / CGFloat(pts)
            c.translateBy(x: 0, y: CGFloat(px)); c.scaleBy(x: k, y: -k)
            c.interpolationQuality = .high
            c.draw(cg, in: CGRect(x: x0, y: y0, width: w, height: h))
        }
        let iwPt = max(image.size.width, 1), ihPt = max(image.size.height, 1)
        let hx = (Double(cursor.hot.x) / Double(iwPt) * Double(w) + Double(x0)) / pts
        let hy = (Double(cursor.hot.y) / Double(ihPt) * Double(h) + Double(y0)) / pts
        return (buf, SIMD2(min(max(hx, 0), 1), min(max(hy, 0), 1)))
    }

    public func entry(_ shape: UInt16) -> Entry? { map[shape] ?? map[StockCursor.arrow.rawValue] }

    private static func raster(_ draw: (CGContext) -> Void) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: px * px * 4)
        buf.withUnsafeMutableBytes { p in
            guard let c = CGContext(data: p.baseAddress, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let k = CGFloat(px) / CGFloat(pts)
            c.translateBy(x: 0, y: CGFloat(px)); c.scaleBy(x: k, y: -k)          // top-left origin, units = points
            c.setLineJoin(.round); c.setLineCap(.round)
            draw(c)
        }
        return buf
    }

    /// Returns the hotspot in points.
    private static func art(_ c: CGContext, _ pack: CursorPack, _ s: StockCursor) -> SIMD2<Double> {
        let rgb: (Double, Double, Double)
        switch pack {
        case .lavender: rgb = (0.53, 0.33, 0.95)
        case .coral: rgb = (1, 0.16, 0.12)
        case .sky: rgb = (0.184, 0.525, 0.941)
        case .mint: rgb = (0.086, 0.659, 0.478)
        case .lemon: rgb = (0.949, 0.718, 0.020)
        case .pink: rgb = (0.933, 0.310, 0.596)
        case .wood: rgb = (0.604, 0.369, 0.173)
        case .chrome: rgb = (0.420, 0.451, 0.502)
        case .grass: rgb = (0.243, 0.620, 0.180)
        default: rgb = (0.11, 0.098, 0.09)
        }
        let ink = CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        let paper = CGColor(gray: 1, alpha: 1)
        func shadowed(_ body: () -> Void) {
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: CGColor(gray: 0, alpha: 0.35))
            c.beginTransparencyLayer(auxiliaryInfo: nil)
            body()
            c.endTransparencyLayer()
            c.restoreGState()
        }
        func glyph(_ d: String, tip: CGPoint, hot: CGPoint, scale: CGFloat, stroke: CGFloat) -> SIMD2<Double> {
            let p = SVGPath.parse(d)
            var t = CGAffineTransform(translationX: hot.x - tip.x * scale, y: hot.y - tip.y * scale).scaledBy(x: scale, y: scale)
            if let q = p.copy(using: &t) {
                shadowed {
                    c.addPath(q); c.setFillColor(ink); c.setStrokeColor(paper); c.setLineWidth(stroke); c.setLineJoin(.round)
                    c.drawPath(using: .fillStroke)
                }
            }
            return [Double(hot.x), Double(hot.y)]
        }
        // Every mark is drawn twice: a paper silhouette one point larger, then
        // the ink. That is the whole outline language — no strokes for their own
        // sake, and a mark stays legible on any wallpaper.
        func fillMark(_ p: CGPath, rim: CGFloat = 1.0, inkStroke: CGFloat = 0) {
            shadowed {
                c.setFillColor(paper); c.setStrokeColor(paper); c.setLineJoin(.round); c.setLineCap(.round)
                c.addPath(p); c.fillPath()
                c.setLineWidth(2 * rim + inkStroke); c.addPath(p); c.strokePath()
                c.setFillColor(ink); c.setStrokeColor(ink)
                c.addPath(p)
                if inkStroke <= 0 { c.fillPath() } else { c.setLineWidth(inkStroke); c.strokePath() }
            }
        }
        func strokeMark(_ p: CGPath, _ w: CGFloat, rim: CGFloat = 1.0) {
            shadowed {
                c.setLineJoin(.round); c.setLineCap(.round)
                c.setStrokeColor(paper); c.setLineWidth(w + 2 * rim); c.addPath(p); c.strokePath()
                c.setStrokeColor(ink); c.setLineWidth(w); c.addPath(p); c.strokePath()
            }
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, rotated t: CGAffineTransform) -> CGPath {
            var m = t
            let p = box(x, y, w, h, r)
            guard let q = p.copy(using: &m) else { return p }
            return q
        }
        func union(_ parts: [CGPath]) -> CGPath {
            let p = CGMutablePath()
            for part in parts { p.addPath(part) }
            return p
        }
        guard pack.preservesShape else { return stylized(c, pack, ink: ink, paper: paper) }
        // Shape-preserving packs: one drawing per recorded shape. A pointing
        // hand is not an open hand, and text selection is not an arrow.
        switch s {
        case .arrow:
            // 24-unit arrow at 1.4x (about 25 pt tall), tip is the hotspot
            return glyph(arrowD, tip: CGPoint(x: 3.2, y: 3.2), hot: CGPoint(x: 3.5, y: 3.5), scale: 1.4, stroke: 2.1)
        case .iBeam:
            let beam = CGPath(roundedRect: CGRect(x: 14.4, y: 7.4, width: 3.2, height: 17.2), cornerWidth: 0.6, cornerHeight: 0.6, transform: nil)
            let caps = union([CGPath(roundedRect: CGRect(x: 10.4, y: 5.4, width: 11.2, height: 2.8), cornerWidth: 1.2, cornerHeight: 1.2, transform: nil),
                              CGPath(roundedRect: CGRect(x: 10.4, y: 23.8, width: 11.2, height: 2.8), cornerWidth: 1.2, cornerHeight: 1.2, transform: nil)])
            fillMark(union([beam, caps]))
            // The beam centre is the hotspot, and the beam covers it.
            return [16, 16]
        case .pointingHand:
            // 256-unit hand, ~24 pt tall, fingertip is the hotspot
            return glyph(handD, tip: CGPoint(x: 112, y: 16), hot: CGPoint(x: 12, y: 3.5), scale: 24.0 / 224.0, stroke: 2.0)
        case .openHand:
            let fingers = [CGPath(roundedRect: CGRect(x: 9.6, y: 6.4, width: 3.0, height: 10.6), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil),
                           CGPath(roundedRect: CGRect(x: 13.0, y: 5.2, width: 3.0, height: 11.8), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil),
                           CGPath(roundedRect: CGRect(x: 16.4, y: 6.0, width: 3.0, height: 11.0), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil),
                           CGPath(roundedRect: CGRect(x: 19.8, y: 8.0, width: 3.0, height: 9.0), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)]
            let thumb = box(-1.7, -3.5, 3.4, 7.0, 1.7, rotated: CGAffineTransform(translationX: 7.4, y: 17.2).rotated(by: -0.605))
            fillMark(union([box(9.2, 14.0, 14.0, 12.6, 4.4), thumb] + fingers))
            return [16, 18]
        case .closedHand:
            let knuckles = [CGPath(roundedRect: CGRect(x: 9.9, y: 9.4, width: 2.7, height: 5.2), cornerWidth: 1.35, cornerHeight: 1.35, transform: nil),
                            CGPath(roundedRect: CGRect(x: 13.1, y: 8.9, width: 2.7, height: 5.7), cornerWidth: 1.35, cornerHeight: 1.35, transform: nil),
                            CGPath(roundedRect: CGRect(x: 16.3, y: 9.3, width: 2.7, height: 5.3), cornerWidth: 1.35, cornerHeight: 1.35, transform: nil),
                            CGPath(roundedRect: CGRect(x: 19.5, y: 10.2, width: 2.7, height: 4.4), cornerWidth: 1.35, cornerHeight: 1.35, transform: nil)]
            let thumb = box(-1.9, -3.8, 3.8, 7.6, 1.9, rotated: CGAffineTransform(translationX: 11.6, y: 20.2).rotated(by: -1.5708))
            fillMark(union([box(8.8, 12.6, 14.4, 13.9, 5.4), thumb] + knuckles))
            return [16, 16]
        case .crosshair:
            let arm = 12.4, gap = 2.6, thick = 2.2
            let parts = [CGRect(x: 16 - thick / 2, y: 16 - arm, width: thick, height: arm - gap),
                         CGRect(x: 16 - thick / 2, y: 16 + gap, width: thick, height: arm - gap),
                         CGRect(x: 16 - arm, y: 16 - thick / 2, width: arm - gap, height: thick),
                         CGRect(x: 16 + gap, y: 16 - thick / 2, width: arm - gap, height: thick)]
            let dot = CGPath(ellipseIn: CGRect(x: 16 - 1.4, y: 16 - 1.4, width: 2.8, height: 2.8), transform: nil)
            let p = CGMutablePath()
            for r in parts { p.addRect(r) }
            p.addPath(dot)
            fillMark(p)
            return [16, 16]
        case .resizeLeftRight:
            let shaft = CGRect(x: 5.4, y: 14.9, width: 21.2, height: 2.2)
            let headL = CGMutablePath()
            headL.move(to: CGPoint(x: 5.0, y: 16)); headL.addLine(to: CGPoint(x: 10.4, y: 11.7)); headL.addLine(to: CGPoint(x: 10.4, y: 20.3)); headL.closeSubpath()
            let headR = CGMutablePath()
            headR.move(to: CGPoint(x: 27.0, y: 16)); headR.addLine(to: CGPoint(x: 21.6, y: 11.7)); headR.addLine(to: CGPoint(x: 21.6, y: 20.3)); headR.closeSubpath()
            let p = CGMutablePath()
            p.addRect(shaft); p.addPath(headL); p.addPath(headR)
            fillMark(p)
            return [16, 16]
        case .resizeUpDown:
            let shaft = CGRect(x: 14.9, y: 5.4, width: 2.2, height: 21.2)
            let headT = CGMutablePath()
            headT.move(to: CGPoint(x: 16, y: 5.0)); headT.addLine(to: CGPoint(x: 11.7, y: 10.4)); headT.addLine(to: CGPoint(x: 20.3, y: 10.4)); headT.closeSubpath()
            let headB = CGMutablePath()
            headB.move(to: CGPoint(x: 16, y: 27.0)); headB.addLine(to: CGPoint(x: 11.7, y: 21.6)); headB.addLine(to: CGPoint(x: 20.3, y: 21.6)); headB.closeSubpath()
            let p = CGMutablePath()
            p.addRect(shaft); p.addPath(headT); p.addPath(headB)
            fillMark(p)
            return [16, 16]
        case .notAllowed:
            let ring = CGPath(ellipseIn: CGRect(x: 6.8, y: 6.8, width: 18.4, height: 18.4), transform: nil)
            let slash = CGMutablePath()
            slash.move(to: CGPoint(x: 9.6, y: 9.6)); slash.addLine(to: CGPoint(x: 22.4, y: 22.4))
            strokeMark(ring, 2.8)
            strokeMark(slash, 2.8)
            return [16, 16]
        case .contextMenu:
            // The arrow is the pointer; the card says a menu is open here. The
            // hotspot stays on the arrow tip, not on the card.
            _ = glyph(arrowD, tip: CGPoint(x: 3.2, y: 3.2), hot: CGPoint(x: 3.5, y: 3.5), scale: 1.05, stroke: 1.8)
            let card = box(17.4, 17.0, 11.0, 9.4, 2.0)
            fillMark(card)
            shadowed {
                c.setStrokeColor(ink); c.setLineWidth(1.5); c.setLineCap(.round)
                for i in 0..<3 {
                    c.move(to: CGPoint(x: 19.6, y: 19.6 + CGFloat(i) * 2.4))
                    c.addLine(to: CGPoint(x: 26.2, y: 19.6 + CGFloat(i) * 2.4))
                }
                c.strokePath()
            }
            return [3.5, 3.5]
        }
    }

    /// The stylized packs. They are an explicit user override: one glyph for
    /// every shape, never the recorded pointer's identity.
    private static func stylized(_ c: CGContext, _ pack: CursorPack, ink: CGColor, paper: CGColor) -> SIMD2<Double> {
        func shadowed(_ body: () -> Void) {
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: CGColor(gray: 0, alpha: 0.35))
            c.beginTransparencyLayer(auxiliaryInfo: nil)
            body()
            c.endTransparencyLayer()
            c.restoreGState()
        }
        if pack == .holiday {
            // Snowflake: six spokes + center dot, winter pack. Hotspot is
            // the flake center so clicks land where the eye points.
            shadowed {
                c.setStrokeColor(paper); c.setLineWidth(3.2)
                c.setFillColor(ink)
                for k in 0..<6 {
                    let a = Double(k) * Double.pi / 3
                    c.move(to: CGPoint(x: 16, y: 16))
                    c.addLine(to: CGPoint(x: 16 + 11 * CGFloat(cos(a)), y: 16 + 11 * CGFloat(sin(a))))
                }
                c.strokePath()
                c.setStrokeColor(ink); c.setLineWidth(1.4)
                for k in 0..<6 {
                    let a = Double(k) * Double.pi / 3
                    c.move(to: CGPoint(x: 16, y: 16))
                    c.addLine(to: CGPoint(x: 16 + 11 * CGFloat(cos(a)), y: 16 + 11 * CGFloat(sin(a))))
                }
                c.strokePath()
                c.addEllipse(in: CGRect(x: 14, y: 14, width: 4, height: 4)); c.fillPath()
            }
            return [16, 16]
        }
        if pack == .dot {
            shadowed {
                c.addEllipse(in: CGRect(x: 11, y: 11, width: 10, height: 10)); c.setFillColor(ink); c.setStrokeColor(paper); c.setLineWidth(1.8)
                c.drawPath(using: .fillStroke)
            }
            return [16, 16]
        }
        if pack == .ring {
            shadowed {
                c.addEllipse(in: CGRect(x: 7, y: 7, width: 18, height: 18))
                c.setStrokeColor(paper); c.setLineWidth(3.8); c.strokePath()
                c.addEllipse(in: CGRect(x: 7, y: 7, width: 18, height: 18))
                c.setStrokeColor(ink); c.setLineWidth(1.6); c.strokePath()
            }
            return [16, 16]
        }
        return [16, 16]
    }
}

extension CursorPack {
    /// Packs that keep the recorded pointer's identity, so every stock shape gets
    /// its own artwork. The stylized packs (dot, ring, holiday) are an explicit
    /// user override and keep one glyph for every shape.
    var preservesShape: Bool { self != .dot && self != .ring && self != .holiday }
}
