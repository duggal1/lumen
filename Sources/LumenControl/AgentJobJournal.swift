import Foundation
import Darwin

/// Single-writer, process-restart journal for demo/export jobs.
final class AgentJobJournal: Sendable {
    private let directory: URL
    private let lockFD: Int32
    private struct Record: Codable {
        let version: Int
        let job: JobManager.Job
    }
    static func isDurable(_ kind: String) -> Bool { kind == "produce_demo" || kind == "export" }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fd = Darwin.open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw ToolError(code: "JOB_JOURNAL_BUSY", hint: "Another Lumen process owns the job journal.")
        }
        lockFD = fd
    }

    deinit { Darwin.close(lockFD) }

    private func path(_ id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathExtension("json")
    }

    func write(_ job: JobManager.Job) throws {
        guard Self.isDurable(job.kind), job.id.range(of: "^job_[a-f0-9-]+$", options: .regularExpression) != nil else {
            throw ToolError.invalidArguments("Invalid durable job identity.")
        }
        let data = try JSONEncoder().encode(Record(version: 1, job: job))
        try data.write(to: path(job.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path(job.id).path)
    }

    func restore() throws -> [JobManager.Job] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let now = Date().timeIntervalSince1970
        var recovered: [JobManager.Job] = []
        for file in files where file.pathExtension == "json" {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
            guard record.version == 1, Self.isDurable(record.job.kind), path(record.job.id).path == file.path else {
                throw ToolError(code: "JOB_JOURNAL_INVALID", hint: "Unsupported or mismatched job receipt.")
            }
            var job = record.job
            if job.state == .queued || job.state == .running {
                job.state = .failed
                job.error = "JOB_INTERRUPTED: Lumen restarted. Inspect the saved project and output before retrying; never replay capture blindly."
                job.updated = now
                try write(job)
            }
            if now - job.updated > 7 * 86400 {
                try FileManager.default.removeItem(at: file)
            } else {
                recovered.append(job)
            }
        }
        return recovered.sorted { $0.created < $1.created }
    }
}
