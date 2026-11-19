import Foundation
import CoreGraphics
import LumenCore
import LumenProject

/// Geometry helpers retained for the live Area-crop preview (`LiveCamera`).
///
/// The browser-chrome detector and the offline crop planner that used to live
/// here are superseded by `ViewportRecorder` (AXWebArea evidence) and
/// `CropPlanner` (480 Hz crop track). What remains is the legacy aspect-fitting
/// maths for the Area-crop ROI, which is not the same operation as
/// `CropSpace.fit`/`baseView`: `aspectFit` grows a rect TO the source aspect,
/// `fitInside` keeps the source aspect INSIDE a rect.
/// Ownership: none. Threading: pure static functions, callable on any queue.
public enum SmartCropPlanner {
    /// The compositor draws the visible crop into a content rect with the
    /// source aspect ratio, so every crop rect must carry that same aspect or
    /// the picture stretches. Grow around the centre, then clamp into source.
    public static func aspectFit(_ rect: CGRect, source: CGRect) -> CGRect {
        guard rect.width > 1, rect.height > 1, source.width > 1, source.height > 1 else { return rect }
        let target = source.width / source.height
        var w = rect.width, h = rect.height
        if w / h < target { w = h * target } else { h = w / target }
        if w > source.width { w = source.width; h = w / target }
        if h > source.height { h = source.height; w = h * target }
        let x = min(max(rect.midX - w / 2, source.minX), source.maxX - w)
        let y = min(max(rect.midY - h / 2, source.minY), source.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The inverse fit: keep the source aspect while staying INSIDE `rect`.
    public static func fitInside(_ rect: CGRect, source: CGRect) -> CGRect {
        guard rect.width > 1, rect.height > 1, source.width > 1, source.height > 1 else { return rect }
        let target = source.width / source.height
        var w = rect.width, h = rect.height
        if w / h > target { w = h * target } else { h = w / target }
        if w > source.width { w = source.width; h = w / target }
        if h > source.height { h = source.height; w = h * target }
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    /// Reveal union used by the legacy Area-crop preview. `backingScale`
    /// converts margin points into source pixels.
    public static func revealRect(for rect: CGRect, roi: CGRect,
                                  config: SmartCropConfig, backingScale: Double) -> CGRect {
        let margin = max(config.revealMarginPt, 0) * max(backingScale, 1)
        return roi.union(rect).insetBy(dx: -margin, dy: -margin)
    }
}
