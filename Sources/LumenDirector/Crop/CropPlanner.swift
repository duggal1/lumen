import Foundation
import os
import LumenCore
import LumenProject

/// Key/click times in SOURCE seconds, ascending. Pure input bundle.
/// Ownership: none (built per Director pass). Threading: value, `Sendable`.
public struct CropInputs: Sendable {
    public var keys: [Double]
    public var uiClicks: [Double]

    public init(keys: [Double], uiClicks: [Double]) { self.keys = keys; self.uiClicks = uiClicks }

    /// A UI click is a mouse-down inside the browser window but outside its web
    /// area — i.e. on a tab or the address bar, not in page content.
    public static func make(events: [InputEvent], samples: [ViewportSample]) -> CropInputs {
        var keys: [Double] = [], clicks: [Double] = []
        var si = 0
        for e in events {
            switch e.kind {
            case .keyDown where e.isTypingKey:
                keys.append(e.t)
            case .down:
                while si + 1 < samples.count && samples[si + 1].t <= e.t { si += 1 }
                guard samples.indices.contains(si) else { continue }
                let s = samples[si]
                if s.front, s.webValid,
                   s.window.contains(Double(e.x), Double(e.y)),
                   !s.web.contains(Double(e.x), Double(e.y)) {
                    clicks.append(e.t)
                }
            default:
                break
            }
        }
        return CropInputs(keys: keys, uiClicks: clicks)
    }
}

/// One projected browser observation. Pure value.
/// Ownership: none. Threading: value, `Sendable`.
public struct ViewportSample: Sendable, Equatable {
    public var t: Double
    public var front: Bool
    public var ui: Bool
    public var webValid: Bool
    public var window: PxRect
    public var web: PxRect

    public init(_ r: ViewportRecord) {
        t = r.t
        front = r.flags.contains(.browserFront)
        ui = r.flags.contains(.uiFocus)
        webValid = r.flags.contains(.webValid)
        window = r.window
        web = r.web
    }
}

/// One crop state transition. Times/durations are SOURCE seconds.
/// Ownership: derived. Threading: value, `Sendable`.
public struct ViewportCropStateChange: Sendable, Equatable {
    public var start: Double
    public var duration: Double
    public var mode: CropMode

    public init(start: Double, duration: Double, mode: CropMode) {
        self.start = start; self.duration = duration; self.mode = mode
    }
}

/// Dense 480 Hz crop rect in source pixels. Immutable; shared with Render and
/// the camera seam. Named `ViewportCropTrack` to avoid colliding with the
/// existing keyframed `LumenProject.CropTrack`.
/// Ownership: derived. Threading: immutable `Sendable`, read on any queue.
public struct ViewportCropTrack: Sendable {
    public let hz: Double
    /// x, y, w, h per tick (source pixels).
    public let rects: [SIMD4<Float>]

    public init(hz: Double, rects: [SIMD4<Float>]) { self.hz = hz; self.rects = rects }

    public func rect(at t: Double) -> PxRect {
        guard !rects.isEmpty else { return PxRect(x: 0, y: 0, w: 0, h: 0) }
        let f = min(max(t * hz, 0), Double(rects.count - 1))
        let i = Int(f), j = min(i + 1, rects.count - 1)
        let v = rects[i] + (rects[j] - rects[i]) * Float(f - Double(i))
        return PxRect(x: Double(v.x), y: Double(v.y), w: Double(v.z), h: Double(v.w))
    }
}

/// Changes plus the baked track. Ownership: derived. Threading: value, `Sendable`.
public struct ViewportCropPlan: Sendable {
    public var changes: [ViewportCropStateChange]
    public var track: ViewportCropTrack

    public init(changes: [ViewportCropStateChange], track: ViewportCropTrack) {
        self.changes = changes; self.track = track
    }
}

/// Pure, deterministic crop planner. No wall clock, no randomness, no I/O.
/// Ownership: none. Threading: any queue; each `plan` call is independent.
public enum CropPlanner {
    public static let hz = 480.0
    static let srate = 20.0
    private static let signpost = OSLog(subsystem: "com.lumen.studio", category: "crop")

