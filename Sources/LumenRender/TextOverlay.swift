import Foundation
import CoreGraphics
import CoreText
import AppKit
import Metal
import LumenProject
import LumenDirector

/// The frosted material behind a caption block. The card itself is drawn by
/// the Metal compositor from a blurred copy of the scene, never baked into the
/// text sprite: preview and export use the same pixels.
struct TextCard {
    /// Corner radius in sprite pixels.
    let radius: Float
    /// Base tint. Alpha is the floor for the adaptive opacity; the compositor
    /// raises it on bright backdrops until white text keeps 4.5:1 contrast.
    let tint: SIMD4<Float>
}

/// A pre-rasterized text layer composited by the same Metal path in preview and export.
struct TextOverlaySprite {
    let texture: any MTLTexture
    let center: SIMD2<Float>            // output canvas pixels, top-left origin
    let opacity: Float
    var scale: Float = 1
    /// Blur-in radius in output pixels. Zero once the caption has settled.
    var blur: Float = 0
    var card: TextCard?
}

private struct TextPart {
    let value: String
    let color: RGBA
    /// Baseline offset in raster pixels: a word rises into place as it is
    /// spoken instead of popping in at its final position.
    var rise: CGFloat = 0
}

private struct Raster {
    let texture: any MTLTexture
    let padding: CGFloat
}

/// Critically damped step response, 0 to 1. omega 20 settles in ~0.33 s.
func settle(_ t: Double, omega: Double) -> Double {
    let x = omega * max(t, 0)
    return 1 - exp(-x) * (1 + x)
}

struct CaptionPose { var opacity, lift, scale, blur: Double }

/// The caption is animated by the playhead, never by wall-clock time, so a
/// scrub lands on the exact frame. Word in: opacity 0→1, blur 8→0, 6 pt rise,
/// scale 0.985→1 over 380 ms with an ease-out quart. Group out: blur 0→6 and
/// opacity→0 over 220 ms.
func captionPose(at t: Double, shownAt: Double, hiddenAt: Double, unit: Double) -> CaptionPose {
    let inT = max(0, min(1, (t - shownAt) / 0.38))
    let e = 1 - pow(1 - inT, 4)                                  // ease-out quart
    let outT = max(0, min(1, (t - (hiddenAt - 0.22)) / 0.22))
    return CaptionPose(opacity: e * (1 - outT),
                       lift: 6 * unit * (1 - e),                 // positive: below the anchor
                       scale: 0.985 + 0.015 * e,
                       blur: (8 * (1 - e) + 6 * outT) * unit)
}

final class TextOverlayCache {
    private var textures: [String: Raster] = [:]
    private var order: [String] = []
    private let maxEntries = 64

    func caption(_ chunk: CaptionChunk, style: CaptionStyle, time: Double,
                 canvas: SIMD2<Int>, videoRect: SIMD4<Double>,
                 device: any MTLDevice) -> TextOverlaySprite? {
        guard !chunk.lines.isEmpty else { return nil }
        let unit = Double(videoRect.w) / 1080.0                  // one design point at 1080 tall
        let stagger = 0.028
        let wordIn = 0.38
        var index = 0
        let lines = chunk.lines.map { line in
            line.map { word -> TextPart in
                defer { index += 1 }
                let start = chunk.start + Double(index) * stagger
                let t = max(0, min(1, (time - start) / wordIn))
                let e = 1 - pow(1 - t, 4)                       // ease-out quart
                // The spoken word is full white, the rest sit at 60 %. This is
                // brightness only: a weight change would reflow the line.
                let edge = max(0, min(1, min((time - word.start) / 0.08, (word.end - time) / 0.08)))
                let dim = RGBA(r: style.color.r, g: style.color.g, b: style.color.b, a: style.color.a * 0.6)
                var color = mix(dim, style.color, edge)
                color.a *= Float(e)
                // Quantized so the raster cache holds a bounded number of
                // variants while a caption animates.
                let step = 1.0 / 32.0
                color.a = Float((Double(color.a) / step).rounded() * step)
                let rise = ((1 - e) * 6 * unit).rounded()
                return TextPart(value: word.text, color: color, rise: CGFloat(rise))
            }
        }
        // Scale with the actual video, not the outer canvas/padding. Both
        // Studio and export share this rasterization and its layout bounds.
        let fontSize = CGFloat(videoRect.w) * CGFloat(max(style.size, 0.015))
        // A caption never uses more than 60 % of the picture width.
        let safeWidth = max(1, Int(videoRect.z * 0.60))
        guard let raster = texture(lines: lines, fontSize: fontSize, typeface: style.font,
                                   canvas: canvas, maxWidth: safeWidth, device: device) else { return nil }
        let pose = captionPose(at: time, shownAt: chunk.start, hiddenAt: chunk.end, unit: unit)
        let halfH = Double(raster.texture.height) / 2 * pose.scale
        let desiredY = videoRect.y + videoRect.w * chunk.y + pose.lift
        let y = min(max(desiredY, videoRect.y + halfH + 8), videoRect.y + videoRect.w - halfH - 8)
        let card = style.pill.map { TextCard(radius: Float(raster.padding), tint: $0.simd) }
        return TextOverlaySprite(texture: raster.texture,
                                 center: SIMD2(Float(videoRect.x + videoRect.z / 2), Float(y)),
                                 opacity: Float(pose.opacity), scale: Float(pose.scale),
                                 blur: Float(pose.blur), card: card)
    }

