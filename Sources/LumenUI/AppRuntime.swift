import Foundation
import AppKit
import ScreenCaptureKit
import LumenCore
import LumenProject
import LumenCapture

/// Bridges the agent layer to the app.
///
/// The daemon and the UI share ONE engine: this adapter exposes the existing
/// `AppModel` recording lifecycle as the `LumenRuntime` the agent tools call,
/// so an agent drives exactly the same capture the UI buttons drive.
extension AppModel: LumenRuntime {
    public func runtimeStatus() async -> RuntimeStatus {
        var status = RuntimeStatus()
        switch phase {
        case .idle: status.phase = "idle"
        case .preparing: status.phase = "preparing"
        case .countdown(let n): status.phase = "countdown-\(n)"
        case .recording: status.phase = "recording"
        case .finishing: status.phase = "finishing"
        }
        status.paused = paused
        status.recording = phase == .recording
        var permissions = RuntimePermissions()
        permissions.screenRecording = Permissions.screen
        permissions.accessibility = Permissions.accessibility
        permissions.inputMonitoring = Permissions.input
        permissions.microphone = Permissions.mic
        permissions.camera = Permissions.camera
        status.permissions = permissions
        status.libraryPath = library.path
        status.projects = projects.count
        status.activeProjectPath = lastProjectURL?.path
        status.version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return status
    }

    public func startRecording(_ target: RecordingTarget, options: RecordingOptions) async throws {
        guard phase == .idle else { throw RuntimeFailure("A recording is already running.") }
        var resolved = target
        // Resolve the window now: the agent may have launched the app after
        // the library last refreshed its window list.
        if resolved.kind == .window, resolved.windowID == nil, let bundleID = resolved.bundleID {
            resolved.windowID = await Self.windowID(bundleID: bundleID)
        }
        agentTarget = resolved
        agentOptions = options
        // AGENT: preserve the recording initiator until the stop operation completes.
        agentRecording = true
        pendingMarkers = []
        await start()
        agentTarget = nil
        agentOptions = nil
        guard phase == .recording else {
            agentRecording = false
            let message = error ?? "The recording could not start."
            throw RuntimeFailure(message)
        }
    }

    public func stopRecording() async throws -> URL {
        guard phase == .recording else { throw RuntimeFailure("No recording is running.") }
        await stop()
        guard let url = lastProjectURL else { throw RuntimeFailure("The recording did not produce a project.") }
        return url
    }

    public func pauseRecording() async throws {
        guard phase == .recording else { throw RuntimeFailure("No recording is running.") }
        await session.pause()
        paused = await session.isPaused
    }

    public func resumeRecording() async throws {
        guard phase == .recording else { throw RuntimeFailure("No recording is running.") }
        await session.resume()
        paused = await session.isPaused
    }

    public func addMarker(_ marker: CaptureMarker) async throws {
        guard phase == .recording else { throw RuntimeFailure("No recording is running.") }
        // AGENT: duplicate marker IDs make later timeline anchors ambiguous.
        guard !marker.id.isEmpty, !pendingMarkers.contains(where: { $0.id == marker.id }) else {
            throw RuntimeFailure("Marker ID is empty or already exists: \(marker.id).")
        }
        pendingMarkers.append(marker)
    }

    /// The window id of an application's frontmost on-screen window.
    static func windowID(bundleID: String) async -> UInt32? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return nil
        }
        return content.windows.first { $0.owningApplication?.bundleIdentifier == bundleID }?.windowID
    }

    public func activeRecordingBundle() async -> URL? { lastProjectURL }

    public func recordingLibrary() async -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: library,
            includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "lumen" }
    }
}

