import Foundation
import AVFoundation
import CoreMedia
import LumenProject

/// Independent capture session for each additional audio device. A physical
/// microphone and a loopback device (for example BlackHole) never share a
/// single flattened PCM stream, so they remain editable after recording.
///
/// ScreenCaptureKit still owns the primary microphone; this handles the
/// second and subsequent selected devices through AVFoundation.
final class ExtraMicrophoneRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let deviceID: String
    let deviceName: String
    let file: String
    let writer: CAFWriter

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "lumen.capture.additional-microphone", qos: .userInitiated)

    init(deviceID: String, file: String, in bundle: ProjectBundle) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID), device.hasMediaType(.audio) else {
            throw CaptureError.writer("Audio input disconnected: \(deviceID)")
        }
        self.deviceID = deviceID
        self.deviceName = device.localizedName
        self.file = file
        self.writer = CAFWriter(url: bundle.url.appendingPathComponent(file))
        super.init()

        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.writer("Cannot open audio input: \(device.localizedName)")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Match CAFWriter's Float32 path. The device's native sample rate is
        // preserved by capture, then resampled once to 48 kHz for the editor.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.writer("Cannot receive audio from: \(device.localizedName)")
        }
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() { session.startRunning() }

    func stop() async {
        session.stopRunning()
        // Drain the callback queue before closing the CAF. No callback writes
        // after stop returns, including the final buffer.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { c.resume() }
        }
        writer.close()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        let timestamp: Double
        if let clock = session.synchronizationClock {
            timestamp = CMSyncConvertTime(sampleBuffer.presentationTimeStamp,
                                          from: clock, to: CMClockGetHostTimeClock()).seconds
        } else {
            timestamp = sampleBuffer.presentationTimeStamp.seconds
        }
        writer.append(sampleBuffer, hostTime: timestamp.isFinite ? timestamp : nil)
    }

    var track: MicrophoneSourceMeta? {
        guard let start = writer.first.withLock({ $0 }), start.isFinite else { return nil }
        return MicrophoneSourceMeta(deviceID: deviceID, deviceName: deviceName,
                                    track: TrackMeta(file: file, startHostSeconds: start))
    }
}
