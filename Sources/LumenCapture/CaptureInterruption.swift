import Foundation

/// Persist only the typed cause and OS error code; no window titles, paths,
/// captured text or raw NSError descriptions belong in a diagnostic receipt.
public struct CaptureInterruption: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case streamStopped, sleep, termination, diskPressure
        public var userDescription: String {
            switch self {
            case .streamStopped: "screen capture stopped"
            case .sleep: "Mac went to sleep"
            case .termination: "application is closing"
            case .diskPressure: "available storage is low"
            }
        }
    }
    public let kind: Kind
    public let domain: String?
    public let code: Int?

    public init(kind: Kind, domain: String? = nil, code: Int? = nil) {
        self.kind = kind
        self.domain = domain
        self.code = code
    }
}

/// Mutated only by RecordingSession. A late callback cannot claim another
/// recording; the first accepted reason remains the authoritative cause.
struct CaptureInterruptionState {
    private(set) var generation = UUID()
    private(set) var reason: CaptureInterruption?

    mutating func begin() -> UUID {
        generation = UUID()
        reason = nil
        return generation
    }

    mutating func accept(_ cause: CaptureInterruption, generation candidate: UUID) -> Bool {
        guard candidate == generation, reason == nil else { return false }
        reason = cause
        return true
    }

    mutating func invalidate() { _ = begin() }
}
