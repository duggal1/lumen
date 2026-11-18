import Foundation
import CoreGraphics
import LumenCore
import LumenProject

/// A recorded interaction that should reveal browser chrome. Times are source
/// seconds; `rect` is a resolved element rect in source pixels.
public struct SmartCropIntent: Sendable, Equatable {
    public var t: Double
    public var tEnd: Double
    public var rect: CGRect
    /// Auto-detected browser page-content rect in source pixels. This is a
    /// sentinel that carries the default crop to `plan()` without changing
    /// Director's call signature; it is never a reveal span itself.
    public var baseROI: CGRect? = nil
    public init(t: Double, tEnd: Double, rect: CGRect, baseROI: CGRect? = nil) {
        self.t = t; self.tEnd = tEnd; self.rect = rect; self.baseROI = baseROI
    }
}

/// Detects the browser chrome that must be excluded by default.
///
/// Evidence is the AX vocabulary capture already records: a browser window's
/// `window|…` label / `appName`, and the address-bar and tab element labels.
/// Only the page content is returned; tabs, the address bar and the autocomplete
/// panel above the page are chrome. No guess is made without browser evidence,
/// and a detection that would eat into the page is rejected outright.
public enum BrowserChrome {
    static let windowPrefix = "window|"
    static let browserNames = ["chrome", "chromium", "safari", "firefox", "edge",
                               "arc", "brave", "opera", "vivaldi", "webbrowser"]
    static let addressLabels = ["address and search bar", "address and search field",
                                "search or enter address", "search or enter website name",
                                "search google or type a url", "address bar", "address",
                                "location bar", "location", "omnibox", "url bar"]
    static let tabLabels = ["browser tab", "tab strip", "tabstrip", "tab bar",
                            "new tab", "tabs", "tab"]