    func manual(_ frame: TextFrame, canvas: SIMD2<Int>, device: any MTLDevice) -> TextOverlaySprite? {
        guard !frame.text.isEmpty else { return nil }
        let lines = frame.text.components(separatedBy: "\n").prefix(5).map {
            [TextPart(value: $0, color: frame.color)]
        }
        guard let raster = texture(lines: lines, fontSize: CGFloat(canvas.y) * CGFloat(max(frame.size, 0.015)),
                                   canvas: canvas, device: device) else { return nil }
        return TextOverlaySprite(texture: raster.texture,
                                 center: SIMD2(frame.center.x * Float(canvas.x), frame.center.y * Float(canvas.y)),
                                 opacity: frame.opacity)
    }

    private func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        let f = Float(t)
        return RGBA(r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f,
                    b: a.b + (b.b - a.b) * f, a: a.a + (b.a - a.a) * f)
    }

    /// Two faces, one weight. 450 sits exactly between regular and medium, so
    /// a caption reads evenly and the spoken word never changes weight.
    private func coreFont(_ typeface: CaptionFont, size: CGFloat) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        let desc = typeface == .serif ? (base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor)
                                      : base.fontDescriptor
        var font = CTFontCreateWithFontDescriptor(desc as CTFontDescriptor, size, nil)
        let key = "NSCTFontWeightAttribute"
        let weighted = CTFontDescriptorCreateCopyWithAttributes(desc as CTFontDescriptor,
                                                              [key: 4.5] as CFDictionary)
        let probe = CTFontCreateWithFontDescriptor(weighted, size, nil)
        // CoreText only honours a fractional weight when the face is variable;
        // otherwise keep the medium we already have.
        if let read = CTFontCopyAttribute(probe, key as CFString) as? NSNumber,
           abs(read.doubleValue - 4.5) < 0.25 {
            font = probe
        }
        return font
    }

    private func texture(lines: [[TextPart]], fontSize wanted: CGFloat, typeface: CaptionFont = .sans,
                         canvas: SIMD2<Int>, maxWidth: Int? = nil,
                         device: any MTLDevice) -> Raster? {
        let maxCharacters = lines.map { $0.reduce(0) { $0 + $1.value.count + 1 } }.max() ?? 1
        let widthLimit = max(2, min(maxWidth ?? canvas.x, canvas.x))
        let fontSize = max(10, min(wanted, CGFloat(widthLimit) * 1.15 / CGFloat(max(1, maxCharacters))))
        let identifier = lines.map { row in
            row.map { p in
                "\(p.value)@\(p.color.r),\(p.color.g),\(p.color.b),\(p.color.a)"
            }.joined(separator: "/")
        }.joined(separator: "\n")
        let key = "\(canvas.x)x\(canvas.y):\(fontSize):\(typeface.rawValue):\(identifier)"
        if let cached = textures[key] { return cached }

        let font = coreFont(typeface, size: fontSize)
        let coreLines: [CTLine] = lines.map { parts in
            let attr = NSMutableAttributedString(string: "")
            for (index, part) in parts.enumerated() {
                let color = CGColor(red: CGFloat(part.color.r), green: CGFloat(part.color.g),
                                    blue: CGFloat(part.color.b), alpha: CGFloat(part.color.a))
                let prefix = index == 0 ? "" : " "
                var attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
                ]
                if part.rise != 0 { attributes[.baselineOffset] = part.rise }
                attr.append(NSAttributedString(string: prefix + part.value, attributes: attributes))
            }
            return CTLineCreateWithAttributedString(attr)
        }
        let widths = coreLines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let padding = max(8, fontSize * 0.32)
        let lineHeight = fontSize * 1.32
        let width = max(2, min(widthLimit, Int(ceil((widths.max() ?? 0) + padding * 2))))
        let height = max(2, min(canvas.y, Int(ceil(CGFloat(coreLines.count) * lineHeight + padding * 2))))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let texture: (any MTLTexture)? = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            // The card is a compositor material now; only glyphs live here.
            context.setShadow(offset: CGSize(width: 0, height: -1),
                              blur: max(2, fontSize * 0.1),
                              color: CGColor(gray: 0, alpha: 0.70))
            for (index, line) in coreLines.enumerated() {
                context.textPosition = CGPoint(x: (CGFloat(width) - widths[index]) / 2,
                    y: CGFloat(height) - padding - CGFloat(index + 1) * lineHeight + fontSize * 0.20)
                CTLineDraw(line, context)
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let result = device.makeTexture(descriptor: descriptor), let bytes = raw.baseAddress else {
                return nil
            }
            result.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: bytes, bytesPerRow: width * 4)
            return result
        }
        guard let texture else { return nil }
        let raster = Raster(texture: texture, padding: padding)
        textures[key] = raster
        order.append(key)
        if order.count > maxEntries {
            textures.removeValue(forKey: order.removeFirst())
        }
        return raster
    }
}
