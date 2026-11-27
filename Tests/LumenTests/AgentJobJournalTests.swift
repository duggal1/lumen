import Foundation
import Testing
@testable import LumenControl

@Test func agentJournalRestoresInterruptedCheckpointWithoutReplayingWork() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = "job_" + UUID().uuidString.lowercased()
    let now = Date().timeIntervalSince1970
    do {
        let journal = try AgentJobJournal(directory: root)
        let job = JobManager.Job(id: id, kind: "produce_demo", state: .running, progress: 0.75,
            message: "editing", result: .object(["project_path": .string("/fixture/project.lumen")]),
            error: nil, created: now, updated: now)
        try journal.write(job)
    }
    let restarted = JobManager(journalDirectory: root)
    let job = try #require(restarted.job(id))
    #expect(job.state == .failed)
    #expect(job.error?.contains("JOB_INTERRUPTED") == true)
    #expect(job.result?["project_path"]?.stringValue == "/fixture/project.lumen")
}

@Test func agentJournalRejectsConcurrentWriter() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = try AgentJobJournal(directory: root)
    #expect(throws: ToolError.self) { _ = try AgentJobJournal(directory: root) }
    withExtendedLifetime(owner) {}
}

@Test func agentJournalPreservesCompletedReceipt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let jobs = JobManager(journalDirectory: root)
    let id = jobs.start(kind: "export") { reporter in
        try reporter.checkpoint(.object(["stage": .string("verified")]))
        return .object(["output": .string("/fixture/movie.mp4")])
    }
    let job = try await jobs.waitForCompletion(id)
    #expect(job.state == .done)
    let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(id + ".json"))) as? [String: Any]
    let persisted = receipt?["job"] as? [String: Any]
    #expect(persisted?["state"] as? String == "done")
}
