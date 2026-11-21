import XCTest
@testable import LumenRender

/// TEMPORARY (subagent-2-lag): baseline render-path measurement via the real
/// Metal encode path. Not part of the suite's assertions.
final class RenderPerfTests: XCTestCase {
    func testBaseline1080p() throws {
        let r = try RenderBenchmark.run(frames: 120, width: 1920, height: 1080, fps: 60)
        print("BENCH-BASELINE \(r.width)x\(r.height): \(r.report.summary)")
    }
}
