import Foundation
import simd
import LumenProject

/// Pure, deterministic geometry for cinematic 3D camera moves (PLAN 10.4.1).
///
/// Ownership: LumenRender. Threading: value type, safe on any thread, no Metal,
/// no clock, no allocation in the frame loop. All angles are DEGREES; all quad
/// coordinates are normalized to [-0.5, 0.5] of the content rect. This is
/// content math — it only ever reaches `contentFS`, never app chrome.
public enum CameraTilt {
    /// Lean yaw ceiling (PLAN 10.4.1).
    public static let maxYaw: Float = 8
    /// Lean pitch ceiling (PLAN 10.4.1).
    public static let maxPitch: Float = 6
    /// Float drift ceiling (PLAN 10.4.1 allows up to 2; the product cap is 1.5).
    public static let maxFloat: Float = 1.5
    /// Reveal entrance yaw; the one documented exception to `maxYaw`.
    public static let revealYaw: Float = 12
    /// Hard safety ceiling in the shader. Reveal's 12 degree entrance fits inside it.
    public static let shaderCeiling: Float = 18
    /// Perspective distance in canvas heights (PLAN 10.4.1).
    public static let perspectiveDistance: Float = 3
    /// Reveal entrance starts the content at 1 - this = 0.92 scale.
    public static let revealScaleDrop: Double = 0.08
    private static let deg: Float = .pi / 180

    // MARK: Control surface

    /// Mode-aware render-side clamp. This is the single gate a tilt passes
    /// through before it can reach the shader or the export. Crucially `.off`
    /// returns zero even when the incoming state carries a stale/nonzero tilt:
    /// disabling 3D therefore produces a completely flat frame, with no 3D
    /// value surviving anywhere in the render path.
    public static func effective(_ raw: SIMD2<Float>, mode: TiltMode,
                                 maxYaw: Double, maxPitch: Double, floatDeg: Double) -> SIMD2<Float> {
        switch mode {
        case .off:
            return .zero
        case .lean:
            return SIMD2(finite(raw.x, positive(maxYaw, cap: Self.maxYaw)),
                         finite(raw.y, positive(maxPitch, cap: Self.maxPitch)))
        case .float:
            let cap = min(positive(floatDeg, cap: maxFloat), maxFloat)
            return SIMD2(finite(raw.x, cap), finite(raw.y, cap))
        case .reveal:
            return SIMD2(finite(raw.x, revealYaw), finite(raw.y, positive(maxPitch, cap: Self.maxPitch)))
        }
    }

    /// Entrance scale envelope for Reveal: 0.92 at the 12 degree start, easing
    /// to 1.0 as the tilt settles. `1` for every other mode. Pure in the tilt,
    /// so it is identical in preview, sub-frames and export.
    public static func revealScale(mode: TiltMode, tilt: SIMD2<Float>) -> Double {
        switch mode {
        case .reveal:
            let amount = min(max(abs(finite(tilt.x, revealYaw)) / revealYaw, 0), 1)
            return 1 - revealScaleDrop * Double(amount)
        default:
            return 1
        }
    }

    public static func isFlat(_ tilt: SIMD2<Float>) -> Bool {
        abs(tilt.x) + abs(tilt.y) < 0.001
    }

    // MARK: Homography

    /// Maps a normalized quad coordinate into a normalized source coordinate.
    ///
    /// This is one perspective divide (a true homography, not a shear):
    /// `z = 1 + ax*n.x + ay*n.y`, `s = n * zmin / z`, where `zmin` is the depth
    /// at the nearest corner. Because `z >= zmin`, `|s| <= 0.5` for every pixel:
    /// the warp is a contraction that can never sample outside the viewport,
    /// the smart crop, or the source texture. The final clamp is a numerical
    /// safety net only — for any in-range tilt it never changes a value.
    public static func homography(_ n: SIMD2<Float>, tiltDeg: SIMD2<Float>) -> SIMD2<Float> {
        let qx = finite(n.x, 0.5), qy = finite(n.y, 0.5)
        let q = SIMD2<Float>(qx, qy)
        guard !isFlat(tiltDeg) else { return q }
        let yaw = Double(finite(tiltDeg.x, shaderCeiling)) * Double(deg)
        let pitch = Double(finite(tiltDeg.y, shaderCeiling)) * Double(deg)
        let ax = Float(tan(yaw) / Double(perspectiveDistance))
        let ay = Float(tan(pitch) / Double(perspectiveDistance))
        let zmin = 1 - 0.5 * (abs(ax) + abs(ay))
        let z = 1 + ax * q.x + ay * q.y
        let s = q * (zmin / max(z, 1e-4))
        return SIMD2(min(max(s.x, -0.5), 0.5), min(max(s.y, -0.5), 0.5))
    }

    /// Source-pixel sample point for one output pixel, including the
    /// intelligent Area crop. The returned point is always inside both the
    /// crop rect and the source texture, for any tilt and any camera center.
    public static func sourcePoint(normalized n: SIMD2<Float>, tiltDeg: SIMD2<Float>,
                                   camera: SIMD2<Double>, view: SIMD2<Double>,
                                   crop: CGRect, sourceSize: SIMD2<Double>) -> SIMD2<Double> {
        let s = homography(n, tiltDeg: tiltDeg)
        let p = camera + SIMD2<Double>(s) * view
        let bounds = validCrop(crop, sourceSize: sourceSize)
        return SIMD2(clampD(p.x, bounds.minX, bounds.maxX), clampD(p.y, bounds.minY, bounds.maxY))
    }

    /// Empty crop means "use the whole frame"; a crop is intersected with the
    /// source and normalized, so callers can rely on the returned rect.
    public static func validCrop(_ crop: CGRect, sourceSize: SIMD2<Double>) -> CGRect {
        guard crop.width > 1, crop.height > 1,
              crop.minX.isFinite, crop.minY.isFinite, crop.width.isFinite, crop.height.isFinite else {
            return CGRect(x: 0, y: 0, width: max(sourceSize.x, 0), height: max(sourceSize.y, 0))
        }
        let lo = SIMD2<Double>(max(crop.minX, 0), max(crop.minY, 0))
        let hi = SIMD2<Double>(min(crop.maxX, sourceSize.x), min(crop.maxY, sourceSize.y))
        return CGRect(x: lo.x, y: lo.y,
                      width: max(hi.x - lo.x, 0), height: max(hi.y - lo.y, 0))
    }

    // MARK: Numeric hygiene (hostile input must never become a NaN transform)

    private static func finite(_ v: Float, _ cap: Float) -> Float {
        guard v.isFinite else { return 0 }
        return min(max(v, -abs(cap)), abs(cap))
    }

    private static func positive(_ v: Double, cap: Float) -> Float {
        guard v.isFinite else { return cap }
        return min(max(Float(v), 0), abs(cap))
    }

    private static func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard v.isFinite else { return lo }
        return min(max(v, lo), max(hi, lo))
    }
}
