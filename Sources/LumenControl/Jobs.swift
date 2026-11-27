import Foundation
import os

/// Long work (export, privacy scan, record finalize) runs as a job with an id,
/// progress and a cancel switch. Never on the main actor.
public final class JobManager: @unchecked Sendable {
    public enum State: String, Sendable, Codable {
        case queued, running, done, failed, cancelled
    }

    public struct Job: Sendable, Codable {
        public var id: String
        public var kind: String
        public var state: State
        public var progress: Double
        public var message: String?
        public var result: JSONValue?
        public var error: String?
        public var created: Double
        public var updated: Double
    }

    /// Progress notifications for the MCP client.
    public struct Event: Sendable {
        public let jobID: String
        public let progress: Double
        public let message: String?
    }

    private let state = OSAllocatedUnfairLock<Store>(initialState: Store())
    struct Store {
        var jobs: [String: Job] = [:]
        var order: [String] = []
        var tasks: [String: Task<Void, Never>] = [:]
        var listeners: [String: @Sendable (Event) -> Void] = [:]
    }

    public init() {}

    public func subscribe(jobID: String, _ listener: @escaping @Sendable (Event) -> Void) {
        state.withLock { $0.listeners[jobID] = listener }
    }

    public func job(_ id: String) -> Job? {
        state.withLock { $0.jobs[id] }
    }

    public func recentJobs() -> [Job] {
        state.withLock { s in s.order.compactMap { s.jobs[$0] } }
    }

    /// Waits for a terminal job state while forwarding changed progress.
    // AGENT: wait=true needs one cancellable request that follows the job instead of returning a poll id.
    public func waitForCompletion(_ id: String,
                                  progress: (@Sendable (Double, String?) -> Void)? = nil) async throws -> Job {
        var previousProgress: Double?
        var previousMessage: String?
        do {
            while true {
                try Task.checkCancellation()
                guard let current = job(id) else {
                    throw ToolError.failed("No job with id \(id).")
                }
                if current.progress != previousProgress || current.message != previousMessage {
                    progress?(current.progress, current.message)
                    previousProgress = current.progress
                    previousMessage = current.message
                }
                switch current.state {
                case .done:
                    return current
                case .failed:
                    throw ToolError(code: "JOB_FAILED", hint: current.error ?? "The job failed. Read job_status for details.")
                case .cancelled:
                    throw ToolError(code: "JOB_CANCELLED", hint: "The job was cancelled.")
                case .queued, .running:
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
        } catch is CancellationError {
            _ = cancel(id)
            throw CancellationError()
        }
    }

    public func cancel(_ id: String) -> Bool {
        let task = state.withLock { $0.tasks[id] }
        task?.cancel()
        update(id) { job in
            if job.state == .queued || job.state == .running { job.state = .cancelled; job.updated = Date().timeIntervalSince1970 }
        }
        return task != nil
    }

    /// Starts a job. The body reports progress; it is never run on main.
    @discardableResult
    public func start(kind: String, _ body: @escaping @Sendable (JobReporter) async throws -> JSONValue) -> String {
        let id = "job_" + UUID().uuidString.prefix(8).lowercased()
        let job = Job(id: id, kind: kind, state: .queued, progress: 0, message: nil, result: nil, error: nil,
                      created: Date().timeIntervalSince1970, updated: Date().timeIntervalSince1970)
        // AGENT: install the task while holding the store lock so fast completion cannot leave a stale handle.
        state.withLock { s in
            let cutoff = Date().timeIntervalSince1970 - 3600
            let finished = s.order.filter { key in
                guard let old = s.jobs[key] else { return true }
                return old.state != .queued && old.state != .running && old.updated < cutoff
            }
            for key in finished { s.jobs[key] = nil; s.listeners[key] = nil }
            s.order.removeAll { s.jobs[$0] == nil }
            while s.order.count >= 200, let index = s.order.firstIndex(where: { s.tasks[$0] == nil }) {
                let key = s.order.remove(at: index); s.jobs[key] = nil; s.listeners[key] = nil
            }
            s.jobs[id] = job; s.order.append(id)
            let task = Task { [weak self] in
            guard let self else { return }
            let reporter = JobReporter(jobID: id, report: { [weak self] progress, message in
                self?.progress(id, progress, message)
            }, saveCheckpoint: { [weak self] checkpoint in
                self?.update(id) { $0.result = checkpoint }
            })
            do {
                try Task.checkCancellation()
                self.update(id) { j in if j.state == .queued { j.state = .running } }
                let result = try await body(reporter)
                if Task.isCancelled {
                    self.update(id) { $0.state = .cancelled }
                } else {
                    self.update(id) { j in
                        j.state = .done; j.progress = 1; j.result = result; j.updated = Date().timeIntervalSince1970
                    }
                }
            } catch {
                self.update(id) { j in
                    j.state = Task.isCancelled ? .cancelled : .failed
                    j.error = (error as? ToolError).map { "\($0.code): \($0.hint)" } ?? error.localizedDescription
                    j.updated = Date().timeIntervalSince1970
                }
            }
            self.state.withLock { $0.tasks[id] = nil; $0.listeners[id] = nil }
            }
            s.tasks[id] = task
        }
        return id
    }

    private func progress(_ id: String, _ value: Double, _ message: String?) {
        guard value.isFinite else { return }
        update(id) { j in j.progress = max(j.progress, min(max(value, 0), 1)); j.message = message; j.updated = Date().timeIntervalSince1970 }
        let listener = state.withLock { $0.listeners[id] }
        listener?(Event(jobID: id, progress: value, message: message))
    }

    private func update(_ id: String, _ body: @Sendable (inout Job) -> Void) {
        state.withLock { s in
            guard var job = s.jobs[id] else { return }
            // Terminal states are immutable. Late progress or a worker that ignores
            // cancellation must not resurrect a cancelled job.
            guard job.state == .queued || job.state == .running else { return }
            body(&job)
            s.jobs[id] = job
        }
    }
}

/// Progress handle handed to a job body.
public struct JobReporter: Sendable {
    public let jobID: String
    let report: @Sendable (Double, String?) -> Void
    let saveCheckpoint: @Sendable (JSONValue) -> Void
    public func checkpoint(_ value: JSONValue) { saveCheckpoint(value) }
    public func progress(_ value: Double, _ message: String? = nil) { report(value, message) }
}

extension JobManager.Job {
    // AGENT: waited long-running tools return the same stable job envelope as job_status.
    var jsonValue: JSONValue {
        .object(["job_id": .string(id), "kind": .string(kind), "state": .string(state.rawValue),
                 "progress": .number(progress), "message": message.map(JSONValue.string) ?? .null,
                 "result": result ?? .null, "error": error.map(JSONValue.string) ?? .null])
    }
}
