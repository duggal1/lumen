import Foundation
import simd

/// Pure source-to-canvas mask geometry. Source coordinates are always used
/// even after manual zoom, auto-zoom, or aspect-ratio changes.
public enum PrivacyMaskGeometry {
    public static func canvasRect(_ rect: SIMD4<Float>, geometry: Geometry,
                                  camera: SIMD2<Double>, scale: Double) -> SIMD4<Float>? {
        guard rect.x.isFinite, rect.y.isFinite, rect.z.isFinite, rect.w.isFinite,
              rect.z > 0, rect.w > 0 else { return nil }
        let source = geometry.src
        let x0 = max(Double(rect.x), 0), y0 = max(Double(rect.y), 0)
        let x1 = min(Double(rect.x + rect.z), source.x)
        let y1 = min(Double(rect.y + rect.w), source.y)
        guard x1 > x0, y1 > y0 else { return nil }
        let a = geometry.toCanvas(SIMD2(x0, y0), cam: camera, scale: scale)
        let b = geometry.toCanvas(SIMD2(x1, y1), cam: camera, scale: scale)
        return SIMD4(Float(a.x), Float(a.y), Float(b.x - a.x), Float(b.y - a.y))
    }

    /// A single pixel of UI paint from OUTSIDE the protected source rect is
    /// safe to extend across that rect. Never sample sensitive pixels for the
    /// default Blend mode. Solid fill is used if no safe neighbor exists.
    public static func outsideSample(_ rect: SIMD4<Float>,
                                     sourceSize: SIMD2<Float>) -> SIMD2<Float>? {
        guard rect.z > 0, rect.w > 0, sourceSize.x > 0, sourceSize.y > 0 else { return nil }
        let cx = min(max(rect.x + rect.z * 0.5, 0.5), sourceSize.x - 0.5)
        let cy = min(max(rect.y + rect.w * 0.5, 0.5), sourceSize.y - 0.5)
        let left = max(rect.x, 0), top = max(rect.y, 0)
        let right = max(sourceSize.x - (rect.x + rect.z), 0)
        let bottom = max(sourceSize.y - (rect.y + rect.w), 0)
        let candidates: [(Float, SIMD2<Float>)] = [
            (left, SIMD2(rect.x - min(16, left * 0.5), cy)),
            (right, SIMD2(rect.x + rect.z + min(16, right * 0.5), cy)),
            (top, SIMD2(cx, rect.y - min(16, top * 0.5))),
            (bottom, SIMD2(cx, rect.y + rect.w + min(16, bottom * 0.5)))
        ]
        guard let best = candidates.max(by: { $0.0 < $1.0 }), best.0 >= 8 else { return nil }
        return SIMD2(min(max(best.1.x, 0.5), sourceSize.x - 0.5),
                     min(max(best.1.y, 0.5), sourceSize.y - 0.5))
    }
}
