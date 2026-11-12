import Foundation
import AppKit
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
        agentTarget = target
        agentOptions = options
        pendingMarkers = []
        await start()
        agentTarget = nil
        agentOptions = nil
        guard phase == .recording else {
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
        pendingMarkers.append(marker)
    }

    public func activeRecordingBundle() async -> URL? { lastProjectURL }

    public func recordingLibrary() async -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: library,
            includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "lumen" }
    }
}

