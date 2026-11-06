import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reference-image golden suite primitive. RGBA8, row-major, top-left origin.
/// Deliberately small: render a frame, compare, fail with a measurable diff.
public struct GoldenImage: Sendable, Equatable {
    public var width: Int, height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = max(width, 0); self.height = max(height, 0)
        let expected = self.width * self.height * 4
        self.pixels = pixels.count == expected ? pixels : Array(pixels.prefix(expected))
    }

    public init(pixelBuffer pb: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else {
            throw GoldenError.unsupportedFormat
        }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw GoldenError.unreadable }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        rgba.withUnsafeMutableBytes { dst in
            guard let out = dst.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let src = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                let row = src.advanced(by: y * stride)
                let o = out.advanced(by: y * w * 4)
                for x in 0..<w {
                    o[x * 4 + 0] = row[x * 4 + 2]
                    o[x * 4 + 1] = row[x * 4 + 1]
                    o[x * 4 + 2] = row[x * 4 + 0]
                    o[x * 4 + 3] = row[x * 4 + 3]
                }
            }
        }
        self.init(width: w, height: h, pixels: rgba)
    }

    public static func loadPNG(_ url: URL) throws -> GoldenImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw GoldenError.unreadable }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return GoldenImage(width: w, height: h, pixels: rgba)
    }

    public func writePNG(_ url: URL) throws {
        var bytes = pixels
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw GoldenError.unreadable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw GoldenError.unreadable }
        bytes.removeAll()
    }
}

public enum GoldenError: LocalizedError, Equatable {
    case unsupportedFormat, unreadable
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Golden capture needs a 32BGRA pixel buffer."
        case .unreadable: "Could not read or write the golden image."
        }
    }
}

public struct GoldenDiff: Sendable, Equatable {
    public var differingPixels: Int
    public var totalPixels: Int
    public var maxChannelDelta: Int
    public var meanChannelDelta: Double

    public var differingFraction: Double {
        totalPixels > 0 ? Double(differingPixels) / Double(totalPixels) : 1
    }

    /// `tolerance` is the allowed fraction of differing pixels. A dimension
    /// mismatch always fails (it returns 1.0).
    public func passes(tolerance: Double = 0.002) -> Bool {
        differingFraction <= max(tolerance, 0)
    }

    public var summary: String {
        String(format: "%d/%d pixels differ (%.3f%%), max channel Δ %d, mean %.3f",
               differingPixels, totalPixels, differingFraction * 100, maxChannelDelta, meanChannelDelta)
    }
}

public enum GoldenComparison {
    public static func compare(_ reference: GoldenImage, _ candidate: GoldenImage) -> GoldenDiff {
        let n = min(reference.pixels.count, candidate.pixels.count)
        guard reference.width == candidate.width, reference.height == candidate.height else {
            return GoldenDiff(differingPixels: max(reference.width * reference.height, candidate.width * candidate.height),
                              totalPixels: max(reference.width * reference.height, candidate.width * candidate.height, 1),
                              maxChannelDelta: 255, meanChannelDelta: 255)
        }
        var differing = 0, maxDelta = 0, sumDelta = 0
        var i = 0
        while i + 3 < n {
            let d = max(abs(Int(reference.pixels[i]) - Int(candidate.pixels[i])),
                        abs(Int(reference.pixels[i + 1]) - Int(candidate.pixels[i + 1])),
                        abs(Int(reference.pixels[i + 2]) - Int(candidate.pixels[i + 2])),
                        abs(Int(reference.pixels[i + 3]) - Int(candidate.pixels[i + 3])))
            if d > 0 { differing += 1; maxDelta = max(maxDelta, d); sumDelta += d }
            i += 4
        }
        let total = max(reference.width * reference.height, 1)
        return GoldenDiff(differingPixels: differing, totalPixels: total, maxChannelDelta: maxDelta,
                          meanChannelDelta: differing > 0 ? Double(sumDelta) / Double(differing) : 0)
    }
}

/// Run manually: `lumen-cli golden <project> --reference <dir>` captures frames
/// at fixed timestamps, compares PNGs and exits non-zero on drift. `--update`
/// writes the candidate as the new reference.
public enum GoldenHarness {
    public static func capture(pixelBuffer: CVPixelBuffer, reference: URL) throws -> (GoldenImage, GoldenDiff) {
        let candidate = try GoldenImage(pixelBuffer: pixelBuffer)
        let expected = try GoldenImage.loadPNG(reference)
        return (candidate, GoldenComparison.compare(expected, candidate))
    }

    public static func save(pixelBuffer: CVPixelBuffer, to url: URL) throws {
        try GoldenImage(pixelBuffer: pixelBuffer).writePNG(url)
    }
}
