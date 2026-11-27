import Foundation
import CoreGraphics
import LumenCore
import LumenProject

/// Adapter from pure `VisualShot`s to the planner's existing `.visual` intent
/// stream. The detector now lives in `ActivityShotBuilder`; this type only maps
/// framing. It emits no hover intents and leaves explicit input at higher
/// priority. Pure value functions; safe to call from any task.
enum VisualAutofocus {
    /// Seconds of slack around an explicit subject where a passive shot is dropped.
    private static let inputGuard = 0.5
    /// Source-pixel slack used when a subject has no resolved rect.
    private static let spatialGuard = 48.0

    /// Maps every shot to planner intents. `waypoints[0]` opens the shot; later
    /// waypoints become in-shot pans that the existing solver folds into the
    /// same segment. Overlapping shots were already chained by the builder, so
    /// two segments never claim the same instant.
    static func intents(shots: [VisualShot], input: [ZoomPlanner.Intent] = [],
                        src: SourceInfo, tm: TimeMap) -> [ZoomPlanner.Intent] {
        let W = Double(src.width), H = Double(src.height)
        guard W > 0, H > 0 else { return [] }
        var out: [ZoomPlanner.Intent] = []
        for shot in shots {
            guard let opening = shot.waypoints.first else { continue }
            let start = min(max(shot.start, tm.trimStart), tm.trimEnd)
            var end = min(max(shot.end, start + 0.2), tm.trimEnd)
            if shot.sustained, let action = shot.actionTime {
                // Later explicit actions end the previous response subject.
                if let next = input.filter({ $0.t > max(action + 0.05, start) && $0.t < end })
                    .map(\.t).min() { end = next }
            }
            guard end > start else { continue }
            guard var first = intent(opening, t: start, tEnd: end, W: W, H: H) else { continue }
            first.visualSubjectID = shot.subjectID
            first.sustainedVisual = shot.sustained
            first.visualActionTime = shot.actionTime
            guard !collides(first, with: input) else { continue }
            out.append(first)
            for waypoint in shot.waypoints.dropFirst() {
                let t = min(max(waypoint.t, start), end)
                guard t < end, var pan = intent(waypoint, t: t, tEnd: t, W: W, H: H) else { continue }
                pan.visualSubjectID = shot.subjectID
                pan.sustainedVisual = shot.sustained
                pan.visualActionTime = shot.actionTime
                if !collides(pan, with: input) { out.append(pan) }
            }
        }
        return out.sorted { $0.t < $1.t }
    }

    /// Compatibility entry point kept so existing callers still compile. The
    /// grid-based path is `intents(shots:input:src:tm:)`; the legacy path uses
    /// the same causal hover evidence instead of dropping pointer observations.
    static func intents(_ points: [ActivityPoint], events: [InputEvent] = [],
                        input: [ZoomPlanner.Intent] = [], src: SourceInfo,
                        tm: TimeMap) -> [ZoomPlanner.Intent] {
        VisualZoom.intents(points, events: events,
                           input: input, src: src, tm: tm)
    }

    private static func intent(_ waypoint: VisualShot.Waypoint, t: Double, tEnd: Double,
                               W: Double, H: Double) -> ZoomPlanner.Intent? {
        guard t.isFinite, tEnd.isFinite else { return nil }
        let r = CGRect(x: waypoint.rect.x, y: waypoint.rect.y,
                       width: waypoint.rect.w, height: waypoint.rect.h)
        guard r.width > 1, r.height > 1,
              r.minX.isFinite, r.minY.isFinite,
              r.minX >= -W, r.minY >= -H, r.maxX <= 2 * W, r.maxY <= 2 * H else { return nil }
        var result = ZoomPlanner.Intent(kind: .visual, t: t, tEnd: tEnd,
                                        x: r.midX, y: r.midY)
        result.rect = r
        result.preferredScale = waypoint.scale
        return result
    }

    private static func collides(_ candidate: ZoomPlanner.Intent,
                                 with input: [ZoomPlanner.Intent]) -> Bool {
        input.contains { other in
            // The initiating click is evidence for the corroborated result,
            // not a second competing subject. Later input still has priority.
            if candidate.sustainedVisual, let action = candidate.visualActionTime,
               other.kind == .click, abs(other.t - action) < 0.000001 { return false }
            guard other.t <= candidate.tEnd + inputGuard,
                  candidate.t <= other.tEnd + inputGuard else { return false }
            if let r = other.frameRect ?? other.rect, let c = candidate.rect {
                return r.insetBy(dx: -spatialGuard, dy: -spatialGuard).intersects(c)
            }
            return hypot(other.x - candidate.x, other.y - candidate.y) <= spatialGuard
        }
    }
}
