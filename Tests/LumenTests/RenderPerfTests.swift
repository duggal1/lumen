import XCTest
import Testing
@testable import LumenRender

/// Render-path benchmarks with real gates. The old file only printed a number
/// and could never fail; these assert the acceptance criteria instead.
final class RenderPerfTests: XCTestCase {
    func testBaseline1080p() throws {
        let r = try RenderBenchmark.run(frames: 120, width: 1920, height: 1080, fps: 60)
        print("BENCH-BASELINE \(r.width)x\(r.height): \(r.report.summary)")
        XCTAssertEqual(r.report.frames, 120)
        XCTAssertTrue(r.report.frames > 0)
        XCTAssertTrue(r.report.averageMs.isFinite && r.report.averageMs >= 0)
        XCTAssertTrue(r.report.worstMs >= r.report.p99Ms)
    }

    /// One minute of 60 fps click-and-zoom content through the real Metal
    /// encode path. Mirrors `lumen-cli bench --frames 3600 --clicks`.
    func testOneMinuteClickScenarioHoldsSixtyFpsGate() throws {
        let r = try RenderBenchmark.run(frames: 3600, width: 1920, height: 1080,
                                        fps: 60, clicks: true)
        print("BENCH-CLICKS \(r.width)x\(r.height): \(r.report.summary)")
        XCTAssertEqual(r.report.frames, 3600)
        XCTAssertLessThan(r.report.p99Ms, 16.6)
        XCTAssertLessThanOrEqual(r.report.worstMs, 33)
        XCTAssertEqual(r.report.overBudget, 0)
        XCTAssertTrue(r.report.passes)
    }
}

@Test func clickBudgetGateRejectsMissedDeadlines() {
    let b = FrameBudget(fps: 60)
    let good = Array(repeating: 8.0, count: 120)
    #expect(b.evaluate(good, clickScenario: true).passes)
    #expect(!b.evaluate(good + [40.0], clickScenario: true).passes)
    #expect(!b.evaluate(Array(repeating: 17.0, count: 120), clickScenario: true).passes)
    #expect(!b.evaluate(Array(repeating: .nan, count: 120), clickScenario: true).passes)
}
