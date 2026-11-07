import Foundation

/// Global gate: analysis and export pause while any recording is active.
/// Owned by RecordingSession; read by AnalysisService at .utility QoS.
public enum RecordingGate: @unchecked Sendable {
    private static let lock = NSLock()
    private static var count = 0
    public static var isRecordingActive: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
    public static func recordingStarted() { lock.lock(); defer { lock.unlock() }; count += 1 }
    public static func recordingStopped() { lock.lock(); defer { lock.unlock() }; count = max(count - 1, 0) }
}
