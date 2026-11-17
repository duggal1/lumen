import Foundation
import CoreGraphics

// MARK: - Agent runtime seam
//
// The agent layer (LumenControl) must be able to drive a recording without
// importing SwiftUI, and the UI must not depend on the agent layer. The seam
// lives here, in the base target both sides already depend on.
//
// `LumenApp` implements `LumenRuntime` on top of the existing `AppModel`, so
// the agent drives exactly the same capture start/stop the UI buttons drive.

/// What to record.
public enum RecordingTargetKind: String, Codable, Sendable, Equatable, CaseIterable {
    case display, window, region
}

/// A capture target, resolved by the agent.
public struct RecordingTarget: Codable, Sendable, Equatable {
    public var kind: RecordingTargetKind
    /// `CGDirectDisplayID` for display/region targets.
    public var displayID: UInt32?
    /// Bundle identifier for window targets ("com.apple.TextEdit").
    public var bundleID: String?
    /// Window id, when the agent already knows it.
    public var windowID: UInt32?
    /// Region in display points.
    public var rect: CGRect?

    public init(kind: RecordingTargetKind, displayID: UInt32? = nil, bundleID: String? = nil,
                windowID: UInt32? = nil, rect: CGRect? = nil) {
        self.kind = kind; self.displayID = displayID; self.bundleID = bundleID
        self.windowID = windowID; self.rect = rect
    }
}

/// Everything the agent can choose about a recording.
public struct RecordingOptions: Codable, Sendable, Equatable {
    public var fps = 60
    public var microphone = true
    public var systemAudio = false
    public var webcam = false
    // AGENT: agent recordings can start immediately while human recordings retain their countdown.
    public var countdownSeconds = 0
    /// Automatic privacy masking is ON by default for agent recordings: they
    /// show emails, tokens and the like.
    public var privacyAutoMask = true
    public init() {}
}

/// One point of interest in a recording. Anchored on the host clock, exactly
/// like the recorded input events, so a marker and a click can be compared.
public struct CaptureMarker: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String?
    /// Host-clock seconds (same clock as `InputEvent.t`).
    public var startHostSeconds: Double
    public var endHostSeconds: Double
    /// Resolved screen rect of whatever the step was about, in screen points.
    public var rect: CGRect?

    public init(id: String, label: String? = nil, startHostSeconds: Double, endHostSeconds: Double, rect: CGRect? = nil) {
        self.id = id; self.label = label
        self.startHostSeconds = startHostSeconds; self.endHostSeconds = endHostSeconds
        self.rect = rect
    }
}

/// What a resolved frame is evidence *about*. Dialogs, new windows and typing
/// fields are distinct beats: the planner holds a dialog longer and frames a
/// field tightly, but all three must carry their own provenance.
public enum IntentKind: String, Codable, Sendable, CaseIterable, Equatable {
    case click, typing, dialog, newWindow, marker
}

/// A resolved, provenance-carrying intent beat handed to the planner or the
/// agent marker stream. A `nil` rect on `resolved == false` is evidence of
/// absence — it must never be expanded into a guessed camera target.
public struct IntentFrame: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: IntentKind
    public var startHostSeconds: Double
    public var endHostSeconds: Double
    /// Resolved screen rect of the subject, in screen points.
    public var rect: CGRect?
    /// Window-level `window|<role>|<subrole>|<title>` or element-level AX label.
    public var label: String?
    public var resolved: Bool
    public var epoch: UInt32
    public var sampledAt: Double
    public var windowID: Int?
    public var appName: String?

    public init(id: String, kind: IntentKind, startHostSeconds: Double, endHostSeconds: Double,
                rect: CGRect? = nil, label: String? = nil, resolved: Bool = false,
                epoch: UInt32 = 0, sampledAt: Double = 0, windowID: Int? = nil, appName: String? = nil) {
        self.id = id; self.kind = kind
        self.startHostSeconds = startHostSeconds; self.endHostSeconds = endHostSeconds
        self.rect = rect; self.label = label; self.resolved = resolved
        self.epoch = epoch; self.sampledAt = sampledAt
        self.windowID = windowID; self.appName = appName
    }

    /// The legacy marker stream cannot express provenance; it keeps the rect
    /// (only when resolved) and the label so downstream consumers can still
    /// recover the window-level evidence from the marker's label.
    public var marker: CaptureMarker {
        CaptureMarker(id: id, label: label, startHostSeconds: startHostSeconds,
                      endHostSeconds: endHostSeconds, rect: resolved ? rect : nil)
    }
}

/// Permission state, reported by `lumen_status`.
public struct RuntimePermissions: Codable, Sendable, Equatable {
    public var screenRecording = false
    public var accessibility = false
    public var inputMonitoring = false
    public var microphone = false
    public var camera = false
    public init() {}
}

/// A snapshot of the recording state.
public struct RuntimeStatus: Codable, Sendable, Equatable {
    public var phase: String = "idle"
    public var paused = false
    public var recording = false
    public var permissions = RuntimePermissions()
    public var libraryPath: String = ""
    public var projects = 0
    public var activeProjectPath: String?
    public var version = "0.1.0"
    public init() {}
    public init(phase: String, paused: Bool, recording: Bool, permissions: RuntimePermissions,
                libraryPath: String, projects: Int, activeProjectPath: String?, version: String) {
        self.phase = phase
        self.paused = paused
        self.recording = recording
        self.permissions = permissions
        self.libraryPath = libraryPath
        self.projects = projects
        self.activeProjectPath = activeProjectPath
        self.version = version
    }
}

/// A failure the runtime reports to the agent.
public struct RuntimeFailure: Error, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The seam the agent layer calls. Implemented by the app (UI or headless).
public protocol LumenRuntime: AnyObject, Sendable {
    func runtimeStatus() async -> RuntimeStatus
    func startRecording(_ target: RecordingTarget, options: RecordingOptions) async throws
    func stopRecording() async throws -> URL
    func pauseRecording() async throws
    func resumeRecording() async throws
    /// Records a marker on the current recording. Throws when nothing is recording.
    func addMarker(_ marker: CaptureMarker) async throws
    /// Adds an actuator event to the current recording without posting it through HID.
    // AGENT: virtual mode needs an event-log path because process-targeted events bypass Lumen's global event tap.
    func injectInput(kind: InputEvent.Kind, screenPoint: CGPoint, button: UInt8,
                     keyCode: UInt16, flags: UInt16, scrollDelta: Float) async throws
    /// The bundle of the recording in progress, if any.
    func activeRecordingBundle() async -> URL?
    /// All projects in the library.
    func recordingLibrary() async -> [URL]
}

public extension LumenRuntime {
    // AGENT: runtimes without an event recorder reject virtual input instead of silently losing its analysis events.
    func injectInput(kind: InputEvent.Kind, screenPoint: CGPoint, button: UInt8,
                     keyCode: UInt16, flags: UInt16, scrollDelta: Float) async throws {
        throw RuntimeFailure("This runtime cannot record virtual input events.")
    }

    /// Resolved dialog/new-window/typing beats default to the marker stream so
    /// existing runtimes keep working; a runtime with the intent pipeline can
    /// override this and keep the full provenance (epoch, resolved, windowID).
    func recordIntent(_ intent: IntentFrame) async throws {
        try await addMarker(intent.marker)
    }
}
