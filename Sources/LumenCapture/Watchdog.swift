import Foundation
import os
import LumenCore

// MARK: - Hang record (written to hangs.json)

/// One main-thread stall. `latencyMs` is time from enqueue to run on main.
/// `stage` is the RecordingSession stage when the stall happened.
/// Value type. Owned by MainThreadWatchdog.
public struct HangRecord: Codable, Sendable, Equatable {
    public var timestamp: Double
    public var latencyMs: Double
    public var stage: String
    public init(timestamp: Double, latencyMs: Double, stage: String) {
        self.timestamp = timestamp
        self.latencyMs = latencyMs
        self.stage = stage
    }
}

// MARK: - Watchdog

/// Pings main every 10 ms from a background thread and records any latency
/// over 50 ms together with the current signpost stage. Writes hangs.json.
/// Stays in Release behind LUMEN_HANG_WATCHDOG=1. No-op when flag is off.
/// Threading: owns a background queue; main hop is one async enqueue.
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "lumen.watchdog", qos: .utility)
    private let hangs = OSAllocatedUnfairLock<[HangRecord]>(initialState: [])
    private let stage = OSAllocatedUnfairLock<String>(initialState: "idle")
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let outputURL: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        outputURL = base.appendingPathComponent("Lumen", isDirectory: true)
            .appendingPathComponent("hangs.json")
    }

    public var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LUMEN_HANG_WATCHDOG"] == "1"
    }

    /// Current stage for the next hang record. Set by RecordingSession on every transition.
    public func setStage(_ s: String) {
        stage.withLock { $0 = s }
    }

    public var currentStage: String { stage.withLock { $0 } }

    public func start() {
        guard isEnabled else { return }
        let already = running.withLock { r -> Bool in if r { return true }; r = true; return false }
        guard !already else { return }
        queue.async { [weak self] in self?.loop() }
    }

    public func stop() {
        running.withLock { $0 = false }
        flush()
    }

    public func flush() {
        let records = hangs.withLock { $0 }
        guard !records.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(records)
            try data.write(to: outputURL, options: .atomic)
        } catch {
            os_log("watchdog flush failed: %@", log: .default, type: .error, String(describing: error))
        }
    }

    /// Synchronous snapshot for tests / CLI.
    public func snapshot() -> [HangRecord] { hangs.withLock { $0 } }

    /// Test hook: record a synthetic hang.
    func record(latencyMs: Double, stage: String) {
        hangs.withLock { $0.append(HangRecord(timestamp: HostClock.now(), latencyMs: latencyMs, stage: stage)) }
    }

    private func loop() {
        while running.withLock({ $0 }) {
            let enqueued = HostClock.now()
            let current = stage.withLock { $0 }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let ran = HostClock.now()
                let latency = (ran - enqueued) * 1000
                if latency > 50 {
                    self.record(latencyMs: latency, stage: current)
                    os_log("main stall %.1f ms in stage %@", log: .default, type: .fault, latency, current)
                    self.flush()
                }
            }
            Thread.sleep(forTimeInterval: 0.010)
        }
    }
}
