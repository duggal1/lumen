import Foundation
import CoreGraphics
import CoreText
import AppKit
import Metal
import LumenCore
import LumenProject

// Command-key pills are rasterised from vector glyphs into a Metal texture and
// composited through the SAME frosted-card path as captions, so preview and
// export share pixels and the scene behind the pill is genuinely blurred.
// All motion is a pure function of the timeline playhead: a 60 fps export and a
// scrub to the same timestamp land on the identical frame.

public struct ShortcutPose: Sendable, Equatable {
    public var opacity: Double
    public var scale: Double
    public var lift: Double
    public var blur: Double
    public init(opacity: Double, scale: Double, lift: Double, blur: Double) {
        self.opacity = opacity; self.scale = scale; self.lift = lift; self.blur = blur
    }
}

/// Critically-ish damped spring with one small overshoot, then a quiet fade.
/// `unit` is one design point at 1080 p and scales lift/blur with the video.
public func shortcutPose(at t: Double, start: Double, end: Double, unit: Double = 1) -> ShortcutPose {
    let duration = 0.42
    let u = min(max((t - start) / duration, 0), 1)
    // 1 - e^-7u cos(11u): rises fast, overshoots ~8%, settles by ~0.42 s.
    let spring = 1 - exp(-7 * u) * cos(11 * u)
    let settle = min(max(spring, 0), 1.09)
    let outDuration = 0.24
    let v = min(max((t - (end - outDuration)) / outDuration, 0), 1)
    let fade = 1 - (v * v * (3 - 2 * v))                 // smoothstep, zero slope at both ends
    return ShortcutPose(opacity: min(max(settle, 0), 1) * fade,
                        scale: (0.90 + 0.10 * settle) * (1 - 0.04 * v),
                        lift: (1 - settle) * 14 * unit - v * 4 * unit,
                        blur: (7 * (1 - min(settle, 1)) + 5 * v) * unit)
}

private struct PillRaster {
    let texture: any MTLTexture
    let padding: CGFloat
}

/// Raster cache + timeline sampler for shortcut pills.
final class ShortcutPillCache {
    private var textures: [String: PillRaster] = [:]
    private var order: [String] = []
    private let maxEntries = 48

    init() {}

    /// The API the Renderer hook calls. Returns sprites ready to append to the
    /// existing `sprites: [TextOverlaySprite]` array before card compositing.
    func sprites(events: [InputEvent], time: Double, plan: ShortcutOverlayPlan,
                 canvas: SIMD2<Int>, videoRect: SIMD4<Double>,
                 device: any MTLDevice) -> [TextOverlaySprite] {
        sprites(pills: ShortcutDetector.displays(in: events, plan: plan), time: time,
                plan: plan, canvas: canvas, videoRect: videoRect, device: device)
    }

    /// Renderer-facing entry point: `pills` are the Director's OUTPUT-time
    /// `timeline.derived?.shortcutPills` track, so no raw event log is needed.
    func sprites(pills: [ShortcutDisplay], time: Double, plan: ShortcutOverlayPlan,
                 canvas: SIMD2<Int>, videoRect: SIMD4<Double>,
                 device: any MTLDevice) -> [TextOverlaySprite] {
        guard plan.enabled else { return [] }
        let displays = pills
        let unit = Double(videoRect.w) / 1080.0
        var result: [TextOverlaySprite] = []
        for display in displays where time >= display.start && time <= display.end {
            let pose = shortcutPose(at: time, start: display.start, end: display.end, unit: unit)
            guard pose.opacity > 0.002 else { continue }
            let fontSize = CGFloat(videoRect.w) * 0.030        // ~32 pt at 1080 p
            guard let raster = texture(text: display.text, fontSize: fontSize,
                                       canvas: canvas, device: device) else { continue }
            let centerX = Double(videoRect.x + videoRect.z / 2)
            let anchorY: Double
            switch plan.position {
            case .topMiddle: anchorY = videoRect.y + videoRect.w * 0.11
            case .bottomMiddle: anchorY = videoRect.y + videoRect.w * 0.88
            }
            let halfH = Double(raster.texture.height) / 2 * pose.scale
            let y = min(max(anchorY + pose.lift, videoRect.y + halfH + 6),
                        videoRect.y + videoRect.w - halfH - 6)
            result.append(TextOverlaySprite(
                texture: raster.texture,
                center: SIMD2(Float(centerX), Float(y)),
                opacity: Float(pose.opacity),
                scale: Float(pose.scale),
                blur: Float(pose.blur),
                card: TextCard(radius: Float(raster.padding),
                               tint: SIMD4<Float>(0.09, 0.10, 0.13, 0.62))))
        }
        return result
    }

    private func texture(text: String, fontSize wanted: CGFloat,
                         canvas: SIMD2<Int>, device: any MTLDevice) -> PillRaster? {
        let key = "\(canvas.x)x\(canvas.y):\(text):\(wanted)"
        if let cached = textures[key] { return cached }
        let fontSize = max(11, min(wanted, CGFloat(canvas.y) * 0.09))
        let font = CTFontCreateWithName("SF Pro Text" as CFString, fontSize, nil)
        let attributed = NSMutableAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let padding = max(10, fontSize * 0.55)
        let width = max(2, min(canvas.x, Int(ceil(bounds.width + padding * 2))))
        let height = max(2, min(canvas.y, Int(ceil(bounds.height + padding * 2))))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let raster: PillRaster = pixels.withUnsafeMutableBytes({ raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.textPosition = CGPoint(x: padding - bounds.origin.x,
                                            y: padding - bounds.origin.y)
            CTLineDraw(line, context)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor),
                  let bytes = raw.baseAddress else { return nil }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: bytes, bytesPerRow: width * 4)
            return PillRaster(texture: texture, padding: padding)
        }) else { return nil }
        textures[key] = raster
        order.append(key)
        if order.count > maxEntries { textures.removeValue(forKey: order.removeFirst()) }
        return raster
    }
}
