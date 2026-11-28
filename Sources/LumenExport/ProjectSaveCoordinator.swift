import Foundation
import os
import LumenProject

/// An explicit write can be overtaken by a newer snapshot or external revision.
/// It must not use the new revision number to write stale data.
enum ProjectSaveOrderError: LocalizedError {
    case superseded
    var errorDescription: String? { "A newer project edit superseded this save." }
}

/// One disk writer, one latest pending snapshot, and a revision epoch.
/// The lock protects only admission and completion; file I/O never holds it.
final class ProjectSaveCoordinator<Value: Sendable>: Sendable {
    private struct Ticket: Sendable {
        let value: Value
        let epoch: UInt64
        let sequence: UInt64
    }
    private struct State: Sendable {
        var revision: Int
        var epoch: UInt64 = 0
        var sequence: UInt64 = 0
        var committed: UInt64 = 0
        var pending: Ticket?
        var scheduled = false
        var writing = false
        var blocked: ProjectError?
        var lastFailure: String?
        var onFailure: (@Sendable (Error) -> Void)?
        var onSettled: (@Sendable () -> Void)?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let queue = DispatchQueue(label: "lumen.project.save", qos: .userInitiated)
    private let delay: DispatchTimeInterval
    private let persist: @Sendable (Value, Int) throws -> Int

    init(revision: Int, delay: DispatchTimeInterval = .milliseconds(250),
         persist: @escaping @Sendable (Value, Int) throws -> Int) {
        state = OSAllocatedUnfairLock(initialState: State(revision: revision))
        self.delay = delay
        self.persist = persist
    }

    var revision: Int { state.withLock { $0.revision } }
    var isWriting: Bool { state.withLock { $0.writing } }
    var lastFailure: String? { state.withLock { $0.lastFailure } }

    func setCallbacks(onFailure: @escaping @Sendable (Error) -> Void,
                      onSettled: @escaping @Sendable () -> Void) {
        state.withLock { $0.onFailure = onFailure; $0.onSettled = onSettled }
    }

    /// External revision is adopted only after the caller applied its exact
    /// timeline. Every previously queued snapshot belongs to the old epoch.
    func adopt(revision: Int) {
        state.withLock { value in
            guard revision > value.revision else { return }
            value.revision = revision
            value.epoch &+= 1
            value.pending = nil
            value.blocked = nil
            value.lastFailure = nil
        }
    }

    func enqueue(_ value: Value) {
        let schedule = state.withLock { s -> Bool in
            s.sequence &+= 1
            s.pending = Ticket(value: value, epoch: s.epoch, sequence: s.sequence)
            guard !s.scheduled, s.blocked == nil else { return false }
            s.scheduled = true
            return true
        }
        if schedule { scheduleDrain() }
    }

    private func scheduleDrain() {
        // Retain the coordinator until its last acknowledged pending write
        // has run, even if its ProjectSession closes in the meantime.
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            let ticket = try? takePending()
            if let ticket { try? write(ticket) }
            let again = state.withLock { s -> Bool in
                s.scheduled = false
                guard s.blocked == nil, let pending = s.pending,
                      pending.sequence != ticket?.sequence else { return false }
                s.scheduled = true
                return true
            }
            if again { scheduleDrain() }
        }
    }

    private func takePending() throws -> Ticket? {
        try state.withLock { s in
            if let blocked = s.blocked { throw blocked }
            let next = s.pending
            s.pending = nil
            return next
        }
    }

    /// Explicit lifecycle barrier, serialized with the background writer.
    func flushPending() throws {
        try queue.sync {
            if let ticket = try takePending() { try write(ticket) }
        }
    }

    func saveImmediately(_ value: Value) throws {
        let ticket = try state.withLock { s -> Ticket in
            if let blocked = s.blocked { throw blocked }
            s.sequence &+= 1
            let ticket = Ticket(value: value, epoch: s.epoch, sequence: s.sequence)
            s.pending = nil
            return ticket
        }
        try queue.sync { try write(ticket) }
    }

    private func write(_ ticket: Ticket) throws {
        let expected = try state.withLock { s -> Int in
            guard ticket.epoch == s.epoch, ticket.sequence > s.committed else {
                throw ProjectSaveOrderError.superseded
            }
            if let blocked = s.blocked { throw blocked }
            s.writing = true
            return s.revision
        }
        let newRevision: Int
        do {
            newRevision = try persist(ticket.value, expected)
        } catch {
            let callbacks = state.withLock { s -> ((@Sendable (Error) -> Void)?, (@Sendable () -> Void)?) in
                s.writing = false
                guard ticket.epoch == s.epoch else { return (nil, s.onSettled) }
                if s.pending == nil || s.pending!.sequence < ticket.sequence { s.pending = ticket }
                if let projectError = error as? ProjectError,
                   case .conflict = projectError { s.blocked = projectError }
                s.lastFailure = error.localizedDescription
                return (s.onFailure, s.onSettled)
            }
            callbacks.0?(error)
            callbacks.1?()
            throw error
        }
        let result = state.withLock { s -> (Bool, (@Sendable () -> Void)?) in
            s.writing = false
            guard ticket.epoch == s.epoch else { return (false, s.onSettled) }
            s.revision = newRevision
            s.committed = ticket.sequence
            s.lastFailure = nil
            return (true, s.onSettled)
        }
        result.1?()
        if !result.0 { throw ProjectSaveOrderError.superseded }
    }
}
