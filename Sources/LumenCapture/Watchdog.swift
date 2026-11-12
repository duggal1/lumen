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
/// Enabled in release so a recording stall can be diagnosed after force quit.
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

    /// The stall recorder stays on: it is the only way a hang the user cannot
    /// reproduce leaves evidence behind. It costs one empty main-queue block
    /// every 50 ms.
    public var isEnabled: Bool {
        ProcessInfo.processInfo.environment["LUMEN_HANG_WATCHDOG"] != "0"
    }

    /// Stack sampling is NOT free. `sample` suspends every thread of this
    /// process thousands of times a second, so running it against a live
    /// recording turns a 250 ms hiccup into a multi-second freeze — and the
    /// freeze it causes can trigger another sample. It stays off unless a
    /// developer asks for it explicitly.
    public var isSamplingEnabled: Bool {
        ProcessInfo.processInfo.environment["LUMEN_HANG_SAMPLE"] == "1"
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
        hangs.withLock { records in
            // Bounded: a long recording with a wedged main thread must not
            // grow this array without limit.
            records.append(HangRecord(timestamp: HostClock.now(), latencyMs: latencyMs, stage: stage))
            if records.count > 200 { records.removeFirst(records.count - 200) }
        }
    }

    private func loop() {
        while running.withLock({ $0 }) {
            let enqueued = HostClock.now(), current = currentStage
            let reply = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { reply.signal() }
            if reply.wait(timeout: .now() + 0.25) == .timedOut {
                record(latencyMs: (HostClock.now() - enqueued) * 1000, stage: current)
                flush()
                if isSamplingEnabled { sampleStack(stage: current) }
                // Wait for main to come back, but bounded: the watchdog is a
                // reporter, never a reason the app stays stuck.
                let deadline = Date().addingTimeInterval(2)
                while running.withLock({ $0 }), Date() < deadline,
                      reply.wait(timeout: .now() + 0.05) == .timedOut {}
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Developer-only: dump this process's stacks to a file. Never runs during
    /// a normal recording (see `isSamplingEnabled`).
    private func sampleStack(stage: String) {
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let name = "stall-" + String(Int(Date().timeIntervalSince1970)) + ".txt"
        let stack = outputURL.deletingLastPathComponent().appendingPathComponent(name)
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [String(ProcessInfo.processInfo.processIdentifier), "1", "1", "-file", stack.path]
        sample.standardOutput = FileHandle.nullDevice; sample.standardError = FileHandle.nullDevice
        try? sample.run()
        os_log("main stalled in %@; stack sample: %@", log: .default, type: .fault, stage, stack.path)
    }
}
