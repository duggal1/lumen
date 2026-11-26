import Foundation
import LumenCore

/// Pure geometry helpers for the three crop seams (camera, layout, cursor).
/// The camera solver keeps its quintic/480 Hz logic; these functions only
/// change WHICH source rect is "zoom 1" and how coordinates map into it.
/// Ownership: none. Threading: all functions are pure and callable on any queue.
public enum CropSpace {
    /// Zoom-1 view inside the crop. `aspect == nil` means the frame follows the
    /// crop aspect (`.fit`); otherwise the crop is side/top-trimmed to the
    /// requested canvas aspect (`.fillFollow`).
    public static func baseView(crop: PxRect, aspect: Double?) -> PxRect {
        guard let a = aspect, a.isFinite, a > 0, crop.isValid else { return crop }
        return crop.aspect > a
            ? crop.centered(w: crop.h * a, h: crop.h)
            : crop.centered(w: crop.w, h: crop.w / a)
    }

    /// Visible source rect for camera state `(u, v)` in crop-normalised coords
    /// and log-zoom RELATIVE to the crop. The centre stays inside the crop.
    public static func visible(crop: PxRect, aspect: Double?, u: Double, v: Double, logZ: Double) -> PxRect {
        guard crop.isValid else { return crop }
        let base = baseView(crop: crop, aspect: aspect)
        let z = exp(min(max(logZ.isFinite ? logZ : 0, 0), log(10_000.0)))
        let vw = base.w / z, vh = base.h / z
        let nx = min(max(u.isFinite ? u : 0.5, 0), 1)
        let ny = min(max(v.isFinite ? v : 0.5, 0), 1)
        let cx = min(max(crop.x + nx * crop.w, crop.x + vw / 2), crop.maxX - vw / 2)
        let cy = min(max(crop.y + ny * crop.h, crop.y + vh / 2), crop.maxY - vh / 2)
        return PxRect(x: cx - vw / 2, y: cy - vh / 2, w: vw, h: vh)
    }

    /// Converts a source-pixel target to crop-normalised coordinates AT THE
    /// TARGET'S OWN TIME, so a moving crop never shifts a settled camera shot.
    public static func normalise(_ px: Double, _ py: Double, crop: PxRect) -> (u: Double, v: Double) {
        guard crop.isValid else { return (0.5, 0.5) }
        return (px.isFinite ? (px - crop.x) / crop.w : 0.5,
                py.isFinite ? (py - crop.y) / crop.h : 0.5)
    }

    /// Largest rect of `aspect` inside `box`, centred. Evaluated per tick
    /// OUTSIDE the layout spring so view aspect always equals frame aspect.
    public static func fit(aspect: Double, in box: PxRect) -> PxRect {
        guard aspect.isFinite, aspect > 0, box.isValid else { return box }
        return aspect > box.aspect
            ? box.centered(w: box.w, h: box.w / aspect)
            : box.centered(w: box.h * aspect, h: box.h)
    }

    /// 1 inside the crop, smoothly 0 within `feather` source px outside it.
    /// Multiply the cursor's opacity by this so the pointer never leaves frame.
    public static func cursorVisibility(x: Double, y: Double, crop: PxRect, feather: Double = 24) -> Double {
        guard crop.isValid, x.isFinite, y.isFinite else { return 0 }
        if !feather.isFinite || feather <= 0 { return crop.contains(x, y) ? 1 : 0 }
        let d = hypot(max(crop.x - x, 0, x - crop.maxX), max(crop.y - y, 0, y - crop.maxY))
        let t = min(max(1 - d / feather, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
