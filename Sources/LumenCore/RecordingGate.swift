import Foundation
import Synchronization

/// Global gate: analysis and export pause while any recording is active.
/// Owned by RecordingSession; read by AnalysisService at .utility QoS.
public enum RecordingGate: @unchecked Sendable {
    private static let count = OSAllocatedUnfairLock(initialState: 0)
    public static var isRecordingActive: Bool { count.withLock { $0 } > 0 }
    public static func recordingStarted() { count.withLock { $0 += 1 } }
    public static func recordingStopped() { count.withLock { $0 = max($0 - 1, 0) } }
}