    struct Run { var start: Double; var end: Double; var mode: CropMode }

    struct Smoothed {
        var data: [SIMD4<Double>]                    // .x=x .y=y .z=width .w=height

        func at(_ t: Double) -> PxRect {
            guard !data.isEmpty else { return PxRect(x: 0, y: 0, w: 0, h: 0) }
            let f = min(max(t * CropPlanner.srate, 0), Double(data.count - 1))
            let i = Int(f), j = min(i + 1, data.count - 1)
            let v = data[i] + (data[j] - data[i]) * (f - Double(i))
            return PxRect(x: v.x, y: v.y, w: v.z, h: v.w)
        }
    }

    public static func plan(samples: [ViewportSample], inputs: CropInputs, duration: Double,
                            source: PxRect, settings s: CropSettings) -> ViewportCropPlan {
        os_signpost(.begin, log: signpost, name: "crop.plan")
        defer { os_signpost(.end, log: signpost, name: "crop.plan") }
        guard s.enabled, samples.count >= 2, duration.isFinite, duration > 0.5 else {
            let full = SIMD4<Float>(Float(source.x), Float(source.y), Float(source.w), Float(source.h))
            return ViewportCropPlan(
                changes: [.init(start: 0, duration: 0, mode: .full)],
                track: ViewportCropTrack(hz: hz, rects: [full]))
        }
        let n = Int((duration * hz).rounded(.up)) + 1
        let web = series(samples, duration, source, sigma: s.trackSigma) { $0.webValid ? $0.web : nil }
        let win = series(samples, duration, source, sigma: s.trackSigma) { $0.window.isValid ? $0.window : nil }
        var runs = baseRuns(samples, s, duration)
        mergeShortRuns(&runs, s.minDwell)
        let spans = uncropSpans(samples, inputs, s, duration)
        let changes = changeList(runs, spans, s, duration)

        func rect(_ m: CropMode, _ t: Double) -> PxRect {
            switch m {
            case .full: return source
            case .content:
                // TRUE CROP of the AXWebArea source rect: inset the chrome
                // divider, then grow to the OUTPUT aspect so the compositor
                // never stretches the picture. No camera zoom factor is used.
                let detected = web.at(t).insetBy(s.insetPx)
                return SmartCropPlanner.aspectFit(detected, source: source)
                    .intersection(source)
            case .window: return win.at(t).intersection(source)
            }
        }
        var rects: [SIMD4<Float>] = []
        rects.reserveCapacity(n)
        var k = 0
        for i in 0..<n {
            let t = Double(i) / hz
            while k + 1 < changes.count && t >= changes[k + 1].start { k += 1 }
            var r = rect(changes[k].mode, t)
            if k > 0, changes[k].duration > 0 {
                let u = (t - changes[k].start) / changes[k].duration
                if u < 1 { r = PxRect.blend(rect(changes[k - 1].mode, t), r, quintic(u)) }
            }
            rects.append(SIMD4(Float(r.x), Float(r.y), Float(r.w), Float(r.h)))
        }
        return ViewportCropPlan(changes: changes, track: ViewportCropTrack(hz: hz, rects: rects))
    }

    @inline(__always) static func quintic(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * t * (t * (6 * t - 15) + 10)
    }

