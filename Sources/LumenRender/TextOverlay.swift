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

/// Pure function of time (offline export is deterministic): blur-in/out for
/// the whole block. Opacity eases; lift, scale and blur follow the spring.
func captionPose(at t: Double, shownAt: Double, hiddenAt: Double, frameHeight: Double) -> CaptionPose {
    let k = settle(t - shownAt, omega: 20) * (1 - settle(t - hiddenAt, omega: 26))
    let e = k * k * (3 - 2 * k)
    return CaptionPose(opacity: e,
                       lift: frameHeight * 0.006 * (1 - k),
                       scale: 0.985 + 0.015 * k,
                       blur: Double(frameHeight * 0.005) * (1 - k))
}

final class TextOverlayCache {
    private var textures: [String: Raster] = [:]
    private var order: [String] = []
    private let maxEntries = 64

    func caption(_ chunk: CaptionChunk, style: CaptionStyle, time: Double,
                 canvas: SIMD2<Int>, videoRect: SIMD4<Double>,
                 device: any MTLDevice) -> TextOverlaySprite? {
        guard !chunk.lines.isEmpty else { return nil }
        // Spoken word is full white; the rest at ~60% white. Adjacent words
        // crossfade over 80 ms instead of snapping colour on the exact frame.
        // The blend is quantized to 1/16 so the raster cache stays bounded.
        let fade = 0.08
        let lines = chunk.lines.map { line in
            line.map { word -> TextPart in
                guard style.wordHighlight else { return TextPart(value: word.text, color: style.color) }
                let inT = max(0, min(1, (time - word.start) / fade))
                let outT = max(0, min(1, (word.end - time) / fade))
                let on = (min(inT, outT) * 16).rounded() / 16
                var dim = style.color
                dim.a *= 0.6
                return TextPart(value: word.text, color: mix(dim, style.highlightColor, on))
            }
        }
        // Scale with the actual video, not the outer canvas/padding. Both
        // Studio and export share this rasterization and its layout bounds.
        let fontSize = CGFloat(videoRect.w) * CGFloat(max(style.size, 0.015))
        let safeWidth = max(1, Int(videoRect.z * 0.88))
        guard let raster = texture(lines: lines, fontSize: fontSize, bold: style.bold, typeface: style.font,
                                   canvas: canvas, maxWidth: safeWidth, device: device) else { return nil }
        let opacity: Float
        var lift = 0.0, scale = 1.0
        var blur: Float = 0
        switch style.animation {
        case .fade:
            opacity = Float(max(0, min(1, (time - chunk.start) / 0.18,
                                   (chunk.end - time) / 0.18)))
        case .blur:
            let pose = captionPose(at: time, shownAt: chunk.start, hiddenAt: chunk.end,
                                   frameHeight: Double(videoRect.w))
            opacity = Float(pose.opacity)
            lift = pose.lift
            scale = pose.scale
            blur = Float(pose.blur)
        case .pop:
            let pose = captionPose(at: time, shownAt: chunk.start, hiddenAt: chunk.end,
                                   frameHeight: Double(videoRect.w))
            opacity = Float(pose.opacity)
            scale = 0.82 + 0.18 * pose.scale
        case .slide:
            let pose = captionPose(at: time, shownAt: chunk.start, hiddenAt: chunk.end,
                                   frameHeight: Double(videoRect.w))
            opacity = Float(pose.opacity)
            lift = -Double(videoRect.w) * 0.035 * (1 - pose.opacity)
        case .none:
            opacity = 1
        }
        let halfH = Double(raster.texture.height) / 2 * scale
        let desiredY = videoRect.y + videoRect.w * chunk.y - lift
        let y = min(max(desiredY, videoRect.y + halfH + 8), videoRect.y + videoRect.w - halfH - 8)
        let card = style.pill.map { TextCard(radius: Float(raster.padding), tint: $0.simd) }
        return TextOverlaySprite(texture: raster.texture,
                                 center: SIMD2(Float(videoRect.x + videoRect.z / 2), Float(y)),
                                 opacity: opacity, scale: Float(scale), blur: blur, card: card)
    }

    func manual(_ frame: TextFrame, canvas: SIMD2<Int>, device: any MTLDevice) -> TextOverlaySprite? {
        guard !frame.text.isEmpty else { return nil }
        let lines = frame.text.components(separatedBy: "\n").prefix(5).map {
            [TextPart(value: $0, color: frame.color)]
        }
        guard let raster = texture(lines: lines, fontSize: CGFloat(canvas.y) * CGFloat(max(frame.size, 0.015)),
                                   bold: true, canvas: canvas, device: device) else { return nil }
        return TextOverlaySprite(texture: raster.texture,
                                 center: SIMD2(frame.center.x * Float(canvas.x), frame.center.y * Float(canvas.y)),
                                 opacity: frame.opacity)
    }

    private func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> RGBA {
        let f = Float(t)
        return RGBA(r: a.r + (b.r - a.r) * f, g: a.g + (b.g - a.g) * f,
                    b: a.b + (b.b - a.b) * f, a: a.a + (b.a - a.a) * f)
    }

    /// The system font is the real SF Pro; `postScript` names fall back to
    /// Helvetica on machines that do not ship them.
    private func coreFont(_ typeface: CaptionFont, bold: Bool, size: CGFloat) -> CTFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        switch typeface {
        case .sfPro:
            if let f = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) { return f }
        case .sfRounded:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if let desc = base.fontDescriptor.withDesign(.rounded) {
                return CTFontCreateWithFontDescriptor(desc as CTFontDescriptor, size, nil)
            }
            if let f = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) { return f }
        case .newYork:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            if let desc = base.fontDescriptor.withDesign(.serif) {
                return CTFontCreateWithFontDescriptor(desc as CTFontDescriptor, size, nil)
            }
        case .menlo:
            return CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo") as CFString, size, nil)
        }
        return CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
    }

    private func texture(lines: [[TextPart]], fontSize wanted: CGFloat, bold: Bool, typeface: CaptionFont = .sfPro,
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
        let key = "\(canvas.x)x\(canvas.y):\(fontSize):\(bold):\(typeface.rawValue):\(identifier)"
        if let cached = textures[key] { return cached }

        let font = coreFont(typeface, bold: bold, size: fontSize)
        let coreLines: [CTLine] = lines.map { parts in
            let attr = NSMutableAttributedString(string: "")
            for (index, part) in parts.enumerated() {
                let color = CGColor(red: CGFloat(part.color.r), green: CGFloat(part.color.g),
                                    blue: CGFloat(part.color.b), alpha: CGFloat(part.color.a))
                let prefix = index == 0 ? "" : " "
                attr.append(NSAttributedString(string: prefix + part.value, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
                ]))
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
