import Foundation
import CoreVideo
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

    /// Source-pixel rectangles whose luma tiles changed between two frames.
    ///
    /// The whole frame is returned when there is no baseline (first frame) or
    /// when the two grids have a different shape. Otherwise every tile whose
    /// mean moved by at least `threshold` is marked, the marked set is grown by
    /// `padTiles` in each direction, the marked tiles are merged into connected
    /// components and each component is returned as a pixel rectangle. Nothing
    /// changed means an empty result, which is the common case on a static screen.
    static func between(_ previous: LumaTiles?, _ current: LumaTiles, threshold: Int = 6, padTiles: Int = 4) -> [CGRect] {
        between(previous, current, threshold: threshold, padTiles: padTiles,
                previousSignatures: nil, signatures: nil)
    }

    /// Same as `between(_:_:threshold:padTiles:)`, but a tile also counts as
    /// changed when its exact pixel signature moved even though the mean luma
    /// barely did — a single new character in a mostly uniform region.
    static func between(_ previous: LumaTiles?, _ current: LumaTiles, threshold: Int = 6, padTiles: Int = 4,
                        previousSignatures: [UInt64]?, signatures: [UInt64]?) -> [CGRect] {
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

/// 16 source-px tiles, stride-2 sampling, one pass over the buffer.
/// Shared by the typing tracer and the sensitive-text scan so both measure
/// change against the very same grid.
///
/// The tiles-only path skips the per-pixel signature the OCR scan needs: a
/// typed glyph is measured for the typing tracer alone, and the signature is
/// the single most expensive part of the pass.
func lumaTiles(_ buffer: CVPixelBuffer) throws -> LumaTiles {
    let started = DispatchTime.now().uptimeNanoseconds
    defer { AnalysisMetrics.shared.add(luma: Int(DispatchTime.now().uptimeNanoseconds - started)) }
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AnalysisError.pixelBuffer }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw AnalysisError.pixelBuffer }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let tile = 16
    let cols = max(1, (width + tile - 1) / tile), rows = max(1, (height - 1) / tile + 1)
    var sum = [UInt32](repeating: 0, count: cols * rows)
    var count = [UInt32](repeating: 0, count: cols * rows)
    for y in stride(from: 0, to: height, by: 2) {
        let row = base + y * rowBytes
        let base_index = (y / tile) * cols
        var x = 0, column = 0
        while x < width {
            let end = min(x + tile, width)
            var s = 0, c = 0
            var xx = x
            while xx < end {
                let i = xx * 4
                s += (29 * Int(row[i]) + 150 * Int(row[i + 1]) + 77 * Int(row[i + 2])) >> 8
                c += 1
                xx += 2
            }
            let index = base_index + column
            sum[index] += UInt32(s)
            count[index] += UInt32(c)
            x = end
            column += 1
        }
    }
    var mean = [UInt8](repeating: 0, count: cols * rows)
    for i in mean.indices where count[i] > 0 {
        mean[i] = UInt8(min(255, sum[i] / count[i]))
    }
    return LumaTiles(cols: cols, rows: rows, tile: tile, mean: mean)
}

/// The luma grid plus a per-tile pixel signature. The signature catches tiles
/// whose content changed without moving the mean luma.
func lumaSnapshot(_ buffer: CVPixelBuffer) throws -> (tiles: LumaTiles, signatures: [UInt64]) {
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AnalysisError.pixelBuffer }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw AnalysisError.pixelBuffer }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let tile = 16
    let cols = max(1, (width + tile - 1) / tile), rows = max(1, (height + tile - 1) / tile)
    var sum = [UInt32](repeating: 0, count: cols * rows)
    var count = [UInt32](repeating: 0, count: cols * rows)
    var signatures = [UInt64](repeating: 14695981039346656037, count: cols * rows)
    for y in stride(from: 0, to: height, by: 2) {
        let row = base + y * rowBytes
        let ry = y / tile
        for x in stride(from: 0, to: width, by: 2) {
            let i = x * 4
            let luma = (29 * Int(row[i]) + 150 * Int(row[i + 1]) + 77 * Int(row[i + 2])) >> 8
            let index = ry * cols + x / tile
            signatures[index] = (signatures[index] ^ UInt64(luma >> 4)) &* 1099511628211
            sum[index] += UInt32(luma)
            count[index] += 1
        }
    }
    var mean = [UInt8](repeating: 0, count: cols * rows)
    for i in mean.indices where count[i] > 0 {
        mean[i] = UInt8(min(255, sum[i] / count[i]))
    }
    return (LumaTiles(cols: cols, rows: rows, tile: tile, mean: mean), signatures)
}
