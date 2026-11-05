import Foundation
import Testing
import LumenProject
import LumenCore
import LumenDirector
import LumenAudio

@Test func legacyProjectMetadataKeepsSingleMicrophoneCompatibility() throws {
    let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 2,
                            backingScale: 2, originX: 0, originY: 0)
    let original = ProjectMeta(name: "Legacy", source: source,
                               clock: RecordingClock())
    let legacy = try JSONEncoder().encode(original)
    var json = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
    json.removeValue(forKey: "additionalMicrophones")
    let decoded = try JSONDecoder().decode(ProjectMeta.self,
                                            from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.additionalMicrophones.isEmpty)
}

@Test func multipleDeviceTracksRoundTripWithHostClockOffsets() throws {
    let source = SourceInfo(width: 640, height: 480, fps: 30, duration: 4,
                            backingScale: 1, originX: 0, originY: 0)
    var metadata = ProjectMeta(name: "Multi-source", source: source,
                               clock: RecordingClock())
    metadata.mic = TrackMeta(file: "mic.caf", startHostSeconds: 20.05)
    metadata.additionalMicrophones = [
        MicrophoneSourceMeta(deviceID: "blackhole-virtual", deviceName: "BlackHole 2ch",
                             track: TrackMeta(file: "mic-extra-1.caf", startHostSeconds: 20.15)),
        MicrophoneSourceMeta(deviceID: "external-mic", deviceName: "USB microphone",
                             track: TrackMeta(file: "mic-extra-2.caf", startHostSeconds: 20.12)),
    ]
    let saved = try JSONEncoder().encode(metadata)
    let loaded = try JSONDecoder().decode(ProjectMeta.self, from: saved)
    #expect(loaded.additionalMicrophones.count == 2)
    #expect(loaded.additionalMicrophones[0].deviceName == "BlackHole 2ch")
    #expect(loaded.additionalMicrophones[1].track.file == "mic-extra-2.caf")
    #expect(abs(loaded.additionalMicrophones[1].track.startHostSeconds - 20.12) < 0.0001)
}

@Test func additionalMicrophoneIsMixedAndExportedAsIsolatedStem() {
    let fs = AudioIO.fs
    let source = SourceInfo(width: 640, height: 360, fps: 30, duration: 2,
                            backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 2)
    timeline.audio.speedRampsAuto = false
    timeline.audio.micClean = false
    timeline.audio.clickSounds = false
    timeline.audio.whooshes = false
    timeline = Director.derive(timeline, input: DirectorInput(events: [], source: source), revision: 1)

    let primary = (0..<Int(fs * 2)).map { i in Float(0.08 * sin(Double(i) * 2 * .pi * 220 / fs)) }
    let loopback = (0..<Int(fs)).map { i in Float(0.1 * sin(Double(i) * 2 * .pi * 630 / fs)) }
    let mixer = AudioMixer(mic: primary, micOffset: 0,
                           system: nil, systemOffset: 0,
                           additionalMicrophones: [
                               RecordedMicrophone(deviceName: "BlackHole 2ch",
                                                  samples: loopback, offset: 0.5),
                           ])
    let stems = mixer.stems(timeline)
    #expect(stems.map(\.name) == ["microphone", "microphone-2"])
    let independent = stems[1].left
    #expect(independent[Int(0.25 * fs)] == 0)
    let peak = independent[Int(0.65 * fs)..<Int(0.70 * fs)]
        .reduce(Float.zero) { max($0, abs($1)) }
    #expect(peak > 0.01)
    #expect(stems[0].left != independent)
    #expect(mixer.mix(timeline)?.truePeakDb ?? 0 <= -1.0 + 0.05)

    timeline.audio.micMode = .off
    #expect(mixer.stems(timeline).isEmpty)
}
