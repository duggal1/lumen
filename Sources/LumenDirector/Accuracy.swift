import Foundation
import LumenCore
import LumenProject

/// A measurement, not a subjective quality rating. Error is the excess
/// offset beyond physical viewport clamping at the exact interaction time.
public struct ZoomAccuracy: Sendable {
    public var clicks = 0
    public var zoomedClicks = 0
    public var insideMargin = 0
    public var medianExcessError = 0.0
    public var medianArrival = 1.0
    public var maxExcessError = 0.0
    public init() {}
}

public enum AccuracyReport {
    public static func measure(_ timeline: Timeline, events: [InputEvent]) -> ZoomAccuracy {
        var result = ZoomAccuracy()
        guard let derived = timeline.derived else { return result }
        let tm = timeline.timeMap
        let width = derived.sourceSize.x, height = derived.sourceSize.y
        guard width > 0, height > 0 else { return result }
        var errors: [Double] = [], arrivals: [Double] = []
        for event in events where event.kind == .down && event.button == 0 &&
            event.t >= tm.trimStart && event.t <= tm.trimEnd - 0.8 && !tm.isCut(event.t) {
            result.clicks += 1
            guard let zoom = timeline.zoom.first(where: { $0.start <= event.t && event.t < $0.end }),
                  zoom.scale > 1.001 else { continue }
            let frame = timeline.evaluate(at: tm.output(atSource: event.t))
            let scale = max(Double(frame.cameraScale), 1)
            let viewWidth = width / scale, viewHeight = height / scale
            let x = Double(event.x), y = Double(event.y)
            guard x.isFinite && y.isFinite && x >= 0 && x <= width && y >= 0 && y <= height else { continue }
            let nx = (x - (Double(frame.cameraCenter.x) - viewWidth / 2)) / viewWidth
            let ny = (y - (Double(frame.cameraCenter.y) - viewHeight / 2)) / viewHeight
            let achievableX = clamp(x, viewWidth / 2, width - viewWidth / 2)
            let achievableY = clamp(y, viewHeight / 2, height - viewHeight / 2)
            let idealX = (x - achievableX) / viewWidth
            let idealY = (y - achievableY) / viewHeight
            let excess = hypot((nx - 0.5) - idealX, (ny - 0.5) - idealY)
            result.zoomedClicks += 1
            if nx >= 0.12 && nx <= 0.88 && ny >= 0.12 && ny <= 0.88 { result.insideMargin += 1 }
            errors.append(excess)
            arrivals.append(clamp(log(scale) / log(zoom.scale), 0, 1))
        }
        func median(_ items: [Double], empty: Double) -> Double {
            guard !items.isEmpty else { return empty }
            let sorted = items.sorted()
            return sorted[sorted.count / 2]
        }
        result.medianExcessError = median(errors, empty: 0)
        result.maxExcessError = errors.max() ?? 0
        result.medianArrival = median(arrivals, empty: 1)
        return result
    }
}
