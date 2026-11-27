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

    private func responseShot(end: Double = 14) -> VisualShot {
        var shot = VisualShot(start: 1, end: end, waypoints: [
            .init(t: 1, rect: PxRect(x: 900, y: 180, w: 800, h: 600), scale: 1.6)
        ], strength: 100, kind: .region)
        shot.subjectID = 1; shot.sustained = true; shot.actionTime = 0.5
        return shot
    }

    @Test func overlappingURLClickEndsResponseWithoutErasingHistory() throws {
        let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 20,
                                backingScale: 1, originX: 0, originY: 0)
        let click = ZoomPlanner.Intent(kind: .click, t: 12, tEnd: 12, x: 1300, y: 680,
                                       rect: CGRect(x: 1200, y: 640, width: 200, height: 80))
        let result = VisualAutofocus.intents(shots: [responseShot()], input: [click],
                                             src: source, tm: TimeMap(sourceDuration: 20))
        let response = try #require(result.first)
        #expect(result.count == 1)
        #expect(response.t == 1)
        #expect(response.tEnd == 12)
        #expect(response.visualEnd == 12)
        let lateClick = ZoomPlanner.Intent(kind: .click, t: 14.1, tEnd: 14.1, x: 1300, y: 680,
                                           rect: click.rect)
        let late = VisualAutofocus.intents(shots: [responseShot()], input: [lateClick],
                                          src: source, tm: TimeMap(sourceDuration: 20))
        #expect(late.first?.tEnd == 14)
    }

    @Test func precedingExplicitTypingStillHasPriority() {
        let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 20,
                                backingScale: 1, originX: 0, originY: 0)
        let typing = ZoomPlanner.Intent(kind: .typing, t: 0.2, tEnd: 2, x: 1300, y: 500,
                                        frameRect: CGRect(x: 1000, y: 300, width: 500, height: 400))
        #expect(VisualAutofocus.intents(shots: [responseShot()], input: [typing],
                                       src: source, tm: TimeMap(sourceDuration: 20)).isEmpty)
    }

    @Test func completeSyntheticResponseToDestinationHandoff() throws {
        let fixture = replay(response: true)
        // Same pointer sequence until the user clicks within the response.
        // The destination has a stable reveal, not streaming growth.
        let click = InputEvent(t: 13, kind: .down, x: 1200, y: 560)
        let events = fixture.events.filter { $0.t < 13 } + [click]
        let grids = fixture.grids.map { grid -> ActivityGrid in
            guard grid.t >= 13.2, grid.t <= 13.9 else { return grid }
            var cells = grid.cells
            for y in 4...10 { for x in 4...11 { cells[y * ActivityConst.gw + x] = 255 } }
            return ActivityGrid(t: grid.t, cells: cells)
        }
        let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 16,
                             backingScale: 1, originX: 0, originY: 0)
        let result = ActivityShotBuilder.build(grids: grids, source: (1920, 1080),
            inputs: ActivityInputs.make(events: events), settings: ActivitySettings())
        #expect(result.shots.count == 2)
        let first = try #require(result.shots.first)
        let destination = try #require(result.shots.last)
        #expect(first.sustained && first.end == 13)
        #expect(destination.actionTime == 13)
        #expect(destination.waypoints.first?.rect.x == 0)
        let plan = ZoomPlanner.plan(events: events, ax: [], typing: [], activity: [], src: src,
            p: CameraParams(), tm: TimeMap(sourceDuration: 16), avoid: [], activityShots: result.shots)
        #expect(plan.segments.count == 2)
        let response = try #require(plan.segments.first)
        let next = try #require(plan.segments.last)
        #expect(plan.kinds[response.id] == .visual && plan.kinds[next.id] == .visual)
        #expect(response.end == 13)
        #expect(response.start < 2 && response.end > 12.5)
        #expect(next.start >= 13 && next.start >= response.end)
        // No destination evidence: ordinary explicit click remains, and
        // cannot erase the response or extend its segment past the click.
        let noReveal = ActivityShotBuilder.build(grids: fixture.grids, source: (1920, 1080),
            inputs: ActivityInputs.make(events: events), settings: ActivitySettings())
        let fallback = ZoomPlanner.plan(events: events, ax: [], typing: [], activity: [], src: src,
            p: CameraParams(), tm: TimeMap(sourceDuration: 16), avoid: [], activityShots: noReveal.shots)
        let prior = try #require(fallback.segments.first)
        #expect(fallback.segments.count == 2)
        #expect(prior.end == 13)
        #expect(fallback.kinds[prior.id] == .visual)
        #expect(fallback.segments.last.map { fallback.kinds[$0.id] == .click } == true)
        #expect(plan.protectedVisual.contains(response.id))
    }

    @Test func trimmedOutResponseDoesNotResurrectAtTrimStart() {
        let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 20,
                             backingScale: 1, originX: 0, originY: 0)
        let tm = TimeMap(sourceDuration: 20, trimStart: 15, trimEnd: 20)
        #expect(VisualAutofocus.intents(shots: [responseShot()], src: src, tm: tm).isEmpty)
    }


    @Test func cameraHandoffCannotStealReadingTime() throws {
        let response = ZoomSegment(start: 1, end: 13, scale: 1.6,
            focus: .fixed(x: 0.7, y: 0.5), origin: .auto)
        let next = ZoomSegment(start: 13.1, end: 15, scale: 1.8,
            focus: .fixed(x: 0.25, y: 0.4), origin: .auto)
        let tm = TimeMap(sourceDuration: 17)
        let track = try #require(CameraSolver.solve(zoom: [response, next], tm: tm,
            cursor: CursorTrack(count: Int(17 * gridRate) + 1), p: CameraParams(),
            src: SIMD2<Double>(1920, 1080), outDur: 17, loop: nil,
            kinds: [response.id: .visual, next.id: .visual],
            protectedVisual: [response.id], follow: [:], cancelled: { false }))
        func tick(_ t: Double) -> Int { Int((t * track.rate).rounded()) }
        let reading = tick(11)
        for k in tick(12.5)...tick(12.95) {
            #expect(abs(track.nx[k] - track.nx[reading]) < 0.002)
            #expect(abs(track.ny[k] - track.ny[reading]) < 0.002)
            #expect(abs(track.lz[k] - track.lz[reading]) < 0.002)
        }
        #expect(track.nx[tick(14.3)] < track.nx[reading] - 0.1)
        for k in tick(12.5)...tick(14.5) {
            #expect(abs(track.nx[k] - track.nx[k - 1]) < 0.02)
            #expect(abs(track.lz[k] - track.lz[k - 1]) < 0.02)
        }
    }


    private func activityGrid(_ i: Int, bottom: Int?) -> ActivityGrid {
        var cells = [UInt8](repeating: 0, count: ActivityConst.cells)
        if let bottom {
            for y in 8...bottom {
                for x in 27...32 { cells[y * ActivityConst.gw + x] = 255 }
            }
        }
        return ActivityGrid(t: Double(i) / 10, cells: cells)
    }

    @Test func provisionalSeedBridgesDelayedGrowthButNotStationaryHover() throws {
        let events = [InputEvent(t: 0.5, kind: .down, x: 80, y: 100)] +
            (0..<75).map { InputEvent(t: 0.8 + Double($0) * 0.1, kind: .move, x: 80, y: 100) }
        func fixture(growing: Bool) -> [ActivityGrid] {
            (0...90).map { i in
                if (12...16).contains(i) { return activityGrid(i, bottom: 9) }
                if (32...62).contains(i) {
                    return activityGrid(i, bottom: growing ? min(16, 9 + (i - 32) / 5) : 9)
                }
                return activityGrid(i, bottom: nil)
            }
        }
        let inputs = ActivityInputs.make(events: events)
        let positive = ActivityShotBuilder.build(grids: fixture(growing: true),
            source: (1920, 1080), inputs: inputs, settings: ActivitySettings())
        let negative = ActivityShotBuilder.build(grids: fixture(growing: false),
            source: (1920, 1080), inputs: inputs, settings: ActivitySettings())
        let shot = try #require(positive.shots.first)
        #expect(positive.shots.count == 1 && shot.sustained)
        #expect(shot.actionTime == 0.5 && shot.start < 1.3 && shot.end > 6.2)
        #expect(negative.shots.isEmpty)
    }

    @Test func unconfirmedTrackCannotBorrowGrowthAcrossNextAction() throws {
        let events = [InputEvent(t: 0.5, kind: .down, x: 80, y: 100),
                      InputEvent(t: 0.8, kind: .move, x: 80, y: 100),
                      InputEvent(t: 2.1, kind: .down, x: 80, y: 100)]
        let grids = (0...65).map { i in
            activityGrid(i, bottom: (12...48).contains(i) ? min(16, 9 + (i - 12) / 6) : nil)
        }
        let result = ActivityShotBuilder.build(grids: grids, source: (1920, 1080),
            inputs: ActivityInputs.make(events: events), settings: ActivitySettings())
        #expect(!result.shots.contains { $0.sustained && $0.actionTime == 0.5 })
        let shot = try #require(result.shots.first { $0.sustained })
        #expect(shot.actionTime == 2.1 && shot.start >= 2.1)
    }

    @Test func latePointerLocalGrowthCannotConfirmRemoteHover() {
        let events = [InputEvent(t: 0.5, kind: .down, x: 80, y: 100),
                      InputEvent(t: 0.8, kind: .move, x: 80, y: 100),
                      InputEvent(t: 1.7, kind: .move, x: 1200, y: 360)]
        let grids = (0...65).map { i in
            activityGrid(i, bottom: (12...48).contains(i) ? min(16, 9 + (i - 12) / 5) : nil)
        }
        let result = ActivityShotBuilder.build(grids: grids, source: (1920, 1080),
            inputs: ActivityInputs.make(events: events), settings: ActivitySettings())
        #expect(result.shots.isEmpty)
    }

    @Test func confirmedResponseBridgesLongerTokenPauseWithoutPumping() throws {
        let fixture = replay(response: true)
        let grids = fixture.grids.map { grid in
            (5.5...7.9).contains(grid.t)
                ? ActivityGrid(t: grid.t, cells: [UInt8](repeating: 0, count: ActivityConst.cells))
                : grid
        }
        let result = ActivityShotBuilder.build(grids: grids, source: (1920, 1080),
            inputs: ActivityInputs.make(events: fixture.events), settings: ActivitySettings())
        let shot = try #require(result.shots.first)
        #expect(result.shots.count == 1 && shot.sustained && shot.end > 12.5)
        #expect(shot.waypoints.count == 1)
        #expect(result.mergedBusy.contains { $0.contains(7) })
    }

    @Test func lateClickOnResponseCanFrameDestinationAfterWideRelease() throws {
        let fixture = replay(response: true)
        let grids = (0...190).map { i -> ActivityGrid in
            if i <= 160 && !(157...160).contains(i) { return fixture.grids[i] }
            var cells = [UInt8](repeating: 0, count: ActivityConst.cells)
            if (157...165).contains(i) {
                for y in 4...10 { for x in 4...11 { cells[y * ActivityConst.gw + x] = 255 } }
            }
            return ActivityGrid(t: Double(i) / 10, cells: cells)
        }
        func build(x: Float, y: Float) -> ActivityResult {
            let events = fixture.events + [InputEvent(t: 15.5, kind: .down, x: x, y: y)]
            return ActivityShotBuilder.build(grids: grids, source: (1920, 1080),
                inputs: ActivityInputs.make(events: events), settings: ActivitySettings())
        }
        let positive = build(x: 1200, y: 560)
        let response = try #require(positive.shots.first { $0.sustained })
        let destination = try #require(positive.shots.first { $0.actionTime == 15.5 })
        #expect(response.end < 15.5 && destination.start >= 15.5)
        #expect(destination.waypoints.first?.rect.x == 0)
        let unrelated = build(x: 700, y: 800)
        #expect(!unrelated.shots.contains { $0.actionTime == 15.5 })
    }

}
