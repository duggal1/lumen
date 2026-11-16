import Foundation
import CoreImage
import CoreVideo
import CoreGraphics
import os

/// Crops the chrome band off captured window frames on the GPU and delivers
/// every frame at one fixed output size, so a window that is resized while
/// recording still produces a valid track.
///
/// Threading: owned by the capture video queue. Every method runs on that
/// queue; no locks, no cross-queue state.
final class FrameCropper {
    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var output = CGSize.zero
    private var loggedFailure = false
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)

    init() {
        // Metal-backed: the crop and the resize are two draw calls per frame.
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        }
    }

    func configure(width: Int, height: Int) {
        let w = max(width & ~1, 2), h = max(height & ~1, 2)
        guard w != Int(output.width) || h != Int(output.height) else { return }
        output = CGSize(width: w, height: h)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
        pool = created
        loggedFailure = false
    }

    /// Returns a frame with the top `fraction` of the source removed, scaled to
    /// the fixed output size. `nil` only if the allocator refused, in which
    /// case the caller drops the frame instead of writing a wrong one.
    func crop(_ source: CVPixelBuffer, topFraction fraction: Double) -> CVPixelBuffer? {
        guard output.width > 1, output.height > 1, let pool else { return nil }
        let srcWidth = CGFloat(CVPixelBufferGetWidth(source))
        let srcHeight = CGFloat(CVPixelBufferGetHeight(source))
        guard srcWidth > 1, srcHeight > 1 else { return nil }
        let top = min(max((srcHeight * CGFloat(min(max(fraction, 0), 0.6))).rounded(), 0), srcHeight - 16)
        // Core Image is bottom-left origin: dropping the top band means
        // keeping the rectangle that starts at y = 0.
        let keep = CGRect(x: 0, y: 0, width: srcWidth, height: srcHeight - top)
        var image = CIImage(cvPixelBuffer: source).cropped(to: keep)
        let scaleX = output.width / keep.width, scaleY = output.height / keep.height
        if abs(scaleX - 1) > 0.0005 || abs(scaleY - 1) > 0.0005 {
            image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return nil }
        context.render(image, to: destination, bounds: CGRect(origin: .zero, size: output), colorSpace: colorSpace)
        return destination
    }

    func logIfNeeded(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        os_log("window frame crop failed: %@", log: .default, type: .error, message)
    }
}
