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
        let result = try RenderBenchmark.run(frames: 3600, width: 1920, height: 1080,
                                             fps: 60, clicks: true)
        print("BENCH-CLICKS \(result.width)x\(result.height): \(result.report.summary)")
        XCTAssertEqual(result.report.frames, 3600)
        XCTAssertLessThan(result.report.p99Ms, 16.6)
        XCTAssertLessThanOrEqual(result.report.worstMs, FrameBudget(fps: 60).budgetMilliseconds * 3)
        XCTAssertTrue(result.report.passes)
    }
}

/// P3: crystal-clear upscaling must not buy quality with frame time. The
/// sharpness/SSIM side is covered by UpscalerSharpnessFieldTests; this measures
/// the cost of engaging the same scaler in the shared render path.
final class UpscaleCostTests: XCTestCase {
    func testUpscalerStaysInsideFrameBudget() throws {
        let on = try RenderBenchmark.run(frames: 240, width: 1920, height: 1080,
                                         fps: 60, upscale: true)
        let off = try RenderBenchmark.run(frames: 240, width: 1920, height: 1080,
                                          fps: 60, upscale: false)
        // Median frame cost, not the mean: a shared CI runner can preempt the
        // thread for a few frames, and those host stalls would otherwise swamp
        // the sub-millisecond difference this gate is measuring.
        let delta = on.report.p50Ms - off.report.p50Ms
        print("UPSCALE-COST on=\(String(format: "%.2f", on.report.p50Ms)) off=\(String(format: "%.2f", off.report.p50Ms)) delta=\(String(format: "%.2f", delta)) ms (median)")
        XCTAssertTrue(on.report.passes)
        XCTAssertLessThan(delta, 1.0, "upscaler cost \(delta) ms per frame")
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

@Test func clickBudgetIsRateSpecific() {
    let b90 = FrameBudget(fps: 90)
    let b30 = FrameBudget(fps: 30)
    #expect(b90.evaluate([10, 11], clickScenario: true).passes)
    #expect(!b90.evaluate([10, 12], clickScenario: true).passes)
    #expect(b30.evaluate([20, 30], clickScenario: true).passes)
    #expect(!b30.evaluate([20, 34], clickScenario: true).passes)
    #expect(FrameBudget(fps: .nan).budgetMilliseconds.isFinite)
}
