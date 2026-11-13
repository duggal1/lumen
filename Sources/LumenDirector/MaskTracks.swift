import Foundation
import LumenCore
import LumenProject

/// Builds auto mask tracks from OCR detections. Pure. Masks live in SOURCE space and SOURCE time.
enum MaskTracks {
    /// A same-hash detection continues a track only inside this window, and only
    /// when it is close, in the same capture context and in the same field
    /// geometry. 1.6 s and 0.4 × diagonal let one address slide across unrelated
    /// content; these numbers do not.
    static let bridge = 0.35, lead = 0.12, tail = 0.25
    static let maxJump = 0.08          // fraction of the source diagonal
    static let maxGrowth = 0.25        // height change that means a different field
    private struct Track {
        var hash: UInt64
        var cat: SensitiveCategory
        var proposed: Bool
        var ctx: PrivacyContext
        var keys: [MaskKey]
        var last: OCRDetection
    }

    static func build(_ det: [OCRDetection], plan: PrivacyPlan, src: SourceInfo,
                      contexts: PrivacyContextTrack = PrivacyContextTrack()) -> [Mask] {
        guard plan.enabled, plan.autoDetect, !det.isEmpty else { return [] }
        let W = Double(src.width), H = Double(src.height), diag = hypot(W, H)
        var tracks: [Track] = []
        let ordered = det.filter { $0.t.isFinite && $0.x.isFinite && $0.y.isFinite && $0.w > 0 && $0.h > 0 }
            .sorted { ($0.t, $0.hash, $0.x, $0.y) < ($1.t, $1.hash, $1.x, $1.y) }
        for d in ordered {
            let ctx = contexts.context(at: d.t) ?? PrivacyContext()
            let proposed = PrivacyPolicy.verdict(for: d.category, context: contexts.context(at: d.t)) == .propose
            let cx = (d.x + d.w / 2) * W, cy = (d.y + d.h / 2) * H
            var best = -1, bd = Double.infinity
            for (i, tr) in tracks.enumerated()
            where tr.hash == d.hash && tr.proposed == proposed && tr.ctx.isSameSurface(as: ctx) {
                let dt = d.t - tr.last.t
                guard dt > 0.02, dt <= bridge else { continue }
                let dist = hypot(cx - (tr.last.x + tr.last.w / 2) * W, cy - (tr.last.y + tr.last.h / 2) * H)
                guard dist <= maxJump * diag, compatible(tr.last, d) else { continue }
                if dist < bd { best = i; bd = dist }
            }
            let key = MaskKey(t: d.t, x: d.x * W, y: d.y * H, w: d.w * W, h: d.h * H)
            if best >= 0 {
                var ks = tracks[best].keys
                if ks.count >= 2, same(ks[ks.count - 1], key), same(ks[ks.count - 2], key) { ks[ks.count - 1].t = key.t } else { ks.append(key) }
                tracks[best].keys = ks; tracks[best].last = d
            } else {
                tracks.append(Track(hash: d.hash, cat: d.category, proposed: proposed, ctx: ctx, keys: [key], last: d))
            }
        }
        var out: [Mask] = []
        for tr in tracks {
            guard let f = tr.keys.first, let l = tr.keys.last else { continue }
            let s = max(f.t - lead, 0), e = src.duration > 0 ? min(l.t + tail, src.duration) : l.t + tail
            let xSeed = UInt64(max(f.x * 10_000, 0).rounded())
            let ySeed = UInt64(max(f.y * 10_000, 0).rounded())
            let id = stableUUID(tr.hash ^ xSeed, UInt64(max(f.t * 100, 0).rounded()) ^ ySeed)
            let dec = plan.decisions[id.uuidString]
            if dec == false { continue }
            let auto = !tr.proposed && plan.autoApply.contains(tr.cat.rawValue)
            out.append(Mask(id: id, start: s, end: e, mode: plan.mode, keys: tr.keys, origin: .auto,
                            approved: dec ?? auto, category: tr.cat.rawValue, padding: plan.padding))
        }
        return out.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
    }

