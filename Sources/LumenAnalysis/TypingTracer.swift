import Foundation
import LumenProject

/// Pixel-measured typing anchor (no AX dependency). Pure and unit-testable;
/// the AVAssetReader pipeline that builds the luma grids lives in the
/// analysis service and feeds this tracer.
public enum TypingTracer {
    struct Box { var c0: Int, c1: Int, r0: Int, r1: Int, area: Int }

    public static func trace(burst: (t0: Double, t1: Double), ts: [Double], grids: [LumaTiles],
                             anchor: SIMD2<Double>?, srcH: Double) -> TypingTrace? {
        guard ts.count == grids.count, ts.count >= 2, let base = grids.first else { return nil }
        let cols = base.cols, rows = base.rows, tile = Double(base.tile)
        let maxLineRows = max(Int(0.08 * srcH / tile), 2)
        func changed(_ g: LumaTiles) -> [Bool] { (0..<(cols * rows)).map { abs(Int(g.mean[$0]) - Int(base.mean[$0])) >= 8 } }
        func dilate(_ m: [Bool]) -> [Bool] {
            var o = m
            for r in 0..<rows { for c in 0..<cols where m[r * cols + c] { for dc in -2...2 where c + dc >= 0 && c + dc < cols { o[r * cols + c + dc] = true } } }
            return o
        }
        func components(_ m: [Bool]) -> [Box] {
            var seen = [Bool](repeating: false, count: m.count), out: [Box] = []
            for s in m.indices where m[s] && !seen[s] {
                var bx = Box(c0: s % cols, c1: s % cols, r0: s / cols, r1: s / cols, area: 0)
                var stack = [s]; seen[s] = true
                while let i = stack.popLast() {
                    let c = i % cols, r = i / cols
                    bx.c0 = min(bx.c0, c); bx.c1 = max(bx.c1, c); bx.r0 = min(bx.r0, r); bx.r1 = max(bx.r1, r); bx.area += 1
                    for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nc = c + dc, nr = r + dr
                        guard nc >= 0, nc < cols, nr >= 0, nr < rows, m[nr * cols + nc], !seen[nr * cols + nc] else { continue }
                        seen[nr * cols + nc] = true; stack.append(nr * cols + nc)
                    }
                }
                out.append(bx)
            }
            return out
        }
        // First frame with a single-line-high blob = where the first typed characters appeared.
        var band: (r0: Int, r1: Int, left: Int)?, k0 = 1, lineRows = 1
        for k in 1..<ts.count {
            let blobs = components(dilate(changed(grids[k]))).filter { $0.r1 - $0.r0 + 1 <= maxLineRows && $0.area >= 2 }
            guard !blobs.isEmpty else { continue }
            func cy(_ b: Box) -> Double { Double(b.r0 + b.r1 + 1) / 2 * tile }
            var pick = blobs.min { $0.r0 < $1.r0 }!
            if let a = anchor, let n = blobs.filter({ abs(cy($0) - a.y) < 0.25 * srcH }).min(by: { abs(cy($0) - a.y) < abs(cy($1) - a.y) }) { pick = n }
            band = (max(pick.r0 - 1, 0), min(pick.r1 + 1, rows - 1), max(pick.c0 + 2 - 1, 0)); k0 = k
            lineRows = pick.r1 - pick.r0 + 1   // the text line itself; the band's ±1 rows are tracking slack
            break
        }
        guard let band else { return nil }
        var samples: [TypingTrace.Sample] = [], right = band.left
        for k in k0..<ts.count {
            let m = changed(grids[k]); var found = -1
            for r in band.r0...band.r1 { for c in stride(from: cols - 1, through: band.left, by: -1) where m[r * cols + c] { found = max(found, c); break } }
            if found >= 0 { right = found }
            samples.append(.init(t: ts[k], x: Double(right + 1) * tile, y: Double(band.r0 + band.r1 + 1) / 2 * tile))
        }
        guard let last = samples.last else { return nil }
        let left = Double(band.left) * tile
        return TypingTrace(t0: burst.t0, t1: burst.t1,
                           rect: CGRect(x: left, y: Double(band.r0) * tile, width: max(last.x - left, tile), height: Double(lineRows) * tile),
                           samples: samples)
    }
}
