import Foundation
import Testing
import LumenProject

@Test func legacyZoomIsMigratedFromOutputToSourceTime() throws {
    var t = Timeline(duration: 10)
    t.timeMap = TimeMap(sourceDuration: 10, ramps: [SpeedRamp(start: 1, end: 8, speed: 3)])
    let outputStart = 2.0, outputEnd = 3.0
    t.zoom = [ZoomSegment(start: outputStart, end: outputEnd, scale: 2, focus: .follow, origin: .manual)]
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any])
    object["schemaVersion"] = 1
    let migrated = try JSONDecoder().decode(Timeline.self, from: JSONSerialization.data(withJSONObject: object))
    let z = try #require(migrated.zoom.first)
    #expect(abs(migrated.timeMap.output(atSource: z.start) - outputStart) < 0.001)
    #expect(abs(migrated.timeMap.output(atSource: z.end) - outputEnd) < 0.001)
    let again = try JSONDecoder().decode(Timeline.self, from: JSONEncoder().encode(migrated))
    #expect(again.zoom == migrated.zoom)
}

@Test func cutAtStartDoesNotReturnRemovedContent() {
    let map = TimeMap(sourceDuration: 5, cuts: [CutRange(start: 0, end: 1)])
    #expect(abs(map.source(atOutput: 0) - 1) < 0.01)
}
