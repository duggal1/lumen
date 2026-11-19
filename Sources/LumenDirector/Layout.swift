import Foundation
import LumenCore
import LumenProject

enum LayoutResolver {
    /// Content (screen) rect, canvas-normalized, fitted into the padded canvas keeping the source aspect.
    static func contentRect(aspect a: Double, srcAspect sa: Double, insets: EdgeInsetsN) -> SIMD4<Double> {
        contentRect(aspect: a, cropAspect: sa, insets: insets)
    }

    /// Crop-aware `.fit`: the largest rect of the crop's aspect inside the
    /// padded box, evaluated per tick outside the layout spring so the view
    /// aspect always equals the frame aspect. Coordinates are canvas-normalized
    /// with y/h scaled by `a`, matching the legacy `contentRect`.
    static func contentRect(aspect a: Double, cropAspect: Double, insets: EdgeInsetsN) -> SIMD4<Double> {
        let ch = 1 / a                                            // canvas height in width units
        let aw = max(1 - insets.left - insets.right, 0.05), ah = max(ch - insets.top - insets.bottom, 0.05)
        let box = PxRect(x: insets.left, y: insets.top, w: aw, h: ah)
        let fit = CropSpace.fit(aspect: cropAspect, in: box)
        return SIMD4(fit.x, fit.y * a, fit.w, fit.h * a)
    }

    /// Square bubble anchored to a corner, canvas-normalized.
    static func bubbleRect(corner: WebcamLayout.Corner, size: Double, aspect a: Double) -> SIMD4<Double> {
        let ch = 1 / a, s = min(size, 0.45 * min(1, ch)), m = 0.03
        let w = s, h = s * a, my = m * a
        let left = corner == .topLeft || corner == .bottomLeft, top = corner == .topLeft || corner == .topRight
        return SIMD4(left ? m : 1 - m - w, top ? my : 1 - my - h, w, h)
    }

    static func target(_ kind: LayoutKind, _ s: LayoutSettings, corner: WebcamLayout.Corner, aspect a: Double, srcAspect: Double,
                       insets: EdgeInsetsN, webcamAspect ar: Double,
                       crop: PxRect? = nil, fillFollow: Bool = false) -> ResolvedLayout {
        let ch = 1 / a
        // With a browser crop, "zoom 1" is the crop, not the whole source.
        // `.fit` follows the crop's aspect; `.fillFollow` trims it to the canvas.
        let sa: Double
        if let crop, crop.isValid {
            sa = fillFollow ? CropSpace.baseView(crop: crop, aspect: a).aspect : crop.aspect
        } else { sa = srcAspect }
        var screen = contentRect(aspect: a, cropAspect: sa, insets: insets)
        var cam = bubbleRect(corner: corner, size: s.size, aspect: a)
        var so = 1.0, co = 0.0, cut = 0.0
        var rad = s.shape == .circle ? 0.5 : 0.22
        let ax = insets.left, ay = insets.top
        let aw = max(1 - insets.left - insets.right, 0.05), ah = max(ch - insets.top - insets.bottom, 0.05)
        func norm(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> SIMD4<Double> { SIMD4(x, y * a, w, h * a) }
        switch kind {
        case .screenOnly: break
        case .cameraOverlay: co = 1
        case .split:
            let gap = 0.02
            if a >= 1 {
                let sw = (aw - gap) * 0.64, cw = aw - gap - sw
                let w = min(sw, ah * sa), h = w / sa
                screen = norm(ax + (sw - w) / 2, ay + (ah - h) / 2, w, h)
                let side = min(cw, ah * 0.8)
                cam = norm(ax + sw + gap + (cw - side) / 2, ay + (ah - side) / 2, side, side)
            } else {
                let sh = (ah - gap) * 0.58, chh = ah - gap - sh
                let w = min(aw, sh * sa), h = w / sa
                screen = norm(ax + (aw - w) / 2, ay + (sh - h) / 2, w, h)
                let side = min(aw, chh)
                cam = norm(ax + (aw - side) / 2, ay + sh + gap + (chh - side) / 2, side, side)
            }
            co = 1; rad = s.shape == .circle ? 0.5 : 0.08
        case .cameraFullscreen:
            so = 0; cam = norm(ax, ay, aw, ah); rad = 0.03; co = 1
        case .cameraCutout:
            let h = ch * 0.62, w = min(h * ar, 0.6), left = corner == .topLeft || corner == .bottomLeft
            cam = norm(left ? 0.01 : 1 - 0.01 - w, ch - h, w, h); rad = 0; co = 1; cut = 1
        }
        var r = ResolvedLayout()
        r.screenRect = SIMD4<Float>(screen); r.screenOpacity = Float(so)
        r.cameraRect = SIMD4<Float>(cam); r.cameraRadius = Float(rad); r.cameraOpacity = Float(co); r.cutoutBlend = Float(cut)
        return r
    }
}

enum LayoutSolver {
    static let rate = 120.0, omega = 9.0