    static func label(_ s: String?) -> String {
        (s ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isBrowserName(_ s: String?) -> Bool {
        let l = label(s)
        guard !l.isEmpty else { return false }
        // Whole tokens only. A substring test made "arc" match the "arc" inside
        // "search", so every address/search field labelled a browser and its
        // chrome got cropped in an unrelated app. `window|…|Google Chrome`
        // tokenizes to …/google/chrome, which still matches "chrome".
        let tokens = l.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return tokens.contains { browserNames.contains($0) }
    }

    static func isAddressBar(_ f: AXFrame) -> Bool {
        let l = label(f.label)
        return !l.isEmpty && addressLabels.contains { l.contains($0) }
    }

    static func isTab(_ f: AXFrame) -> Bool {
        let l = label(f.label)
        return !l.isEmpty && tabLabels.contains { l.contains($0) }
    }

    /// Page-content rect in source pixels, or nil when there is no browser to
    /// crop or the geometry cannot be trusted. Full-display capture uses the
    /// source bounds as the host when no window frame was resolved.
    public static func detect(ax: [AXFrame], source: SourceInfo) -> CGRect? {
        let W = Double(source.width), H = Double(source.height)
        guard W > 1, H > 1 else { return nil }
        let valid: [AXFrame] = ax.filter { f in
            f.x.isFinite && f.y.isFinite && f.w.isFinite && f.h.isFinite
        }
        let browser = valid.filter { f in
            isBrowserName(f.label) || isBrowserName(f.anchor?.appName)
        }
        guard !browser.isEmpty else { return nil }
        let chrome = valid.filter { isAddressBar($0) || isTab($0) }
        guard !chrome.isEmpty else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        var host = bounds
        var best = 0.0
        for f in browser {
            let r = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
            guard r.width >= 0.40 * W, r.height >= 0.40 * H else { continue }
            let area = r.width * r.height
            if area > best { best = area; host = r.intersection(bounds) }
        }
        guard host.width > 1, host.height > 1 else { return nil }

        // Tab strip and address bar only. An autocomplete popup is transient
        // chrome that extends over the page; including it here would crop real
        // page content even after the popup closes.
        var chromeBottom = host.minY
        var found = false
        let topLimit = host.minY + 0.35 * host.height
        for f in chrome {
            if let a = f.anchor, !a.resolved { continue }
            let r = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
            guard r.width >= 0.05 * W, r.height >= 5,
                  r.minY >= host.minY - 4, r.minY <= topLimit else { continue }
            chromeBottom = max(chromeBottom, r.maxY)
            found = true
        }
        guard found, chromeBottom > host.minY + 0.02 * host.height,
              chromeBottom <= topLimit else { return nil }

        let content = CGRect(x: host.minX, y: chromeBottom,
                             width: host.width, height: host.maxY - chromeBottom)
            .intersection(bounds)
        // Never crop the page: require the vast majority of the frame to remain.
        guard content.width >= 0.40 * W, content.height >= 0.45 * H else { return nil }
        // Keep the source aspect by shrinking the wider axis inside the page,
        // never by growing back into the chrome we just removed.
        let fitted = SmartCropPlanner.fitInside(content, source: bounds)
        return CGRect(x: fitted.minX.rounded(.down), y: fitted.minY.rounded(.down),
                      width: fitted.width.rounded(.up), height: fitted.height.rounded(.up))
    }
}

/// Turns recorded input into a time-varying crop. Pure and deterministic.
///
/// The default crop is the browser's page content. A resolved click or typing
/// field that does not intersect it is chrome interaction and earns a reveal;
/// the reveal holds for the interaction and then restores the page crop.
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

        // The browser's page rect travels with the intents so `plan()` stays a
        // pure function of its existing arguments, including for full display.
        if let auto = BrowserChrome.detect(ax: ax, source: source) {
            out.append(SmartCropIntent(t: -1, tEnd: -1, rect: .zero, baseROI: auto))
        }

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
        // Uses the same single field as the zoom planner, so the uncrop and the
        // zoom shot start on the same keystroke and end on the same one.
        for shot in TypingFocus.shots(events: sorted, ax: ax, traces: typing,
                                      W: W, H: H, b: b,
                                      trimStart: tm.trimStart, trimEnd: tm.trimEnd) {
            guard shot.field.width > 0, shot.field.height > 0 else { continue }
            out.append(SmartCropIntent(t: shot.t0, tEnd: shot.t1, rect: shot.field))
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

    /// The inverse fit: keep the source aspect while staying INSIDE `rect`.
    /// Used for the browser page crop — growing to the source aspect would put
    /// the tab strip and address bar back in the frame.
    public static func fitInside(_ rect: CGRect, source: CGRect) -> CGRect {
        guard rect.width > 1, rect.height > 1, source.width > 1, source.height > 1 else { return rect }
        let target = source.width / source.height
        var w = rect.width, h = rect.height
        if w / h > target { w = h * target } else { h = w / target }
        if w > source.width { w = source.width; h = w / target }
        if h > source.height { h = source.height; w = h * target }
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: - Plan

    public static func plan(config: SmartCropConfig, source: SourceInfo, tm: TimeMap,
                             intents: [SmartCropIntent]) -> CropTrack {
        let W = Double(source.width), H = Double(source.height)
        let b = max(source.backingScale, 1)
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        let auto = intents.first { $0.baseROI != nil }?.baseROI
        guard auto != nil || config.isActive else { return CropTrack() }

        var chosen: CGRect?
        if let auto {
            let a = fitInside(auto.intersection(bounds), source: bounds)
            if let raw = config.roi {
                let c = CGRect(x: raw.minX * W, y: raw.minY * H,
                               width: raw.width * W, height: raw.height * H)
                    .intersection(bounds)
                let fitted = aspectFit(c, source: bounds)
                let inter = fitted.intersection(a)
                chosen = inter.isNull ? a : aspectFit(inter, source: bounds)
            } else {
                chosen = a
            }
        } else if let raw = config.roi {
            chosen = CGRect(x: raw.minX * W, y: raw.minY * H,
                            width: raw.width * W, height: raw.height * H)
                .intersection(bounds)
        }
        guard let rawROI = chosen else { return CropTrack() }
        let roi = aspectFit(rawROI, source: bounds)
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
            // A chrome element that merely touches the page edge (the address
            // bar ends exactly where the page begins) is still chrome. Only a
            // real, positive-area overlap means the subject is already framed.
            let overlap = i.rect.intersection(roi)
            guard overlap.isNull || overlap.width <= 0.5 || overlap.height <= 0.5 else { continue }
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
