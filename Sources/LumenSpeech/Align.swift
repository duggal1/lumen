import Foundation
import LumenProject

/// Gives each word of a finished line a start/end. Pure and deterministic. The line's own span comes from the runtime;
/// inside it, words are placed by length and every inner boundary snaps to a real energy dip within +/-150 ms.
enum WordAligner {
    static func split(_ text: String) -> [String] { text.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    static func align(words: [String], start: Double, end: Double, env: EnergyTrack) -> [WordToken] {
        let n = words.count
        guard n > 0, end > start else { return [] }
        var s = start, e = end
        let seg = env.slice(s, e)
        if seg.count >= 12 {                                   // trim leading/trailing silence the runtime included in the span
            let sorted = seg.sorted(), thr = sorted[sorted.count / 5] + 6
            if let f = seg.firstIndex(where: { $0 > thr }), let l = seg.lastIndex(where: { $0 > thr }) {
                let ns = max(s, Double(f) / 100 - 0.03), ne = min(e, Double(l + 1) / 100 + 0.06)
                if ne - ns >= 0.5 * (e - s) { s = ns; e = ne }
            }
        }
        let w = words.map { word -> Double in
            var c = Double(max(word.count, 1))
            if let ch = word.last, ",;:.?!…".contains(ch) { c += 1.5 }
            return c
        }
        let total = w.reduce(0, +)
        var b = [Double](repeating: s, count: n + 1)
        var acc = 0.0
        for i in 0..<n { acc += w[i]; b[i + 1] = s + (e - s) * acc / total }
        b[n] = e
        let db = env.db
        if db.count > 20 {
            for i in 1..<n {
                let span = min(b[i] - b[i - 1], b[i + 1] - b[i]), r = min(0.15, 0.4 * span)
                let lo = Int((b[i] - r) * 100), hi = Int((b[i] + r) * 100)
                guard lo >= 1, hi < db.count - 1, hi > lo else { continue }
                var best = lo, bv = Float.greatestFiniteMagnitude, mean: Float = 0
                for k in lo...hi {
                    let v = (db[k - 1] + db[k] + db[k + 1]) / 3
                    mean += v
                    if v < bv { bv = v; best = k }
                }
                mean /= Float(hi - lo + 1)
                if bv < mean - 4 { b[i] = (Double(best) + 0.5) / 100 }       // only a real dip moves a boundary
            }
        }
        let minD = min(0.06, (e - s) / Double(2 * n))
        for i in 1..<n { b[i] = max(b[i], b[i - 1] + minD) }
        for i in stride(from: n - 1, through: 1, by: -1) { b[i] = min(b[i], b[i + 1] - minD) }
        return (0..<n).map { WordToken(text: words[$0], start: b[$0], end: b[$0 + 1], confidence: 1) }
    }
}
