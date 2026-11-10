import AVFoundation
import CoreAudio
import CoreMedia
import LumenCore

final class VoiceMicrophoneRecorder {
    private let engine = AVAudioEngine()
    private var tapped = false

    init(deviceID: String?) throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.isVoiceProcessingAGCEnabled = false
        if let deviceID {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var uid: CFString = deviceID as CFString
            var device = AudioDeviceID(kAudioObjectUnknown)
            var translation = AudioValueTranslation()
            let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
                withUnsafeMutablePointer(to: &device) { devicePointer in
                    translation.mInputData = UnsafeMutableRawPointer(uidPointer)
                    translation.mInputDataSize = UInt32(MemoryLayout<CFString>.size)
                    translation.mOutputData = UnsafeMutableRawPointer(devicePointer)
                    translation.mOutputDataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
                    var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                    return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &translation)
                }
            }
            guard status == noErr, device != kAudioObjectUnknown, let unit = input.audioUnit else {
                throw CaptureError.writer("The selected microphone is unavailable.")
            }
            guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                       0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                throw CaptureError.writer("Cannot open the selected microphone with voice processing.")
            }
        }
    }

    func start(receive: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.writer("No microphone input is available.")
        }
        input.installTap(onBus: 0, bufferSize: 480, format: format) { buffer, time in
            guard buffer.frameLength > 0, time.isHostTimeValid else { return }
            var description: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                    asbd: buffer.format.streamDescription, layoutSize: 0, layout: nil,
                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                    formatDescriptionOut: &description) == noErr, let description else { return }
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                presentationTimeStamp: CMTime(seconds: HostClock.seconds(machTicks: time.hostTime), preferredTimescale: 1_000_000_000),
                decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                    makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                    sampleCount: Int(buffer.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr,
                  let sample,
                  CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                    blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                    bufferList: buffer.audioBufferList) == noErr else { return }
            CMSampleBufferSetDataReady(sample)
            receive(sample)
        }
        tapped = true
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
    }

    deinit { stop() }
}
