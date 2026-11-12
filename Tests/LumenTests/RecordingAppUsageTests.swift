import Foundation
import Testing
@testable import LumenUI

@Test func appUsageTracksSwitchesAndExcludesPausedTime() {
    var usage = AppUsageAccumulator()
    usage.activate(id: "app.one", name: "One", at: 10)
    usage.activate(id: "app.two", name: "Two", at: 15)
    usage.pause(at: 18)
    usage.activate(id: "app.one", name: "One", at: 25)
    usage.finish(at: 27)
    #expect(usage.totals["app.one"]?.seconds == 7)
    #expect(usage.totals["app.two"]?.seconds == 3)
}

@Test func appUsageIgnoresUnknownAppsAndBackwardsTime() {
    var usage = AppUsageAccumulator()
    usage.activate(id: "app.one", name: "One", at: 10)
    usage.pause(at: 9)
    usage.activate(id: "", name: "", at: 11)
    usage.finish(at: 12)
    #expect(usage.totals["app.one"] == nil)
    #expect(usage.totals.isEmpty)
}

@Test func appUsageGroupsRecordingsAndRespectsDateRange() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let one = RecordedAppUsage(id: "app.one", name: "One", seconds: 12)
    let two = RecordedAppUsage(id: "app.two", name: "Two", seconds: 8)
    let entries = [(date: now, apps: [one, two]),
                   (date: now.addingTimeInterval(-20 * 86_400), apps: [one])]
    let recent = AppUsageSummary.aggregate(entries, since: now.addingTimeInterval(-7 * 86_400))
    let all = AppUsageSummary.aggregate(entries, since: nil)
    #expect(recent.map(\.seconds) == [12, 8])
    #expect(all.map(\.seconds) == [24, 8])
}
