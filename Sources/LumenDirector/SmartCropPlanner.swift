import Foundation
import LumenCore
import LumenProject

/// A recorded interaction that should reveal browser chrome. Times are source
/// seconds; `rect` is a resolved element rect in source pixels.
public struct SmartCropIntent: Sendable, Equatable {
    public var t: Double
    public var tEnd: Double
    public var rect: CGRect
    public init(t: Double, tEnd: Double, rect: CGRect) {
        self.t = t; self.tEnd = tEnd; self.rect = rect
    }
}

/// Turns recorded input into a time-varying crop. Pure and deterministic.
///
/// The crop is defined geometrically: the user's Area is the content ROI, and
/// any resolved click or typing field that does not intersect it is "chrome"
/// and earns a reveal. AXFrame has no structured role, so this is deliberately
/// not a semantic browser-chrome classifier.
public enum SmartCropPlanner {
    /// Lead-in in OUTPUT seconds. Short enough to feel immediate, long enough
    /// for the quintic to have somewhere to travel.
    public static let leadIn = 0.18

    // MARK: - Intents from recorded evidence

    public static func intents(events: [InputEvent], ax: [AXFrame], typing: [TypingTrace],
                               source: SourceInfo, tm: TimeMap) -> [SmartCropIntent] {
        let W = Double(source.width), H = Double(source.height)
        let b = max(source.backingScale, 1)
        let sorted = events.sorted { $0.t < $1.t }
        var out: [SmartCropIntent] = []

        // Resolved clicks. A click without a resolved element has no rect and
        // cannot identify chrome, so it is ignored rather than guessed.
        for e in sorted where e.kind == .down && e.button == 0 && e.flags & 0x14 == 0 {
            guard e.t.isFinite, e.t >= tm.trimStart + 0.2, e.t <= tm.trimEnd - 0.2 else { continue }
            guard e.axFrameIndex > 0, Int(e.axFrameIndex) <= ax.count else { continue }
            let f = ax[Int(e.axFrameIndex) - 1]
            guard f.anchor?.resolved == true else { continue }
            let rect = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
            guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { continue }
            out.append(SmartCropIntent(t: e.t, tEnd: e.t + 0.12, rect: rect))
        }

        // Typing: the whole resolved field is the subject, never the caret.
        let keys = sorted.filter { $0.kind == .keyDown }
        for burst in sorted.typingBursts() where burst.t0 >= tm.trimStart + 0.2 && burst.t0 <= tm.trimEnd - 0.2 {
            guard let field = ZoomPlanner.resolvedField(t0: burst.t0, t1: burst.t1, keys: keys,
                                                        ax: ax, traces: typing, W: W, H: H, b: b) else { continue }
            guard field.width > 0, field.height > 0 else { continue }
            out.append(SmartCropIntent(t: burst.t0, tEnd: burst.t1, rect: field))
        }

        // A resolved, newly appearing dialog/sheet is a subject of its own.
        // Without this the crop keeps the old content ROI and the dialog is
        // cut off at the frame edge. The whole dialog is revealed.
        for d in ZoomPlanner.dialogIntents(ax: ax, events: sorted, markers: [], tm: tm, W: W, H: H) {
            guard let rect = d.frameRect, rect.width > 0, rect.height > 0 else { continue }
            out.append(SmartCropIntent(t: d.t, tEnd: max(d.tEnd, d.t + 0.4), rect: rect))
        }
        return out.sorted { $0.t < $1.t }
    }

    // MARK: - Reveal geometry

    /// One geometry function for both the offline planner and the live preview.
    /// `backingScale` converts margin points to source pixels.
    public static func revealRect(for rect: CGRect, roi: CGRect,
                                  config: SmartCropConfig, backingScale: Double) -> CGRect {
        let margin = max(config.revealMarginPt, 0) * max(backingScale, 1)
        return roi.union(rect).insetBy(dx: -margin, dy: -margin)
    }

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

    // MARK: - Plan

    public static func plan(config: SmartCropConfig, source: SourceInfo, tm: TimeMap,
                            intents: [SmartCropIntent]) -> CropTrack {
        guard config.isActive else { return CropTrack() }
        let W = Double(source.width), H = Double(source.height)
        let b = max(source.backingScale, 1)
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        guard let raw = config.roi else { return CropTrack() }
        let roi = SmartCropPlanner.aspectFit(
            CGRect(x: raw.minX * W, y: raw.minY * H, width: raw.width * W, height: raw.height * H)
                .intersection(bounds), source: bounds)
        guard roi.width > 1, roi.height > 1 else { return CropTrack() }

        struct Span {
            var start: Double, arrive: Double, end: Double, restore: Double
            var rect: CGRect
        }
        let ret = max(config.returnSeconds, 0.05)
        var spans: [Span] = []
        for i in intents {
            guard i.rect.origin.x.isFinite, i.rect.origin.y.isFinite,
                  i.rect.width.isFinite, i.rect.height.isFinite,
                  i.t.isFinite, i.tEnd.isFinite else { continue }
            guard i.rect.intersection(roi).isNull else { continue } // inside content: no reveal
            let expanded = SmartCropPlanner.aspectFit(
                revealRect(for: i.rect, roi: roi, config: config, backingScale: b).intersection(bounds),
                source: bounds)
            guard expanded.width > roi.width || expanded.height > roi.height else { continue }
            let tOut = tm.output(atSource: i.t)
            let eOut = tm.output(atSource: max(i.tEnd, i.t))
            let s = tOut - leadIn, a = tOut, e = max(eOut, a), r = e + ret
            if var last = spans.last, s <= last.restore + 0.05 {
                // Both merged rects carry the source aspect, but the union of
                // two same-aspect rects at different positions generally does
                // not. Re-fit it or the compositor stretches the revealed frame.
                let merged = last.rect.union(expanded).intersection(bounds)
                last.rect = SmartCropPlanner.aspectFit(merged, source: bounds)
                last.end = max(last.end, e)
                last.restore = max(last.restore, r)
                spans[spans.count - 1] = last
            } else {
                spans.append(Span(start: s, arrive: a, end: e, restore: r, rect: expanded))
            }
        }

        var keys: [CropTrack.Keyframe] = [CropTrack.Keyframe(t: 0, rect: roi)]
        for s in spans {
            keys.append(CropTrack.Keyframe(t: max(0, s.start), rect: roi))
            keys.append(CropTrack.Keyframe(t: max(0, s.arrive), rect: s.rect))
            keys.append(CropTrack.Keyframe(t: max(0, s.end), rect: s.rect))
            keys.append(CropTrack.Keyframe(t: max(0, s.restore), rect: roi))
        }
        // Coalesce duplicate times (a span ending exactly where the next begins).
        var merged: [CropTrack.Keyframe] = []
        for k in keys.sorted(by: { $0.t < $1.t }) {
            if let last = merged.last, abs(last.t - k.t) < 1e-6 {
                merged[merged.count - 1] = k
            } else {
                merged.append(k)
            }
        }
        return CropTrack(keys: merged)
    }
}