    /// Field semantics from capture-time AX. A click into a secure field
    /// (password/CC role) masks the WHOLE field box (not the text box, so
    /// region size never reveals length) from focus to last keystroke.
    /// Covers show-password toggles where OCR alone sees plain text.
    ///
    /// `ocr` is the pixel evidence. Pass it and the mask shrinks to the exposed
    /// value: a field showing only `••••••` has no detection inside it, so it
    /// gets no mask at all, and a revealed value is masked only where it is
    /// readable. Pass nil when no scan exists — the whole field is then masked,
    /// because concealment cannot be ruled out without evidence.
    static func secureFields(events: [InputEvent], ax: [AXFrame], plan: PrivacyPlan, src: SourceInfo,
                             ocr: [OCRDetection]? = nil) -> [Mask] {
        guard plan.enabled, plan.autoDetect, !ax.isEmpty else { return [] }
        let contexts = PrivacyContextTrack.from(ax: ax)
        let focused = events.filter { ($0.kind == .down || $0.kind == .keyDown) && $0.axFrameIndex > 0 }
            .sorted { $0.t < $1.t }
        guard src.duration > 0 else { return [] }
        let detections: [OCRDetection]
        if let ocr {
            detections = revealedValues(ax: ax, ocr: ocr, src: src)
        } else {
            // No pixel evidence: concealment cannot be ruled out, so the whole
            // field is masked (the behaviour that shipped before evidence).
            var fields = ax.compactMap { field -> OCRDetection? in
                guard field.secure, let time = field.sampledAt, field.w > 1, field.h > 1 else { return nil }
                return OCRDetection(t: time, x: field.x / Double(src.width), y: field.y / Double(src.height),
                    w: field.w / Double(src.width), h: field.h / Double(src.height), category: .envSecret,
                    hash: fnv1a64("\(field.x):\(field.y):\(field.w):\(field.h)"), confidence: 1)
            }
            for event in focused {
                guard Int(event.axFrameIndex) <= ax.count else { continue }
                let field = ax[Int(event.axFrameIndex) - 1]
                guard field.secure, field.w > 1, field.h > 1 else { continue }
                let hash = fnv1a64("\(field.x):\(field.y):\(field.w):\(field.h)")
                fields.append(OCRDetection(t: event.t, x: field.x / Double(src.width), y: field.y / Double(src.height),
                    w: field.w / Double(src.width), h: field.h / Double(src.height), category: .envSecret,
                    hash: hash, confidence: 1))
            }
            detections = fields
        }
        var out = build(detections, plan: plan, src: src, contexts: contexts)
        for i in out.indices { out[i].approved = plan.decisions[out[i].id.uuidString] ?? out[i].approved }
        return out.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
    }

    /// Clip every readable detection to the secure field it lands in. Nothing is
    /// invented: a detection outside every field is dropped, and a field with no
    /// detection inside it produces no mask.
    private static func revealedValues(ax: [AXFrame], ocr: [OCRDetection], src: SourceInfo) -> [OCRDetection] {
        let W = Double(src.width), H = Double(src.height)
        let fields = ax.compactMap { field -> CGRect? in
            guard field.secure, field.w > 1, field.h > 1, W > 0, H > 0 else { return nil }
            return CGRect(x: field.x / W, y: field.y / H, width: field.w / W, height: field.h / H)
        }
        var out: [OCRDetection] = []
        var seen: Set<String> = []
        for detection in ocr where detection.w > 0 && detection.h > 0 {
            for field in fields {
                let x0 = max(detection.x, field.minX), y0 = max(detection.y, field.minY)
                let x1 = min(detection.x + detection.w, field.maxX), y1 = min(detection.y + detection.h, field.maxY)
                guard x1 > x0, y1 > y0 else { continue }
                var clipped = detection
                clipped.x = x0; clipped.y = y0; clipped.w = x1 - x0; clipped.h = y1 - y0
                let key = "\(clipped.hash):\(Int((clipped.t * 100).rounded())):\(Int((x0 * 1000).rounded())):\(Int((y0 * 1000).rounded()))"
                if seen.insert(key).inserted { out.append(clipped) }
            }
        }
        return out
    }

    /// A field that changed height or width beyond this is a different field,
    /// even when it shows the same text.
    private static func compatible(_ a: OCRDetection, _ b: OCRDetection) -> Bool {
        let h = max(a.h, b.h), w = max(a.w, b.w)
        guard h > 0, w > 0 else { return false }
        return abs(a.h - b.h) <= maxGrowth * h && abs(a.w - b.w) <= w
    }
    private static func same(_ a: MaskKey, _ b: MaskKey) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.w - b.w) < 0.5 && abs(a.h - b.h) < 0.5
    }
}