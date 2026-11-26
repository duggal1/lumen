import SwiftUI
import AppKit
import CoreGraphics

/// Finrow binary-alpha treatment using native SF Symbols as source.
/// Bounded cache; tint is applied by SwiftUI, not baked into the raster.
@MainActor private enum PixelSymbolCache {
    static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 512 * 1024
        return cache
    }()

    static func image(_ rawName: String, grid: Int) -> NSImage? {
        let name = IconSymbols.resolve(rawName, fallback: "questionmark")
        let key = "\(name):\(grid)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let source = base.withSymbolConfiguration(.init(pointSize: 48, weight: .medium)) ?? base
        guard let ctx = CGContext(data: nil, width: grid, height: grid, bitsPerComponent: 8,
                                  bytesPerRow: grid * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let buffer = ctx.data else { return nil }
        let size = source.size
        guard size.width > 0, size.height > 0 else { return nil }
        let extent = CGFloat(grid - 2)
        let scale = min(extent / size.width, extent / size.height)
        let width = size.width * scale, height = size.height * scale
        let rect = CGRect(x: (CGFloat(grid) - width) / 2, y: (CGFloat(grid) - height) / 2,
                          width: width, height: height)
        ctx.clear(CGRect(x: 0, y: 0, width: CGFloat(grid), height: CGFloat(grid)))
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: grid * grid * 4)
        var occupied = 0
        for i in 0..<(grid * grid) {
            let offset = i * 4
            let alpha: UInt8 = pixels[offset + 3] >= 64 ? 255 : 0
            pixels[offset] = 0; pixels[offset + 1] = 0; pixels[offset + 2] = 0
            pixels[offset + 3] = alpha
            if alpha != 0 { occupied += 1 }
        }
        guard occupied > 0, let cg = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(grid), height: CGFloat(grid)))
        image.isTemplate = true
        images.setObject(image, forKey: key, cost: grid * grid * 4)
        return image
    }
}

struct PixelSymbol: View {
    let name: String
    let size: CGFloat
    init(_ name: String, size: CGFloat = 14) { self.name = name; self.size = size }
    var body: some View {
        let grid = size <= 10 ? 8 : size <= 16 ? 10 : size <= 24 ? 12 : 16
        Group {
            if let image = PixelSymbolCache.image(name, grid: grid) {
                Image(nsImage: image).renderingMode(.template).resizable().interpolation(.none)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: IconSymbols.resolve(name, fallback: "questionmark"))
                    .font(.system(size: size))
            }
        }.accessibilityHidden(true)
    }
}

struct PixelSymbolLabel: View {
    let title: String
    let symbol: String
    init(_ title: String, symbol: String) { self.title = title; self.symbol = symbol }
    var body: some View { HStack(spacing: 6) { PixelSymbol(symbol); Text(title) } }
}
