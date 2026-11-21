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

/// P3: crystal-clear upscaling must not buy quality with frame time. The
/// sharpness/SSIM side is covered by UpscalerSharpnessFieldTests; this measures
/// the cost of engaging the same scaler in the shared render path.
final class UpscaleCostTests: XCTestCase {
    func testUpscalerStaysInsideFrameBudget() throws {
        let on = try RenderBenchmark.run(frames: 240, width: 1920, height: 1080,
                                         fps: 60, upscale: true)
        let off = try RenderBenchmark.run(frames: 240, width: 1920, height: 1080,
                                          fps: 60, upscale: false)
        let delta = on.report.averageMs - off.report.averageMs
        print("UPSCALE-COST on=\(String(format: "%.2f", on.report.averageMs)) off=\(String(format: "%.2f", off.report.averageMs)) delta=\(String(format: "%.2f", delta)) ms")
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
