import Testing
@testable import LumenUI

@Test func studioWheelSpringSettlesExactlyAtBothRefreshRates() {
    for fps in [60.0, 90.0, 120.0] {
        var spring = StudioWheelSpring()
        spring.add(120)
        var total = 0.0
        for _ in 0..<Int(fps) {
            let dx = spring.advance(dt: 1 / fps)
            #expect(dx >= 0)
            total += dx
            #expect(total <= 120.000001)
        }
        #expect(spring.isIdle)
        #expect(abs(total - 120) < 1e-8)
        #expect(spring.advance(dt: 1 / fps) == 0)
    }
}

@Test func studioWheelSpringCanReverseWithoutOvershootOrTrailingQueue() {
    var spring = StudioWheelSpring()
    spring.add(100)
    _ = spring.advance(dt: 1 / 60.0)
    spring.add(-240)
    let target = spring.remaining
    var delivered = 0.0
    for _ in 0..<120 {
        let dx = spring.advance(dt: 1 / 90.0)
        #expect(dx <= 0)
        delivered += dx
    }
    #expect(spring.isIdle)
    #expect(abs(delivered - target) < 1e-8)
    spring.add(.nan)
    #expect(spring.isIdle)
}

@Test func studioDisplayRateRespectsPhysicalPanel() {
    #expect(StudioDisplayRate.range(screenMaximum: 60).preferred == 60)
    #expect(StudioDisplayRate.range(screenMaximum: 90).preferred == 90)
    #expect(StudioDisplayRate.range(screenMaximum: 120).maximum == 90)
    #expect(StudioDisplayRate.range(screenMaximum: 30).minimum == 30)
}

@MainActor
@Test func studioEventIndexReusesSnapshotAndMatchesVisibleRanges() {
    let index = StudioTimelineEventIndex()
    var builds = 0
    let build = {
        builds += 1
        return StudioTimelineEventIndex.Snapshot(
            markers: (0..<10_000).reversed().map { .init(t: Double($0) / 10, kind: "Click", isTap: false) },
            keys: [0, 0.2, 0.4, 2, 2.2, 8, .nan])
    }
    let first = index.snapshot(revision: 1, build: build)
    for i in 0..<100 {
        let value = index.snapshot(revision: 1, build: build)
        let lo = Double(i) * 0.2, hi = lo + 1
        #expect(Array(value.visibleMarkers(from: lo, through: hi)) == first.markers.filter { $0.t >= lo && $0.t <= hi })
    }
    #expect(builds == 1)
    #expect(first.visibleBursts(from: 0.3, through: 2.1).count == 2)
    #expect(first.visibleMarkers(from: .nan, through: 2).isEmpty)
    _ = index.snapshot(revision: 2, build: build)
    #expect(builds == 2)
}
