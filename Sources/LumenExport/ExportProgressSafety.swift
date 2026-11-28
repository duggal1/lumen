import Foundation
import os

public enum ExportStage: String, Sendable, Codable {
    case preflight, decode, render, encoder, audio, finalize, validate, publish
}

public enum ExportFailureReason: String, Sendable, Codable {
    case stalled, gpuFailed, proofFailed
}

/// Additive typed error; existing ExportError callers and presets remain valid.
public struct ExportStageFailure: LocalizedError, Sendable {
    public let stage: ExportStage
    public let reason: ExportFailureReason
    public let detail: String
    public var errorDescription: String? { "Export \(stage.rawValue): \(detail)" }
}

/// A progress clock is refreshed only by advancing a real work counter.
/// Callers supply monotonic time, making the policy deterministic in tests.
struct ExportStallGuard {
    let stage: ExportStage
    let idleSeconds: Double
    private var lastProgress: Double
    private var completed: Int64 = 0

    init(stage: ExportStage, idleSeconds: Double, now: Double) {
        self.stage = stage
        self.idleSeconds = idleSeconds
        lastProgress = now
    }

    mutating func observe(progress: Int64, now: Double) throws {
        if progress > completed {
            completed = progress
            lastProgress = now
        }
        if now - lastProgress >= idleSeconds {
            throw ExportStageFailure(stage: stage, reason: .stalled,
                                     detail: "No progress for \(Int(idleSeconds)) seconds.")
        }
    }
}

/// Exactly one result wins, including cancellation and timeout. The GPU
/// completion closure continues to own its resources until Metal calls it;
/// abandoning a wait never signals a renderer slot or reuses its buffer.
final class Latch: @unchecked Sendable {
    private enum Outcome: Sendable, Equatable { case success, failed, cancelled, timeout }
    private let state = OSAllocatedUnfairLock<(outcome: Outcome?, waiter: CheckedContinuation<Outcome, Never>?)>(
        uncheckedState: (nil, nil))

    func fire(_ success: Bool) { resolve(success ? .success : .failed) }

    private func resolve(_ outcome: Outcome) {
        let waiter = state.withLock { value -> CheckedContinuation<Outcome, Never>? in
            guard value.outcome == nil else { return nil }
            value.outcome = outcome
            let waiter = value.waiter
            value.waiter = nil
            return waiter
        }
        waiter?.resume(returning: outcome)
    }

    private func result(timeout: Duration) async -> Outcome {
        if let outcome = state.withLock({ $0.outcome }) { return outcome }
        return await withTaskCancellationHandler {
            let deadline = Task { [self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                resolve(.timeout)
            }
            defer { deadline.cancel() }
            return await withCheckedContinuation { continuation in
                let ready = state.withLock { value -> Outcome? in
                    if let outcome = value.outcome { return outcome }
                    precondition(value.waiter == nil, "Completion latch has one consumer")
                    value.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            self.resolve(.cancelled)
        }
    }

    func wait() async -> Bool { await result(timeout: .seconds(30)) == .success }

    func waitChecked(stage: ExportStage, timeout: Duration = .seconds(30)) async throws {
        try Task.checkCancellation()
        let outcome = await result(timeout: timeout)
        try Task.checkCancellation()
        switch outcome {
        case .success: return
        case .cancelled: throw CancellationError()
        case .failed: throw ExportStageFailure(stage: stage, reason: .gpuFailed, detail: "GPU execution failed.")
        case .timeout: throw ExportStageFailure(stage: stage, reason: .stalled, detail: "Completion callback did not arrive before the deadline.")
        }
    }
}
