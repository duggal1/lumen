import Foundation
import LumenProject

/// Changed source-pixel regions shared by typing and sensitive-text analysis.
enum DirtyRects {
    static func covering(_ dirty: [CGRect], protected: [CGRect], extent: CGRect) -> [CGRect] {
        // Recognize complete lines: a new suffix can make unchanged text sensitive.
        var regions = dirty.map { region in
            CGRect(x: extent.minX, y: region.minY, width: extent.width, height: region.height).intersection(extent)
        }.filter { !$0.isEmpty }
        var changed = true
        while changed {
            changed = false
            for index in regions.indices {
                var region = regions[index]
                for rect in protected where region.intersects(rect) {
                    let context = max(64, rect.height * 2)
                    region = region.union(rect.insetBy(dx: -context, dy: -context)).intersection(extent)
                }
                if region != regions[index] { regions[index] = region; changed = true }
            }
        }
        var merged: [CGRect] = []
        for candidate in regions {
            var combined = candidate, index = 0
            while index < merged.count {
                if combined.intersects(merged[index]) {
                    combined = combined.union(merged.remove(at: index))
                    index = 0
                } else { index += 1 }
            }
            merged.append(combined)
        }
        return merged
    }

    static func between(_ previous: LumaTiles?, _ current: LumaTiles, threshold: Int = 6, padTiles: Int = 4,
                        previousSignatures: [UInt64]? = nil, signatures: [UInt64]? = nil) -> [CGRect] {
        guard let previous, previous.cols == current.cols, previous.rows == current.rows else {
            return [CGRect(x: 0, y: 0, width: current.cols * current.tile, height: current.rows * current.tile)]
        }
        let cols = current.cols, rows = current.rows
        let hot = current.mean.indices.map { index in
            if abs(Int(previous.mean[index]) - Int(current.mean[index])) >= threshold { return true }
            guard let previousSignatures, let signatures,
                  previousSignatures.count == current.mean.count, signatures.count == current.mean.count else { return false }
            return previousSignatures[index] != signatures[index]
        }
        var grown = hot
        for row in 0..<rows { for column in 0..<cols where hot[row * cols + column] {
            for r in max(row - padTiles, 0)...min(row + padTiles, rows - 1) {
                for c in max(column - padTiles, 0)...min(column + padTiles, cols - 1) { grown[r * cols + c] = true }
            }
        } }
        var seen = [Bool](repeating: false, count: grown.count), regions: [CGRect] = []
        for start in grown.indices where grown[start] && !seen[start] {
            var pending = [start], cursor = 0
            var x0 = start % cols, x1 = x0, y0 = start / cols, y1 = y0
            seen[start] = true
            while cursor < pending.count {
                let index = pending[cursor]; cursor += 1
                let x = index % cols, y = index / cols
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, xx < cols, yy >= 0, yy < rows else { continue }
                    let next = yy * cols + xx
                    guard grown[next], !seen[next] else { continue }
                    seen[next] = true; pending.append(next)
                }
            }
            regions.append(CGRect(x: x0 * current.tile, y: y0 * current.tile,
                width: (x1 - x0 + 1) * current.tile, height: (y1 - y0 + 1) * current.tile))
        }
        return regions
    }
}
