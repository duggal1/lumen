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
    /// same segment. The builder arbitrates distinct subjects, and explicit
    /// input transfers ownership at a half-open source-time boundary.
    static func intents(shots: [VisualShot], input: [ZoomPlanner.Intent] = [],
                        src: SourceInfo, tm: TimeMap) -> [ZoomPlanner.Intent] {
        let W = Double(src.width), H = Double(src.height)
        guard W > 0, H > 0 else { return [] }
        var out: [ZoomPlanner.Intent] = []
        for shot in shots {
            guard let opening = shot.waypoints.first,
                  shot.start.isFinite, shot.end.isFinite,
                  shot.end > tm.trimStart, shot.start < tm.trimEnd else { continue }
            let start = max(shot.start, tm.trimStart)
            var end = min(shot.end, tm.trimEnd)
            if let action = shot.actionTime {
                // Half-open ownership [start, end): a later explicit intent
                // can terminate the shot but must not invalidate its history.
                if let next = input.lazy.filter({ $0.t.isFinite && $0.t > action + 0.000001 &&
                    $0.t >= start && $0.t < end }).map(\.t).min() { end = next }
            }
            guard end > start + 0.02 else { continue }
            guard var first = intent(opening, t: start, tEnd: end, W: W, H: H) else { continue }
            first.visualSubjectID = shot.subjectID
            first.sustainedVisual = shot.sustained
            first.visualActionTime = shot.actionTime
            first.visualEnd = shot.actionTime == nil ? nil : end
            guard !collides(first, with: input) else { continue }
            out.append(first)
            for waypoint in shot.waypoints.dropFirst() {
                let t = min(max(waypoint.t, start), end)
                guard t < end, var pan = intent(waypoint, t: t, tEnd: t, W: W, H: H) else { continue }
                pan.visualSubjectID = shot.subjectID
                pan.sustainedVisual = shot.sustained
                pan.visualActionTime = shot.actionTime
                pan.visualEnd = first.visualEnd
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
            if let action = candidate.visualActionTime, let end = candidate.visualEnd {
                if other.kind == .click, abs(other.t - action) < 0.000001 { return false }
                // Input at or beyond the exclusive end has no temporal
                // intersection, even if the control lies inside the subject.
                guard other.t < end, other.tEnd >= candidate.t else { return false }
            } else {
                // Retain the legacy guard for uncorroborated passive changes.
                guard other.t <= candidate.tEnd + inputGuard,
                      candidate.t <= other.tEnd + inputGuard else { return false }
            }
            if let r = other.frameRect ?? other.rect, let c = candidate.rect {
                return r.insetBy(dx: -spatialGuard, dy: -spatialGuard).intersects(c)
            }
            return hypot(other.x - candidate.x, other.y - candidate.y) <= spatialGuard
        }
    }
}
