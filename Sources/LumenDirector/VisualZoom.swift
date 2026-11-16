import Foundation
import LumenCore
import LumenProject

/// Groups localized screen changes into stable shots; input and manual edits keep priority.
/// A change near the pointer is stronger evidence than the same change across
/// the screen, so it needs fewer samples and a smaller area.
enum VisualZoom {
    static func intents(_ points: [ActivityPoint], events: [InputEvent], input: [ZoomPlanner.Intent],
                        src: SourceInfo, tm: TimeMap) -> [ZoomPlanner.Intent] {
        let width = Double(src.width), height = Double(src.height), area = width * height
        guard area > 0 else { return [] }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let navigation = events.filter { $0.kind == .scroll || $0.kind == .drag }
        let moves = events.filter { $0.kind == .move && $0.t.isFinite }
        var result: [ZoomPlanner.Intent] = []
        var start = 0.0, end = 0.0, region: CGRect?
        var count = 0, cooldown = -Double.infinity

        func pointer(near t: Double) -> SIMD2<Double>? {
            var best: SIMD2<Double>?
            var bestGap = Double.greatestFiniteMagnitude
            for e in moves {
                let gap = t - e.t
                if gap < -0.05 { break }
                if gap <= 0.9, gap < bestGap {
                    bestGap = gap
                    best = SIMD2(Double(e.x), Double(e.y))
                }
            }
            return best
        }

        func close() {
            guard let rect = region else { return }
            defer { region = nil; count = 0 }
            let nearPointer = pointer(near: end).map { p in
                rect.insetBy(dx: -40, dy: -40).contains(CGPoint(x: p.x, y: p.y))
            } ?? false
            let minCount = nearPointer ? 2 : 3
            let minArea = area * (nearPointer ? 0.0025 : 0.004)
            guard count >= minCount, end - start >= 0.3, start >= cooldown,
                  rect.width * rect.height <= area * 0.55,
                  rect.width * rect.height >= minArea,
                  !input.contains(where: { $0.t <= end + 1 && $0.tEnd >= start - 1 }),
                  !navigation.contains(where: { $0.t >= start - 0.8 && $0.t <= end + 0.8 }) else { return }
            result.append(ZoomPlanner.Intent(kind: .visual, t: start, tEnd: min(end + 1.1, tm.trimEnd),
                                             x: rect.midX, y: rect.midY, rect: rect))
            cooldown = end + 3
        }

        for point in points.sorted(by: { $0.t < $1.t }) {
            guard point.t.isFinite, point.t >= tm.trimStart + 0.2, point.t <= tm.trimEnd - 0.2,
                  !tm.isCut(point.t), let bounds = point.region,
                  bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0,
                  let coverage = point.coverage, coverage.isFinite, coverage >= 0.0012, coverage <= 0.45 else {
                close(); continue
            }
            let rect = bounds.intersection(canvas)
            guard !rect.isNull, rect.width * rect.height >= area * 0.0025,
                  rect.width * rect.height <= area * 0.55, rect.midY > height * 0.04 else { close(); continue }
            if let previous = region {
                let distance = hypot(rect.midX - previous.midX, rect.midY - previous.midY)
                let cut = tm.cuts.contains { $0.start < point.t && $0.end > end }
                if point.t - end > 0.75 || distance > hypot(width, height) * 0.18 || cut { close() }
            }
            if region == nil { start = point.t; region = rect }
            else { region = region?.union(rect) }
            end = point.t; count += 1
        }
        close()
        return result
    }
}