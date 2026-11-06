import Foundation
import Testing
@testable import LumenCapture
@testable import LumenUI

@Test func deviceDiscoveryNeverCrashesAndUnknownDeviceFailsLoudly() {
    let devices = DeviceCapture.availableDevices()
    // May be empty on a headless CI Mac; the contract is "no crash, and an
    // unknown id is a typed error, never a silent substitution."
    let result = Result { try DeviceCapture.resolve(deviceID: "no-such-device-xyz") }
    guard case .failure(let error) = result else { Issue.record("unknown device must throw"); return }
    guard case DeviceCapture.DeviceError.notConnected = error else {
        Issue.record("expected notConnected, got \(error)"); return
    }
    #expect(devices.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })
}

@MainActor
@Test func appModelHotkeyStateMachineStartsIdle() {
    // Instantiating AppModel registers the Carbon hotkeys (Cmd+Opt+R start/
    // stop, Cmd+Opt+P pause). If registration crashed, this would not get here.
    let app = AppModel()
    #expect(app.phase == .idle)
    #expect(app.recordingStatus == "Lumen")
    // Pause outside recording is a no-op (hotkey safety).
    app.togglePause()
    #expect(app.phase == .idle)
    #expect(!app.paused)
}

@MainActor
@Test func countdownPhaseReportsSeconds() {
    let app = AppModel()
    app.phase = .countdown(2)
    #expect(app.recordingStatus == "Recording in 2")
    app.phase = .countdown(1)
    #expect(app.recordingStatus == "Recording in 1")
}
