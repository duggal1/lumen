import Foundation
import LumenProject

/// Objective review evidence, deliberately not an aesthetic score. No network,
/// no frame allocations, and no user content (caption text) in the report.
enum AgentCinematicEvidence {
    static func measure(_ timeline: Timeline) -> (valid: Bool, report: JSONValue) {
        let duration = timeline.compositionDuration
        guard duration.isFinite, duration > 0, let tracks = timeline.derived else {
            return (false, .object(["status": .string("missing_evidence"), "requires_external_review": .bool(true)]))
        }
        let camera = tracks.camera
        let n = camera.nx.count
        let valid = n > 0 && camera.rate.isFinite && camera.rate > 0
            && camera.ny.count == n && camera.lz.count == n
            && camera.nx.allSatisfy(\.isFinite) && camera.ny.allSatisfy(\.isFinite) && camera.lz.allSatisfy(\.isFinite)
            && timeline.zoom.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.scale.isFinite && $0.scale > 0 }
        var travel = 0.0
        if valid && n > 1 {
            for i in 1..<n {
                travel += hypot(Double(camera.nx[i]) - Double(camera.nx[i - 1]),
                                Double(camera.ny[i]) - Double(camera.ny[i - 1]))
            }
        }
        let tm = timeline.timeMap
        let holds = timeline.zoom.map { tm.output(atSource: $0.end) - tm.output(atSource: $0.start) }
            .filter { $0.isFinite && $0 > 0 }.sorted()
        let captions = tracks.captions.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        let maxCaptionPace = captions.map { Double($0.text.count) / ($0.end - $0.start) }.filter(\.isFinite).max() ?? 0
        return (valid, .object([
            "status": .string(valid ? "measured" : "invalid_camera_track"),
            "requires_external_review": .bool(true),
            "zoom_shots": .int(holds.count),
            "shots_per_minute": .number(Double(holds.count) * 60 / duration),
            "short_shots_under_0_7s": .int(holds.filter { $0 < 0.7 }.count),
            "median_shot_seconds": .number(holds.isEmpty ? 0 : holds[holds.count / 2]),
            "normalized_camera_travel": .number(travel),
            "max_caption_characters_per_second": .number(maxCaptionPace)
        ]))
    }
}