    /// Tracked rect at 20 Hz: Gaussian-smoothed, nearest-held across long gaps.
    static func series(_ samples: [ViewportSample], _ duration: Double, _ source: PxRect, sigma: Double,
                       pick: (ViewportSample) -> PxRect?) -> Smoothed {
        let pts = samples.compactMap { sm in
            pick(sm).map { (t: sm.t, v: SIMD4<Double>($0.x, $0.y, $0.w, $0.h)) }
        }
        let m = Int((duration * srate).rounded(.up)) + 2
        var raw = [SIMD4<Double>](repeating: SIMD4(source.x, source.y, source.w, source.h), count: m)
        if !pts.isEmpty {
            var j = 0
            for k in 0..<m {
                let t = Double(k) / srate
                while j + 1 < pts.count && pts[j + 1].t <= t { j += 1 }
                let a = pts[j], b = pts[min(j + 1, pts.count - 1)]
                var u = b.t > a.t ? min(max((t - a.t) / (b.t - a.t), 0), 1) : 0
                if b.t - a.t > 1.0 { u = (t - a.t) < (b.t - t) ? 0 : 1 }
                raw[k] = a.v + (b.v - a.v) * u
            }
        }
        let sd = max(sigma * srate, 0.01), r = Int((3 * sd).rounded(.up))
        guard sigma > 0, r >= 1 else { return Smoothed(data: raw) }
        var kern = (-r...r).map { exp(-Double($0 * $0) / (2 * sd * sd)) }
        let ks = kern.reduce(0, +)
        kern = kern.map { $0 / ks }
        var out = raw
        for k in 0..<m {
            var acc = SIMD4<Double>(repeating: 0), ws = 0.0
            for d in -r...r {
                let i = k + d
                if i < 0 || i >= m { continue }
                acc += raw[i] * kern[d + r]
                ws += kern[d + r]
            }
            out[k] = acc / ws
        }
        return Smoothed(data: out)
    }

    static func baseRuns(_ samples: [ViewportSample], _ s: CropSettings, _ duration: Double) -> [Run] {
        func mode(_ m: ViewportSample) -> CropMode {
            (m.front && m.webValid && m.web.w >= s.minWebWidthPx && m.web.h >= s.minWebHeightPx)
                ? .content : .full
        }
        var runs: [Run] = []
        for (i, sm) in samples.enumerated() {
            let m = mode(sm)
            if runs.last?.mode == m { continue }
            let a = i == 0 ? 0 : (samples[i - 1].t + sm.t) / 2
            if !runs.isEmpty { runs[runs.count - 1].end = a }
            runs.append(Run(start: a, end: duration, mode: m))
        }
        return runs
    }

    static func mergeShortRuns(_ runs: inout [Run], _ minDwell: Double) {
        var i = 1
        while i < runs.count - 1 {
            if runs[i].end - runs[i].start < minDwell {
                runs[i - 1].end = runs[i].end
                runs.remove(at: i)
                if i < runs.count, runs[i].mode == runs[i - 1].mode {
                    runs[i - 1].end = runs[i].end
                    runs.remove(at: i)
                }
                i = max(1, i - 1)
            } else { i += 1 }
        }
    }

    /// Intervals where the whole window is revealed while the user works in
    /// browser chrome. Two policies: chrome typing only, or any typing.
    static func uncropSpans(_ samples: [ViewportSample], _ inp: CropInputs, _ s: CropSettings,
                            _ duration: Double) -> [(Double, Double)] {
        guard s.uncrop != .never else { return [] }
        var raw: [(Double, Double)] = []
        func keys(_ a: Double, _ b: Double) -> [Double] { inp.keys.filter { $0 >= a && $0 <= b } }
        if s.uncrop == .chromeTyping {
            var start: Double?
            var last = 0.0
            func close() {
                guard let st = start else { return }
                let k = keys(st - 0.2, last + 0.5)
                if let f = k.first, let l = k.last {
                    raw.append((min(st, f) - s.uncropLead, max(last, l) + s.holdAfterTyping))
                }
                start = nil
            }
            for sm in samples {
                if sm.front && sm.ui {
                    if start == nil { start = sm.t }
                    last = sm.t
                } else if start != nil, sm.t - last > 0.3 { close() }
            }
            close()
        } else {
            var group: [Double] = []
            func flush() {
                if group.count >= 4, let f = group.first, let l = group.last {
                    raw.append((f - s.uncropLead, l + s.holdAfterTyping))
                }
                group = []
            }
            for k in inp.keys {
                if let g = group.last, k - g > 1.2 { flush() }
                group.append(k)
            }
            flush()
        }
        for c in inp.uiClicks { raw.append((c - s.uncropLead, c + s.holdAfterUIClick)) }
        raw.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        let gap = s.uncropDuration + s.recropDuration + 0.4
        for r in raw {
            if let l = merged.last, r.0 - l.1 < gap { merged[merged.count - 1].1 = max(l.1, r.1) }
            else { merged.append(r) }
        }
        return merged.map { (max(0, $0.0), min(duration, $0.1)) }
    }

