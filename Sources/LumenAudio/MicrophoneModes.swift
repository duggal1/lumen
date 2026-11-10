import AVFoundation

public enum MicrophoneModes {
    @MainActor
    public static func showVoiceIsolationControls() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}
