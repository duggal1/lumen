import Foundation
import Testing
import AVFoundation
import LumenProject
import LumenDirector
import LumenAudio

@Test func exportedMicrophoneAndSystemStemsStayIndependent() throws {
    let fs = AudioIO.fs
    let source = SourceInfo(width: 640, height: 360, fps: 60, duration: 2,
                            backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 2)
    timeline.audio.speedRampsAuto = false
    timeline.audio.clickSounds = false
    timeline.audio.whooshes = false
    timeline.audio.micClean = false
    timeline.audio.micGainDb = 0
    timeline.audio.systemGainDb = -3
    timeline = Director.derive(timeline,
                               input: DirectorInput(events: [], source: source), revision: 1)
    let mic = (0..<Int(fs * 2)).map { Float(0.1 * sin(Double($0) * 2 * .pi * 330 / fs)) }
    let sys = (0..<Int(fs * 2)).map { Float(0.1 * sin(Double($0) * 2 * .pi * 700 / fs)) }
    let mixer = AudioMixer(mic: mic, micOffset: 0, system: sys, systemOffset: 0)
    let stems = mixer.stems(timeline)
    #expect(stems.map(\.name) == ["microphone", "system"])
    #expect(stems[0].left.count == stems[1].left.count)
    #expect(stems[0].left != stems[1].left)

    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try AudioIO.writeWAV(stems[0].left, stems[0].right, to: url)
    let saved = try AVAudioFile(forReading: url)
    #expect(saved.fileFormat.sampleRate == fs)
    #expect(saved.length >= Int64(fs * 2) - 2)
    #expect(saved.fileFormat.channelCount == 2)
}

@Test func independentWavStemPreservesRampedOutputTiming() {
    let fs = AudioIO.fs
    let source = SourceInfo(width: 640, height: 360, fps: 30, duration: 4,
                            backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 4)
    timeline.audio.speedRampsAuto = false
    timeline.audio.clickSounds = false
    timeline.audio.whooshes = false
    timeline.audio.micClean = false
    // Default behavior mutes microphone audio during speed ramps.
    // Disable it here to test the actual waveform's output-time alignment.
    timeline.audio.muteMicInRamps = false
    timeline.timeMap.ramps = [SpeedRamp(start: 1, end: 3, speed: 2.2)]
    timeline = Director.derive(timeline, input: DirectorInput(events: [], source: source), revision: 1)
    let mic = (0..<Int(fs * 4)).map { i -> Float in
        let t = Double(i) / fs
        // A real voice waveform survives the input high-pass filter.
        // A constant plateau is DC and would correctly be removed.
        return t >= 2 && t <= 2.2 ? Float(0.15 * sin(2 * .pi * 440 * t)) : 0
    }
    let stems = AudioMixer(mic: mic, micOffset: 0, system: nil, systemOffset: 0).stems(timeline)
    #expect(stems.count == 1)
    let target = timeline.timeMap.output(atSource: 2.1)
    let near = stems[0].left[Int((target - 0.02) * fs)..<Int((target + 0.02) * fs)]
    let peak = near.reduce(Float(0)) { max($0, abs($1)) }
    #expect(peak > 0.001)
    #expect(stems[0].left.count == Int(timeline.timeMap.outputDuration * fs) + 1)
}

@Test func stereoSystemCaptureKeepsIndependentLeftAndRightChannels() {
    let source = SourceInfo(width: 640, height: 360, fps: 60, duration: 1,
                            backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 1)
    timeline.audio.speedRampsAuto = false
    timeline.audio.clickSounds = false
    timeline.audio.whooshes = false
    timeline = Director.derive(timeline,
                               input: DirectorInput(events: [], source: source), revision: 1)
    let fs = AudioIO.fs
    let left = (0..<Int(fs)).map { Float(0.08 * sin(2 * Double.pi * 440 * Double($0) / fs)) }
    let right = (0..<Int(fs)).map { Float(0.08 * sin(2 * Double.pi * 660 * Double($0) / fs)) }
    let mixer = AudioMixer(mic: nil, micOffset: 0, system: left,
                           systemOffset: 0, systemRight: right)
    let stem = mixer.stems(timeline)
    #expect(stem.count == 1)
    #expect(stem[0].name == "system")
    #expect(stem[0].left != stem[0].right)
    let mix = mixer.mix(timeline)
    #expect(mix != nil)
    #expect(mix?.l != mix?.r)
}

@Test func opposedStereoMicrophoneChannelsDoNotCancelToSilence() throws {
    let fs = AudioIO.fs
    let left = (0..<Int(fs)).map { Float(0.1 * sin(2 * Double.pi * 250 * Double($0) / fs)) }
    let right = left.map { -$0 }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
    defer { try? FileManager.default.removeItem(at: file) }
    try AudioIO.writeCAF(left, right, to: file)
    let mono = try AudioIO.readMono(file)
    #expect(mono.count == left.count)
    #expect(mono.reduce(Float(0)) { max($0, abs($1)) } > 0.05)
}
