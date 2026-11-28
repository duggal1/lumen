import Testing
@testable import LumenExport

@Test func gpuLatchPreservesFailureBeforeAndAfterWait() async {
    let first = Latch()
    first.fire(false)
    first.fire(true)
    #expect(await first.wait() == false)
    let second = Latch()
    let waiter = Task { await second.wait() }
    second.fire(true)
    #expect(await waiter.value)
}

@Test func exportProgressGuardDoesNotRenewOnDuplicateOrRegressiveCounter() throws {
    var guardClock = ExportStallGuard(stage: .encoder, idleSeconds: 10, now: 100)
    try guardClock.observe(progress: 1, now: 109)
    try guardClock.observe(progress: 1, now: 118)
    #expect(throws: ExportStageFailure.self) {
        try guardClock.observe(progress: 0, now: 119)
    }
}

@Test func exportProgressGuardAllowsLongAdvancingWork() throws {
    var guardClock = ExportStallGuard(stage: .audio, idleSeconds: 10, now: 0)
    for i in 1...100 {
        try guardClock.observe(progress: Int64(i * 480), now: Double(i * 9))
    }
}

@Test func gpuLatchTimesOutAndIgnoresLateCompletion() async {
    let latch = Latch()
    do {
        try await latch.waitChecked(stage: .render, timeout: .milliseconds(5))
        Issue.record("An absent GPU callback was accepted.")
    } catch let failure as ExportStageFailure {
        #expect(failure.stage == .render)
        #expect(failure.reason == .stalled)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    latch.fire(true)
    #expect(await latch.wait() == false)
}

@Test func gpuLatchCancellationDoesNotWaitForCallback() async {
    let latch = Latch()
    let waiter = Task { try await latch.waitChecked(stage: .render, timeout: .seconds(30)) }
    waiter.cancel()
    do {
        try await waiter.value
        Issue.record("Cancelled export reported success.")
    } catch is CancellationError {
        // Cancellation is terminal, not an encoder retry.
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
    latch.fire(false)
}
