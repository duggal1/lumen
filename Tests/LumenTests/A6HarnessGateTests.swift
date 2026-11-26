import Testing
@testable import LumenRender

/// A6 — harness gates. The live harness (RenderBenchmark) needs a GPU, so the
/// pass/fail policy itself is covered here: FrameBudget turns samples into
/// pass/fail decisions with the cadence (p99 ≤ deadline) and over-budget
/// fraction gates the real 60 fps path must satisfy.
@Suite struct A6HarnessGateTests {
    @Test func constantCadenceAt60fpsPasses() {
        let budget = FrameBudget(fps: 60)
        var samples: [Double] = []
        for i in 0..<600 {
            samples.append(1000.0 / 60.0 + 0.04 * Double((i % 5) - 2) / 2)
        }
        let r = budget.evaluate(samples)
        #expect(r.frames == 600, "\(r.summary)")
        #expect(r.passes, "\(r.summary)")
        #expect(r.overBudget == 0, "\(r.summary)")
    }

    @Test func allOverBudgetFails() {
        let budget = FrameBudget(fps: 60)
        let r = budget.evaluate((0..<600).map { _ in 25.0 }) // > 16.67 ms budget
        #expect(!r.passes, "\(r.summary)")
    }

    @Test func sporadicBadFramesFailP99Gate() {
        let budget = FrameBudget(fps: 60)
        var samples: [Double] = (0..<600).map { _ in 1000.0 / 60.0 }
        // 12 frames at 30 ms sit above the p99 index; the rest are on cadence.
        for i in 480..<492 { samples[i] = 30.0 }
        for i in 540..<552 { samples[i] = 30.0 }
        let r = budget.evaluate(samples)
        #expect(!r.passes, "\(r.summary)")
        #expect(r.worstMs == 30, "\(r.summary)")
    }

    @Test func onCadencePassesSporadicTinyJitter() {
        let budget = FrameBudget(fps: 60)
        var samples: [Double] = (0..<600).map { _ in 1000.0 / 60.0 }
        for i in 300..<305 { samples[i] += 0.01 } // +0.01 ms, well inside the allowance
        let r = budget.evaluate(samples)
        #expect(r.passes, "\(r.summary)")
    }

    @Test func emptySamplesReportNoFrames() {
        let r = FrameBudget(fps: 60).evaluate([])
        #expect(!r.passes)
        #expect(r.frames == 0)
        #expect(r.summary.contains("frames measured"))
    }

    @Test func budgetMillisecondsFollowFps() {
        #expect(abs(FrameBudget(fps: 60).budgetMilliseconds - 1000 / 60) < 1e-9)
        #expect(FrameBudget(fps: 30).budgetMilliseconds == 1000.0 / 30.0)
    }
}
