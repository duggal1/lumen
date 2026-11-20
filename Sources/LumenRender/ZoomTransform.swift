import Foundation
import LumenProject
import LumenDirector
import LumenCore

/// One source-pixel -> canvas-pixel transform for the preview, overlays and export.
/// Quartz event coordinates are already top-left; callers subtract the capture origin
/// and multiply by the capture's actual backing scale before using this transform.
///
/// Invariant (renderer-wide): the content rect this type produces ALWAYS keeps the
/// source aspect. The zoom/camera layer samples a view of exactly the same aspect,
/// so a zoom is a true magnification. Note `clamp`/`viewport` here are the
/// full-source contract (no browser crop); the render path in Renderer.swift uses
/// `Geometry.containedCenter` instead, which fits the same invariant inside a crop.
public struct ZoomTransform: Sendable {
    public let source: SIMD2<Double>
    public let canvas: SIMD2<Double>
    public let videoRect: SIMD4<Double>
    public let cameraCenter: SIMD2<Double>
    public let scale: Double
    private let baseSize: SIMD2<Double>
    private let tilt: SIMD2<Float>

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
        // Swift's max(NaN, 1) is NaN (unlike C fmax). A non-finite zoom would
        // leak into every viewport and overlay as undefined coordinates.
        self.scale = scale.isFinite ? max(scale, 1) : 1
        self.cameraCenter = Self.clamp(cameraCenter ?? source / 2, source: source, scale: self.scale)
        baseSize = source
        tilt = .zero
    }

    public init(canvas size: SIMD2<Int>, source: SIMD2<Double>, timeline: Timeline, at time: Double) {
        let geometry = Geometry(canvas: size, src: source, style: timeline.style)
        let state = timeline.evaluate(at: time)
        let hasLayout = timeline.derived?.layout.samples.isEmpty == false && timeline.clipSource(atOutput: time) == nil
        let placed = hasLayout ? geometry.positioned(in: state.layout, contentScale: timeline.style.contentScale) : geometry
        let fallback = state.cropRect.isEmpty
            ? PxRect(x: 0, y: 0, w: source.x, h: source.y)
            : PxRect(x: state.cropRect.minX, y: state.cropRect.minY, w: state.cropRect.width, h: state.cropRect.height)
        let crop = state.crop.isValid ? state.crop : fallback
        let aspect = placed.content.z / max(placed.content.w, 1)
        let base = CropSpace.baseView(crop: crop, aspect: aspect)

        self.source = source
        canvas = placed.canvas
        videoRect = placed.content
        scale = state.cameraScale.isFinite ? max(Double(state.cameraScale), 1) : 1
        cameraCenter = Geometry.containedCenter(timeline.derived == nil ? source / 2 : SIMD2<Double>(state.cameraCenter),
                                                 crop: crop, aspect: aspect, scale: scale)
        baseSize = SIMD2(base.w, base.h)
        tilt = CameraTilt.effective(state.cameraTilt, mode: timeline.camera.tilt,
                                    maxYaw: timeline.camera.maxYaw, maxPitch: timeline.camera.maxPitch)
    }

    /// The source viewport is always contained within the recording, even at the corners.
    public static func clamp(_ focus: SIMD2<Double>, source: SIMD2<Double>, scale: Double) -> SIMD2<Double> {
        let s = scale.isFinite ? max(scale, 1) : 1
        let half = source / (2 * s)
        func axis(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            guard v.isFinite, lo.isFinite, hi.isFinite, hi >= lo else { return (lo + hi) / 2 }
            return min(max(v, lo), hi)
        }
        return SIMD2(axis(focus.x, half.x, source.x - half.x),
                     axis(focus.y, half.y, source.y - half.y))
    }

    public var viewport: SIMD4<Double> {
        let sz = baseSize / scale
        return SIMD4(cameraCenter.x - sz.x / 2, cameraCenter.y - sz.y / 2, sz.x, sz.y)
    }

    public func sourceToCanvas(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let v = viewport
        let normalized = SIMD2<Float>(Float((p.x - v.x) / v.z - 0.5), Float((p.y - v.y) / v.w - 0.5))
        let position = CameraTilt.inverseHomography(normalized, tiltDeg: tilt)
        return SIMD2(videoRect.x + (Double(position.x) + 0.5) * videoRect.z,
                     videoRect.y + (Double(position.y) + 0.5) * videoRect.w)
    }

    public func canvasToSource(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let v = viewport
        let normalized = SIMD2<Float>(Float((p.x - videoRect.x) / videoRect.z - 0.5),
                                      Float((p.y - videoRect.y) / videoRect.w - 0.5))
        let position = CameraTilt.homography(normalized, tiltDeg: tilt)
        return SIMD2(v.x + (Double(position.x) + 0.5) * v.z, v.y + (Double(position.y) + 0.5) * v.w)
    }

    public func sourceNormalized(_ p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(p.x / max(source.x, 1), p.y / max(source.y, 1))
    }
}