    /// Non-overlapping rest-to-rest transitions: every blend starts after the
    /// previous one has fully settled, so the crop never jitters mid-flight.
    static func changeList(_ runs: [Run], _ spans: [(Double, Double)], _ s: CropSettings,
                           _ duration: Double) -> [ViewportCropStateChange] {
        func modeAt(_ t: Double) -> CropMode {
            if let o = s.overrides.last(where: { t >= $0.start && t < $0.end }) { return o.mode }
            let base = runs.last(where: { $0.start <= t })?.mode ?? .full
            if base == .content, spans.contains(where: { t >= $0.0 && t < $0.1 }) { return .window }
            return base
        }
        var marks = Set<Double>()
        for r in runs { marks.insert(r.start) }
        for sp in spans { marks.insert(sp.0); marks.insert(sp.1) }
        for o in s.overrides { marks.insert(o.start); marks.insert(o.end) }
        var out = [ViewportCropStateChange(start: 0, duration: 0, mode: modeAt(0))]
        for b in marks.sorted() where b > 0 && b < duration {
            let m = modeAt(b + 1e-4)
            let prev = out[out.count - 1]
            guard m != prev.mode else { continue }
            let (start, dur): (Double, Double)
            switch (prev.mode, m) {
            case (_, .window):        (start, dur) = (b, s.uncropDuration)
            case (.window, .content): (start, dur) = (b, s.recropDuration)
            default:                  (start, dur) = (b - 0.05, s.appSwitchDuration)
            }
            out.append(ViewportCropStateChange(
                start: max(max(0, start), prev.start + prev.duration + 0.10),
                duration: dur, mode: m))
        }
        return out
    }
}

// MARK: - Source-pixel geometry for the true crop

public extension SmartCropPlanner {
    /// PxRect twin of the CGRect aspect fit. Grows a detected content rect to
    /// the source aspect about its centre, then clamps inside the source. This
    /// is the final step of the AUTO-CROP path: the resulting rect is a crop
    /// of the source pixels, fitted to the output frame by the compositor.
    static func aspectFit(_ rect: PxRect, source: PxRect) -> PxRect {
        guard rect.w > 1, rect.h > 1, source.w > 1, source.h > 1 else { return rect }
        let target = source.w / source.h
        // A rect already within 0.5% of the output aspect is passed through
        // unchanged (only its origin is clamped). Growing such a rect by a
        // fraction of a pixel is what makes a stable AXWebArea crop breathe by
        // a pixel between frames.
        if abs(rect.aspect - target) <= 0.005 * target,
           rect.w <= source.w, rect.h <= source.h {
            return PxRect(x: min(max(rect.x, source.x), source.maxX - rect.w),
                          y: min(max(rect.y, source.y), source.maxY - rect.h),
                          w: rect.w, h: rect.h)
        }
        var w = rect.w, h = rect.h
        if w / h < target { w = h * target } else { h = w / target }
        if w > source.w { w = source.w; h = w / target }
        if h > source.h { h = source.h; w = h * target }
        let x = min(max(rect.cx - w / 2, source.x), source.maxX - w)
        let y = min(max(rect.cy - h / 2, source.y), source.maxY - h)
        return PxRect(x: x, y: y, w: w, h: h)
    }
}

public extension CropPlanner {
    /// Vision fallback: maps `ChromeDetector`'s window-relative edge result
    /// into a source-pixel crop rect, already aspect-fitted and clamped. The
    /// capture path uses this when no AXWebArea is available; the result has
    /// exactly the same shape as the AX-derived `.content` rect, so the rest
    /// of the planner (smoothing, debounce, transitions) is unchanged.
    static func contentRect(fromEdges edges: [Float], gridW: Int, gridH: Int,
                            window: PxRect, source: PxRect,
                            settings: ChromeDetector.Settings = ChromeDetector.Settings(),
                            insetPx: Double = 2) -> PxRect? {
        guard let detected = ChromeDetector.contentRect(edges: edges, gridW: gridW, gridH: gridH,
                                                        window: window, s: settings) else { return nil }
        return SmartCropPlanner.aspectFit(detected.insetBy(insetPx), source: source)
            .intersection(source)
    }
}

