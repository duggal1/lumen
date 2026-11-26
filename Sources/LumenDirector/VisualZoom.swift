import Foundation
import LumenCore
import LumenProject

/// Groups localized screen changes into stable shots; input and manual edits keep priority.
/// Legacy point streams use the same conservative hover policy as grid streams.
/// Pointer proximity is negative evidence, never a reason to magnify.
enum VisualZoom {
    static func intents(_ points: [ActivityPoint], events: [InputEvent], input: [ZoomPlanner.Intent],
                        src: SourceInfo, tm: TimeMap) -> [ZoomPlanner.Intent] {
        let width = Double(src.width), height = Double(src.height), area = width * height
        guard area > 0 else { return [] }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let navigation = events.filter { $0.kind == .scroll || $0.kind == .drag }
        let inputs = ActivityInputs.make(events: events)
        let cw = width / Double(ActivityConst.gw), ch = height / Double(ActivityConst.gh)
        var hoverTainted = false
        var result: [ZoomPlanner.Intent] = []
        var start = 0.0, end = 0.0, region: CGRect?
        var count = 0, cooldown = -Double.infinity

        func close() {
            guard let rect = region else { return }
            defer { region = nil; count = 0; hoverTainted = false }
            guard !hoverTainted, count >= 3, end - start >= 0.3, start >= cooldown,
                  rect.width * rect.height <= area * 0.55,
                  rect.width * rect.height >= area * 0.004,
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
            if point.t - start <= 0.25 {
                let box = CellBox(x0: Int(floor(rect.minX / cw)), y0: Int(floor(rect.minY / ch)),
                                  x1: Int(ceil(rect.maxX / cw)) - 1, y1: Int(ceil(rect.maxY / ch)) - 1)
                if inputs.hoverAssociated(at: point.t, box: box, cw: cw, ch: ch, radius: 2.5) {
                    hoverTainted = true
                }
            }
            end = point.t; count += 1
        }
        close()
        return result
    }
}