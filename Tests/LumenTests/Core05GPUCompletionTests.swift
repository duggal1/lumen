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
