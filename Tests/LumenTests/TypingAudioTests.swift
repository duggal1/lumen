import Testing
import Foundation
import LumenCore
import LumenProject
import LumenDirector
import LumenAudio

@Test func typingKeepsClickedFieldAfterPause() {
    let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 10, backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 10)
    timeline.audio.speedRampsAuto = false
    let events = [InputEvent(t: 1, kind: .down, x: 800, y: 400), InputEvent(t: 5, kind: .keyDown, keyCode: 0), InputEvent(t: 5.2, kind: .keyDown, keyCode: 1)]
    let out = Director.derive(timeline, input: DirectorInput(events: events, source: source), revision: 1)
    #expect(out.zoom.contains { $0.start >= 5 - 1e-9 && $0.end > 5.2 })
}

@Test func missingAudioSettingsDecodeWithDefaults() throws {
    let audio = try JSONDecoder().decode(AudioPlan.self, from: Data("{}".utf8))
    #expect(audio.micClean)
    #expect(audio.targetLUFS == -14)
}

@Test func outputGainSurvivesLoudnessNormalization() throws {
    let source = SourceInfo(width: 640, height: 360, fps: 60, duration: 1, backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 1)
    timeline.audio.speedRampsAuto = false
    timeline.audio.micClean = false
    timeline.audio.clickSounds = false
    timeline.audio.whooshes = false
    timeline = Director.derive(timeline, input: DirectorInput(events: [], source: source), revision: 1)
    let samples = (0..<48000).map { Float(0.1 * sin(Double($0) * 2 * .pi * 440 / 48000)) }
    let mixer = AudioMixer(mic: samples, micOffset: 0, system: nil, systemOffset: 0)
    let reference = try #require(mixer.mix(timeline))
    var settings = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline.audio)) as? [String: Any])
    settings["outputGainDb"] = -12.0
    timeline.audio = try JSONDecoder().decode(AudioPlan.self, from: JSONSerialization.data(withJSONObject: settings))
    let quieter = try #require(mixer.mix(timeline))
    #expect(abs((quieter.lufs - reference.lufs) + 12) < 0.3)
    #expect(quieter.truePeakDb <= -1)
}
