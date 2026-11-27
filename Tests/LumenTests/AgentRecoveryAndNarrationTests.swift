import Foundation
import Testing
@testable import LumenControl

private struct InvalidNarrationProvider: VoiceProvider {
    func generate(text: String, voice: String, model: String) async throws -> (data: Data, disclosure: String) {
        (Data("not audio".utf8), "test fixture")
    }
}

@Test func invalidNarrationNeverLeavesAProjectAsset() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        _ = try await NarrationAsset.generate(in: root, text: "Hello", provider: InvalidNarrationProvider())
        Issue.record("Invalid audio was accepted.")
    } catch {
        let directory = root.appendingPathComponent("assets")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.isEmpty)
    }
}

@Test func failedAgentJobRetainsRecoverableCheckpoint() async throws {
    let jobs = JobManager()
    let id = jobs.start(kind: "test") { reporter in
        reporter.checkpoint(.object(["project_path": .string("/fixture/recording.lumen")]))
        throw ToolError(code: "FIXTURE_FAILED", hint: "Recover this project.")
    }
    do {
        _ = try await jobs.waitForCompletion(id)
        Issue.record("Expected failure.")
    } catch {
        let job = try #require(jobs.job(id))
        #expect(job.state == .failed)
        #expect(job.result?["project_path"]?.stringValue == "/fixture/recording.lumen")
        #expect(job.error?.contains("FIXTURE_FAILED") == true)
    }
}

@Test func encodedExportProofRejectsInvalidMovie() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("not a movie".utf8).write(to: url)
    do {
        _ = try await AgentExportProof.verify(url, expectedDuration: 1, fps: 30, expectsAudio: false)
        Issue.record("Invalid movie was accepted.")
    } catch {
        // Rejected either by AVFoundation or the explicit verification gate.
    }
}

@Test func agentExportPublishesStemsUnderTheFinalNameAndRollsBackOnCollision() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let staging = root.appendingPathComponent("stage", isDirectory: true)
    try files.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }

    let output = root.appendingPathComponent("demo.mp4")
    let stagedMovie = staging.appendingPathComponent(output.lastPathComponent)
    let stem = root.appendingPathComponent("demo-voiceover-1.wav")
    let stagedStem = staging.appendingPathComponent(stem.lastPathComponent)
    let original = Data("existing movie".utf8)
    let movie = Data("staged movie".utf8)
    let audio = Data("staged audio".utf8)
    try original.write(to: output)
    try movie.write(to: stagedMovie)
    try audio.write(to: stagedStem)
    #expect(throws: ToolError.self) {
        try AgentExportProof.publish(stagedMovie, to: output, overwrite: false)
    }
    #expect(try Data(contentsOf: output) == original)
    #expect(!files.fileExists(atPath: stem.path))

    try audio.write(to: stagedStem)
    #expect(try AgentExportProof.publish(stagedMovie, to: output, overwrite: true) == [stem])
    #expect(try Data(contentsOf: output) == movie)
    #expect(try Data(contentsOf: stem) == audio)
}
