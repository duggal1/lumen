import Testing
import Foundation
import LumenCore
import LumenProject
import LumenAnalysis

// A7 on pixel data: the tracer follows a growing typed line through
// sequential luma grids (tile = 16 px, 40x22 grid over 640x360).
@Test func tracerFollowsGrowingLine() throws {
    let tile = 16, cols = 40, rows = 22
    func grid(_ lit: [(Int, Int)]) -> LumaTiles {
        var mean = [UInt8](repeating: 200, count: cols * rows)
        for (c, r) in lit { mean[r * cols + c] = 40 }
        return LumaTiles(cols: cols, rows: rows, tile: tile, mean: mean)
    }
    let base = grid([])
    // Line starts at col 5, row 7; each frame adds one char to the right.
    let frames = (1...10).map { k -> LumaTiles in grid((0..<k).map { (5 + $0, 7) }) }
    let grids = [base] + frames
    let ts = (0...10).map { 1.0 + Double($0) * 0.08 }
    let tr = TypingTracer.trace(burst: (t0: 1.0, t1: 1.8), ts: ts, grids: grids, anchor: nil, srcH: 352)
    let found = try #require(tr)
    // Caret should advance right across the typed span.
    let xs = found.samples.map(\.x)
    let ys = found.samples.map(\.y)
    print("A7 caret x:", xs.map { String(format: "%.0f", $0) }.joined(separator: "->"), " y:", ys.map { String(format: "%.0f", $0) }.joined(separator: ","))
    #expect(found.samples.count >= 5)
    #expect((xs.last ?? 0) > (xs.first ?? 0) + 40)                    // advances right as text grows
    #expect(ys.allSatisfy { abs($0 - Double(7 * 16)) < 32 })          // stays on the typed line
    let dirChanges = zip(xs, xs.dropFirst()).filter { abs($0.1) > 0 }.count
    _ = dirChanges
    // No backward jumps wider than a tile.
    for (a, b) in zip(xs, xs.dropFirst()) { #expect(b >= a - Double(tile)) }
}
