import Foundation
import LumenCore
import LumenProject

/// Builds auto mask tracks from OCR detections. Pure. Masks live in SOURCE space and SOURCE time.
enum MaskTracks {
    static let bridge = 1.6, lead = 0.6, tail = 0.6
    private struct Track { var hash: UInt64; var cat: SensitiveCategory; var keys: [MaskKey]; var last: OCRDetection }

    static func build(_ det: [OCRDetection], plan: PrivacyPlan, src: SourceInfo) -> [Mask] {
        guard plan.enabled, plan.autoDetect, !det.isEmpty else { return [] }
        let W = Double(src.width), H = Double(src.height), diag = hypot(W, H)
        var tracks: [Track] = []
        let ordered = det.filter { $0.t.isFinite && $0.x.isFinite && $0.y.isFinite && $0.w > 0 && $0.h > 0 }
            .sorted { ($0.t, $0.hash, $0.x, $0.y) < ($1.t, $1.hash, $1.x, $1.y) }
        for d in ordered {
            let cx = (d.x + d.w / 2) * W, cy = (d.y + d.h / 2) * H
            var best = -1, bd = Double.infinity
            for (i, tr) in tracks.enumerated() where tr.hash == d.hash && d.t - tr.last.t > 0.02 && d.t - tr.last.t <= bridge {
                let dist = hypot(cx - (tr.last.x + tr.last.w / 2) * W, cy - (tr.last.y + tr.last.h / 2) * H)
                if dist <= 0.4 * diag, dist < bd { best = i; bd = dist }
            }
            let key = MaskKey(t: d.t, x: d.x * W, y: d.y * H, w: d.w * W, h: d.h * H)
            if best >= 0 {
                var ks = tracks[best].keys
                if ks.count >= 2, same(ks[ks.count - 1], key), same(ks[ks.count - 2], key) { ks[ks.count - 1].t = key.t } else { ks.append(key) }
                tracks[best].keys = ks; tracks[best].last = d
            } else { tracks.append(Track(hash: d.hash, cat: d.category, keys: [key], last: d)) }
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
            out.append(Mask(id: id, start: s, end: e, mode: plan.mode, keys: tr.keys, origin: .auto,
                            approved: dec ?? plan.autoApply.contains(tr.cat.rawValue), category: tr.cat.rawValue, padding: plan.padding))
        }
        return out.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
    }
    private static func same(_ a: MaskKey, _ b: MaskKey) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.w - b.w) < 0.5 && abs(a.h - b.h) < 0.5
    }
}