    /// Explicit layout segments mapped to OUTPUT time. Everything else uses `fallback`.
    static func spans(_ tl: Timeline, _ tm: TimeMap, hasWebcam: Bool) -> (spans: [LayoutSpan], fallback: LayoutKind) {
        guard hasWebcam else { return ([], .screenOnly) }
        var out: [LayoutSpan] = []
        for l in tl.layouts.sorted(by: { $0.start < $1.start }) {
            let a = tm.output(atSource: l.start), b = tm.output(atSource: l.end)
            if b > a { out.append(LayoutSpan(start: a, end: b, kind: l.kind)) }
        }
        return (out, .cameraOverlay)
    }

    /// `.fit` screen rect for one tick, evaluated outside the spring.
    static func fitScreenRect(crop: PxRect, aspect a: Double, srcAspect sa: Double,
                              insets: EdgeInsetsN, fillFollow: Bool) -> SIMD4<Float> {
        let fitted: Double
        if crop.isValid {
            fitted = fillFollow ? CropSpace.baseView(crop: crop, aspect: a).aspect : crop.aspect
        } else { fitted = sa }
        return SIMD4<Float>(LayoutResolver.contentRect(aspect: a, cropAspect: fitted, insets: insets))
    }

    /// One critically damped spring over all 12 layout floats: any layout to any layout, any aspect, no per-pair code.
    /// `cropAt` supplies the 480 Hz viewport crop in SOURCE time; `fillFollow`
    /// selects the `.fillFollow` trim instead of `.fit`. Both default to the
    /// legacy full-source behaviour so existing callers stay valid.
    static func solve(_ tl: Timeline, spans: [LayoutSpan], fallback: LayoutKind, src: SIMD2<Double>, webcamAspect: Double,
                      placement: PlacementTrack, outDur: Double,
                      cropAt: (@Sendable (Double) -> PxRect)? = nil, fillFollow: Bool = false) -> LayoutTrack {
        let sa = src.x / max(src.y, 1), a = tl.style.aspectRatio, ins = tl.style.insets
        let sw = src.x, sh = src.y
        func crop(_ t: Double) -> PxRect { cropAt?(t) ?? PxRect(x: 0, y: 0, w: sw, h: sh) }
        func fit(_ r: PxRect) -> SIMD4<Float> { fitScreenRect(crop: r, aspect: a, srcAspect: sa, insets: ins, fillFollow: fillFollow) }
        var track = LayoutTrack(rate: rate, samples: [], spans: spans, fallback: fallback)
        let n = max(Int(outDur * rate) + 2, 3), dt = 1 / rate
        guard tl.webcam != nil else {
            if cropAt == nil {
                let t = LayoutResolver.target(.screenOnly, tl.layoutSettings[.screenOnly], corner: .bottomRight,
                                              aspect: a, srcAspect: sa, insets: ins, webcamAspect: webcamAspect)
                track.samples = [t, t]
            } else {
                track.samples = (0..<n).map { i in
                    var s = LayoutResolver.target(.screenOnly, tl.layoutSettings[.screenOnly], corner: .bottomRight,
                                                  aspect: a, srcAspect: sa, insets: ins, webcamAspect: webcamAspect)
                    s.screenRect = fit(crop(Double(i) * dt))
                    return s
                }
            }
            return track
        }
        var x = SIMD16<Double>(repeating: 0), v = x
        var cache: (LayoutKind, WebcamLayout.Corner, ResolvedLayout)?
        var out: [ResolvedLayout] = []; out.reserveCapacity(n)
        var si = 0
        for i in 0..<n {
            let t = Double(i) * dt
            while si < spans.count && spans[si].end <= t { si += 1 }
            let kind = (si < spans.count && spans[si].start <= t) ? spans[si].kind : fallback
            let set = tl.layoutSettings[kind]
            let corner = placement.corner(at: t) ?? set.corner
            let cr = crop(t)
            if cache == nil || cache!.0 != kind || cache!.1 != corner {
                cache = (kind, corner, LayoutResolver.target(kind, set, corner: corner, aspect: a, srcAspect: sa,
                                                             insets: ins, webcamAspect: webcamAspect,
                                                             crop: cr, fillFollow: fillFollow))
            }
            var tgt = SIMD16<Double>(cache!.2.v)
            if kind == .cameraOverlay || kind == .cameraCutout { tgt[10] *= Double(placement.visibility(at: t)) }
            if i == 0 { x = tgt }
            for k in 0..<12 { springStep(&x[k], &v[k], target: tgt[k], omega: omega, dt: dt) }
            var sample = ResolvedLayout(v: SIMD16<Float>(x))
            // Fit mode is evaluated per tick OUTSIDE the spring, so the view
            // aspect always equals the frame aspect even mid-transition.
            if kind == .screenOnly || kind == .cameraOverlay { sample.screenRect = fit(cr) }
            out.append(sample)
        }
        track.samples = out
        return track
    }
}
