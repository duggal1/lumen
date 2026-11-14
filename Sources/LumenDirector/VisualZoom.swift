import Foundation
import LumenCore
import LumenProject

/// Groups localized screen changes into stable shots; input and manual edits keep priority.
enum VisualZoom {
    static func intents(_ points: [ActivityPoint], events: [InputEvent], input: [ZoomPlanner.Intent],
                        src: SourceInfo, tm: TimeMap) -> [ZoomPlanner.Intent] {
        let width = Double(src.width), height = Double(src.height), area = width * height
        guard area > 0 else { return [] }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let navigation = events.filter { $0.kind == .scroll || $0.kind == .drag }
        var result: [ZoomPlanner.Intent] = []
        var start = 0.0, end = 0.0, region: CGRect?
        var count = 0, cooldown = -Double.infinity
        func close() {
            guard let rect = region else { return }
            defer { region = nil; count = 0 }
            guard count >= 3, end - start >= 0.3, start >= cooldown,
                  rect.width * rect.height <= area * 0.55,
                  !input.contains(where: { $0.t <= end + 1 && $0.tEnd >= start - 1 }),
                  !navigation.contains(where: { $0.t >= start - 0.8 && $0.t <= end + 0.8 }) else { return }
            result.append(ZoomPlanner.Intent(kind: .visual, t: start, tEnd: min(end + 1.1, tm.trimEnd),
                                             x: rect.midX, y: rect.midY, rect: rect))
            cooldown = end + 3
        }
        for point in points.sorted(by: { $0.t < $1.t }) {
            guard point.t.isFinite, point.t >= tm.trimStart + 0.3, point.t <= tm.trimEnd - 0.8,
                  !tm.isCut(point.t), let bounds = point.region,
                  bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0,
                  let coverage = point.coverage, coverage.isFinite, coverage >= 0.002, coverage <= 0.35 else {
                close(); continue
            }
            let rect = bounds.intersection(canvas)
            guard !rect.isNull, rect.width * rect.height >= area * 0.008,
                  rect.width * rect.height <= area * 0.55, rect.midY > height * 0.08 else { close(); continue }
            if let previous = region {
                let distance = hypot(rect.midX - previous.midX, rect.midY - previous.midY)
                let cut = tm.cuts.contains { $0.start < point.t && $0.end > end }
                if point.t - end > 0.6 || point.t - start > 8 || distance > hypot(width, height) * 0.16 || cut { close() }
            }
            if region == nil { start = point.t; region = rect }
            else { region = region?.union(rect) }
            end = point.t; count += 1
        }
        close()
        return result
    }
}
