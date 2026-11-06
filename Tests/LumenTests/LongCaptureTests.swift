import Foundation
import Testing
import Darwin
import LumenCore
import LumenProject
@testable import LumenDirector

/// Long-capture / memory entry point. Synthetic 10-minute session at 60 fps:
/// 12k pointer events and 100 clicks. This is the CI-sized version of a real
/// hour-long capture; failures mean derive leaks or an unbounded track.
@Test func longCaptureStaysWithinTimeAndMemoryBudget() {
    let duration = 600.0
    let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: duration,
                            backingScale: 1, originX: 0, originY: 0)
    var events: [InputEvent] = []
    events.reserveCapacity(12_100)
    for i in 0..<12_000 {
        let t = Double(i) * (duration / 12_000)
        events.append(InputEvent(t: t, kind: .move,
                                 x: Float(200 + (i * 37) % 1500),
                                 y: Float(200 + (i * 53) % 700)))
        if i % 120 == 0 {
            events.append(InputEvent(t: t, kind: .down,
                                     x: Float(200 + (i * 37) % 1500),
                                     y: Float(200 + (i * 53) % 700)))
        }
    }
    var timeline = Timeline(duration: duration)
    timeline.audio.speedRampsAuto = false

    let before = residentMegabytes()
    let start = Date()
    let out = Director.derive(timeline, input: DirectorInput(events: events, source: source), revision: 1)
    let elapsed = Date().timeIntervalSince(start)
    let growth = residentMegabytes() - before

    #expect(out.derived != nil)
    #expect((out.derived?.cursor.x.count ?? 0) > 800_000, "the full 10 minutes must be derived")
    #expect(elapsed < 20, "derive took \(elapsed)s for 10 minutes of events")
    #expect(growth < 512, "derive grew resident memory by \(growth) MB")
    #expect(residentMegabytes() < 4_096, "resident memory exceeded the 4 GB ceiling")
}

/// Live GPU gate used by `lumen-cli bench`; the same budget policy is unit
/// tested separately so CI can run without a Metal device.
@Test func renderBenchmarkEnforcesTheFrameBudgetPolicy() {
    let result = FrameBudget(fps: 120).evaluate(Array(repeating: 8.5, count: 20))
    #expect(result.passes, "8.5 ms frames fit a 120 fps budget")

    let over = FrameBudget(fps: 120).evaluate(Array(repeating: 12.0, count: 20))
    #expect(!over.passes)
    #expect(over.overBudget == 20)
}

private func residentMegabytes() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}
