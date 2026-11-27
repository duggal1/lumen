import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

@Suite struct DirectorSubjectLifetimeTests {
    private func replay(response: Bool, long: Bool = true) -> (grids: [ActivityGrid], events: [InputEvent]) {
        let events = [InputEvent(t: 0.5, kind: .down, x: 80, y: 100)] +
            (0..<140).map { InputEvent(t: 0.8 + Double($0) * 0.1, kind: .move, x: 80, y: 100) }
        let grids = (0...160).map { i -> ActivityGrid in
            let t = Double(i) / 10
            var cells = [UInt8](repeating: 0, count: ActivityConst.cells)
            if i >= 12 && i <= (long ? 125 : 35), !(55...65).contains(i) {
                let bottom = response ? min(16, 9 + (i - 12) / 5) : 9
                for y in 8...bottom {
                    for x in 27...32 { cells[y * ActivityConst.gw + x] = 255 }
                }
                // The sidebar hover highlight is unrelated and local.
                for y in 2...3 { for x in 1...3 { cells[y * ActivityConst.gw + x] = 255 } }
            }
            return ActivityGrid(t: t, cells: cells)
        }
        return (grids, events)
    }

    @Test func pairedPointerReplayRequiresCorroboratedGrowth() throws {
        let positive = replay(response: true), negative = replay(response: false)
        let input = ActivityInputs.make(events: positive.events)
        let p = ActivityShotBuilder.build(grids: positive.grids, source: (1920, 1080), inputs: input, settings: ActivitySettings())
        let n = ActivityShotBuilder.build(grids: negative.grids, source: (1920, 1080), inputs: input, settings: ActivitySettings())
        #expect(n.shots.isEmpty)
        let shot = try #require(p.shots.first)
        #expect(p.shots.count == 1)
        #expect(shot.sustained)
        #expect(shot.end > 12.5)
        #expect(shot.waypoints.count == 1)
        #expect(shot.actionTime == 0.5)
        #expect(shot.waypoints[0].rect.x > 400)
        #expect(p.mergedBusy.contains { $0.contains(6) })
    }

    @Test func sustainedResultSurvivesPlannerCeiling() throws {
        let fixture = replay(response: true)
        let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 16, backingScale: 1, originX: 0, originY: 0)
        let result = ActivityShotBuilder.build(grids: fixture.grids, source: (1920, 1080),
            inputs: ActivityInputs.make(events: fixture.events), settings: ActivitySettings())
        let plan = ZoomPlanner.plan(events: fixture.events, ax: [], typing: [], activity: [], src: src,
            p: CameraParams(), tm: TimeMap(sourceDuration: 16), avoid: [], activityShots: result.shots)
        let segment = try #require(plan.segments.first)
        #expect(plan.segments.count == 1)
        #expect(plan.kinds[segment.id] == .visual)
        #expect(segment.end > 12.5)
        #expect(segment.start >= 1)
    }

    @Test func independentOverlappingRegionsNeverBecomeOnePan() throws {
        let grids = (0...30).map { i -> ActivityGrid in
            var cells = [UInt8](repeating: 0, count: ActivityConst.cells)
            if (3...15).contains(i) {
                for y in 5...8 { for x in 5...8 { cells[y * ActivityConst.gw + x] = 255 } }
            }
            if (10...20).contains(i) {
                for y in 18...21 { for x in 36...40 { cells[y * ActivityConst.gw + x] = 255 } }
            }
            return ActivityGrid(t: Double(i)/10, cells: cells)
        }
        let result = ActivityShotBuilder.build(grids: grids, source: (1920, 1080), inputs: ActivityInputs(), settings: ActivitySettings())
        #expect(result.shots.count == 1)
        let shot = try #require(result.shots.first)
        #expect(shot.waypoints.count == 1)
        #expect(shot.waypoints[0].rect.x < 500)
    }
}
