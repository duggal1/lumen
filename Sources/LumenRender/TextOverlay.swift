import Foundation
import CoreGraphics
import CoreText
import Metal
import LumenProject
import LumenDirector

/// A pre-rasterized text layer composited by the same Metal path in preview and export.
struct TextOverlaySprite {
    let texture: any MTLTexture
    let center: SIMD2<Float>            // output canvas pixels, top-left origin
    let opacity: Float
}

private struct TextPart {
    let value: String
    let color: RGBA
}

/// CoreText glyph rasterization is cached by text/style, not repeated for every video frame.
/// Renderer owns this object on its render queue; the bounded cache is never shared with UI.
/// Critically damped step response, 0 to 1. omega 20 settles in ~0.33 s.
func settle(_ t: Double, omega: Double) -> Double {
    let x = omega * max(t, 0)
    return 1 - exp(-x) * (1 + x)
}

struct CaptionPose { var opacity, lift, scale: Double }

/// Pure function of time (offline export is deterministic): blur-in/out for
/// the whole block. Opacity eases; lift and scale follow the spring.
func captionPose(at t: Double, shownAt: Double, hiddenAt: Double, frameHeight: Double) -> CaptionPose {
    let k = settle(t - shownAt, omega: 20) * (1 - settle(t - hiddenAt, omega: 26))
    let e = k * k * (3 - 2 * k)
    return CaptionPose(opacity: e,
                       lift: frameHeight * 0.006 * (1 - k),
                       scale: 0.985 + 0.015 * k)
}

final class TextOverlayCache {
    private var textures: [String: any MTLTexture] = [:]
    private var order: [String] = []
    private let maxEntries = 48

    func caption(_ chunk: CaptionChunk, style: CaptionStyle, time: Double,
                 canvas: SIMD2<Int>, videoRect: SIMD4<Double>,
                 device: any MTLDevice) -> TextOverlaySprite? {
        guard !chunk.lines.isEmpty else { return nil }
        // Spoken word full white; the rest at ~60% white. Orange stays an
        // option via the highlight swatch, not the default.
        let lines = chunk.lines.map { line in
            line.map { word in
                let current = style.wordHighlight && time >= word.start && time < word.end
                var c = current ? style.highlightColor : style.color
                if style.wordHighlight && !current { c.a *= 0.6 }
                return TextPart(value: word.text, color: c)
            }
        }
        // Scale with the actual video, not the outer canvas/padding. Both
        // Studio and export share this rasterization and its layout bounds.
        let fontSize = CGFloat(videoRect.w) * CGFloat(max(style.size, 0.015))
        let safeWidth = max(1, Int(videoRect.z * 0.88))
        guard let texture = texture(lines: lines, fontSize: fontSize, bold: style.bold, typeface: style.font,
                                    pill: style.pill, canvas: canvas, maxWidth: safeWidth,
                                    device: device) else { return nil }
        let opacity: Float
        var lift = 0.0
        switch style.animation {
        case .fade:
            opacity = Float(max(0, min(1, (time - chunk.start) / 0.18,
                                   (chunk.end - time) / 0.18)))
        case .blur:
            let pose = captionPose(at: time, shownAt: chunk.start, hiddenAt: chunk.end,
                                   frameHeight: Double(videoRect.w))
            opacity = Float(pose.opacity)
            lift = pose.lift
        default:
            opacity = 1
        }
        let halfH = Double(texture.height) / 2
        let desiredY = videoRect.y + videoRect.w * chunk.y - lift
        let y = min(max(desiredY, videoRect.y + halfH + 8), videoRect.y + videoRect.w - halfH - 8)
        return TextOverlaySprite(texture: texture,
                                 center: SIMD2(Float(videoRect.x + videoRect.z / 2), Float(y)),
                                 opacity: opacity)
    }

    func manual(_ frame: TextFrame, canvas: SIMD2<Int>, device: any MTLDevice) -> TextOverlaySprite? {
        guard !frame.text.isEmpty else { return nil }
        let lines = frame.text.components(separatedBy: "\n").prefix(5).map {
            [TextPart(value: $0, color: frame.color)]
        }
        guard let texture = texture(lines: lines, fontSize: CGFloat(canvas.y) * CGFloat(max(frame.size, 0.015)),
                                    bold: true, pill: nil, canvas: canvas, device: device) else { return nil }
        return TextOverlaySprite(texture: texture,
                                 center: SIMD2(frame.center.x * Float(canvas.x), frame.center.y * Float(canvas.y)),
                                 opacity: frame.opacity)
    }

    private func texture(lines: [[TextPart]], fontSize wanted: CGFloat, bold: Bool, typeface: CaptionFont = .sfPro,
                         pill: RGBA?, canvas: SIMD2<Int>, maxWidth: Int? = nil,
                         device: any MTLDevice) -> (any MTLTexture)? {
        let maxCharacters = lines.map { $0.reduce(0) { $0 + $1.value.count + 1 } }.max() ?? 1
        let widthLimit = max(2, min(maxWidth ?? canvas.x, canvas.x))
        let fontSize = max(10, min(wanted, CGFloat(widthLimit) * 1.15 / CGFloat(max(1, maxCharacters))))
        let identifier = lines.map { row in
            row.map { p in
                "\(p.value)@\(p.color.r),\(p.color.g),\(p.color.b),\(p.color.a)"
            }.joined(separator: "/")
        }.joined(separator: "\n")
        let key = "\(canvas.x)x\(canvas.y):\(fontSize):\(bold):\(typeface.rawValue):\(pill.map { "\($0.r),\($0.g),\($0.b),\($0.a)" } ?? "none"):\(identifier)"
        if let cached = textures[key] { return cached }

        let font = CTFontCreateWithName((bold ? typeface.postScriptBold : typeface.postScript) as CFString, fontSize, nil)
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
            if let pill {
                context.setFillColor(CGColor(red: CGFloat(pill.r), green: CGFloat(pill.g),
                                             blue: CGFloat(pill.b), alpha: CGFloat(pill.a)))
                context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                                       cornerWidth: padding, cornerHeight: padding, transform: nil))
                context.fillPath()
            }
            // Caption type remains legible over both white apps and dark footage
            // without falling back to an opaque black rectangle.
            if pill != nil {
                context.setShadow(offset: CGSize(width: 0, height: -1),
                                  blur: max(2, fontSize * 0.1),
                                  color: CGColor(gray: 0, alpha: 0.70))
            }
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
        textures[key] = texture
        order.append(key)
        if order.count > maxEntries {
            textures.removeValue(forKey: order.removeFirst())
        }
        return texture
    }
}
