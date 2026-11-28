import Foundation
import os
import Testing
import LumenProject
@testable import LumenExport

private final class SaveDiskFixture: Sendable {
    private struct State: Sendable {
        var revision: Int
        var values: [Int] = []
        var fail = false
    }
    private let state: OSAllocatedUnfairLock<State>
    init(revision: Int) { state = OSAllocatedUnfairLock(initialState: State(revision: revision)) }
    var values: [Int] { state.withLock { $0.values } }
    func setFailure(_ fail: Bool) { state.withLock { $0.fail = fail } }
    func externalWrite(revision: Int) { state.withLock { $0.revision = revision } }
    func write(_ value: Int, expected: Int) throws -> Int {
        try state.withLock { s in
            guard expected == s.revision else { throw ProjectError.conflict(expected: expected, actual: s.revision) }
            if s.fail { throw CocoaError(.fileWriteOutOfSpace) }
            s.values.append(value)
            s.revision += 1
            return s.revision
        }
    }
}

@Test func projectSaveCoordinatorKeepsOnlyLatestPendingSnapshot() throws {
    let disk = SaveDiskFixture(revision: 5)
    let saves = ProjectSaveCoordinator<Int>(revision: 5, delay: .seconds(10)) { try disk.write($0, expected: $1) }
    for i in 1...1000 { saves.enqueue(i) }
    try saves.flushPending()
    #expect(disk.values == [1000])
    #expect(saves.revision == 6)
}

@Test func projectSaveCoordinatorNeverRebasesStalePendingEditOntoAgentRevision() throws {
    let disk = SaveDiskFixture(revision: 1)
    let saves = ProjectSaveCoordinator<Int>(revision: 1, delay: .seconds(10)) { try disk.write($0, expected: $1) }
    saves.enqueue(10)
    disk.externalWrite(revision: 2)
    do {
        try saves.flushPending()
        Issue.record("Stale snapshot overwrote an external project.")
    } catch ProjectError.conflict(let expected, let actual) {
        #expect(expected == 1)
        #expect(actual == 2)
    }
    #expect(disk.values.isEmpty)
    #expect(saves.lastFailure != nil)
    saves.enqueue(11)
    saves.adopt(revision: 2)
    try saves.flushPending()
    #expect(disk.values.isEmpty)
    saves.enqueue(20)
    try saves.flushPending()
    #expect(disk.values == [20])
    #expect(saves.revision == 3)
}

@Test func projectSaveCoordinatorRetainsFailedDirtySnapshotForExplicitRetry() throws {
    let disk = SaveDiskFixture(revision: 0)
    let saves = ProjectSaveCoordinator<Int>(revision: 0, delay: .seconds(10)) { try disk.write($0, expected: $1) }
    disk.setFailure(true)
    saves.enqueue(7)
    #expect(throws: CocoaError.self) { try saves.flushPending() }
    #expect(saves.revision == 0)
    #expect(saves.lastFailure != nil)
    disk.setFailure(false)
    try saves.flushPending()
    #expect(disk.values == [7])
    #expect(saves.lastFailure == nil)
    saves.enqueue(8)
    try saves.saveImmediately(9)
    try saves.flushPending()
    #expect(disk.values == [7, 9])
}
