import Foundation
import LumenProject

/// One source-pixel -> canvas-pixel transform for the preview, overlays and export.
/// Quartz event coordinates are already top-left; callers subtract the capture origin
/// and multiply by the capture's actual backing scale before using this transform.
public struct ZoomTransform: Sendable {
    public let source: SIMD2<Double>
    public let canvas: SIMD2<Double>
    public let videoRect: SIMD4<Double>
    public let cameraCenter: SIMD2<Double>
    public let scale: Double

    public init(canvas: SIMD2<Int>, source: SIMD2<Double>, style: Style,
                cameraCenter: SIMD2<Double>? = nil, scale: Double = 1) {
        let size = SIMD2<Double>(Double(canvas.x), Double(canvas.y))
        let inset = style.insets
        // Insets are canvas-width fractions, including the vertical ones.
        let left = size.x * inset.left, right = size.x * inset.right
        let top = size.x * inset.top, bottom = size.x * inset.bottom
        let availableW = max(size.x - left - right, 1)
        let availableH = max(size.y - top - bottom, 1)
        let aspect = source.x / max(source.y, 1)
        let fittedW = min(availableW, availableH * aspect)
        let videoSize = min(max(style.contentScale, 0.3), 2.0)
        let width = fittedW * videoSize, height = width / aspect
        let originX = left + (availableW - width) / 2
        let originY = top + (availableH - height) / 2
        self.source = source
        self.canvas = size
        self.videoRect = SIMD4(originX.rounded(), originY.rounded(), width.rounded(), height.rounded())
        self.scale = max(scale, 1)
        self.cameraCenter = Self.clamp(cameraCenter ?? source / 2, source: source, scale: self.scale)
    }

    /// The source viewport is always contained within the recording, even at the corners.
    public static func clamp(_ focus: SIMD2<Double>, source: SIMD2<Double>, scale: Double) -> SIMD2<Double> {
        let half = source / (2 * max(scale, 1))
        return SIMD2(min(max(focus.x, half.x), source.x - half.x),
                     min(max(focus.y, half.y), source.y - half.y))
    }

    public var viewport: SIMD4<Double> {
        let sz = source / scale
        return SIMD4(cameraCenter.x - sz.x / 2, cameraCenter.y - sz.y / 2, sz.x, sz.y)
    }

    public func sourceToCanvas(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let v = viewport
        return SIMD2(videoRect.x + (p.x - v.x) / v.z * videoRect.z,
                     videoRect.y + (p.y - v.y) / v.w * videoRect.w)
    }

    public func canvasToSource(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let v = viewport
        return SIMD2(v.x + (p.x - videoRect.x) / videoRect.z * v.z,
                     v.y + (p.y - videoRect.y) / videoRect.w * v.w)
    }

    public func sourceNormalized(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(p.x / max(source.x, 1), p.y / max(source.y, 1))
    }
}
