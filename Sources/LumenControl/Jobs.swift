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
        state.withLock { s in s.jobs[id] = job; s.order.append(id) }
        let task = Task { [weak self] in
            guard let self else { return }
            self.update(id) { j in j.state = .running }
            let reporter = JobReporter(jobID: id) { [weak self] progress, message in
                self?.progress(id, progress, message)
            }
            do {
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
                    j.error = String(describing: error)
                    j.updated = Date().timeIntervalSince1970
                }
            }
            self.state.withLock { $0.tasks[id] = nil }
        }
        state.withLock { $0.tasks[id] = task }
        return id
    }

    private func progress(_ id: String, _ value: Double, _ message: String?) {
        update(id) { j in j.progress = min(max(value, 0), 1); j.message = message; j.updated = Date().timeIntervalSince1970 }
        let listener = state.withLock { $0.listeners[id] }
        listener?(Event(jobID: id, progress: value, message: message))
    }

    private func update(_ id: String, _ body: @Sendable (inout Job) -> Void) {
        state.withLock { s in
            guard var job = s.jobs[id] else { return }
            body(&job)
            s.jobs[id] = job
        }
    }
}

/// Progress handle handed to a job body.
public struct JobReporter: Sendable {
    public let jobID: String
    let report: @Sendable (Double, String?) -> Void
    public func progress(_ value: Double, _ message: String? = nil) { report(value, message) }
}
