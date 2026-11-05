import Foundation
import Testing
import LumenAudio
import LumenProject
import LumenDirector

@Test func studioVoiceIsDeterministicAndHasIndependentStrength() {
    let fs = 48_000.0
    let raw = (0..<48_000).map { i -> Float in
        let t = Double(i) / fs
        return Float(0.12 * sin(2 * .pi * 175 * t) + 0.035 * sin(2 * .pi * 3_200 * t))
    }
    let dry = StudioVoice.process(raw, amount: 0)
    let wet = StudioVoice.process(raw, amount: 0.65)
    #expect(dry == raw)
    #expect(wet == StudioVoice.process(raw, amount: 0.65))
    #expect(wet != raw)
    #expect(wet.allSatisfy { $0.isFinite })
    #expect(wet.reduce(Float(0)) { max($0, abs($1)) } < 0.5)
}

@Test func studioVoiceSettingsDecodeWithLegacyDefaults() throws {
    let p = try JSONDecoder().decode(AudioPlan.self, from: Data("{}".utf8))
    #expect(p.voiceProfile == .natural)
    #expect(p.studioAmount == 0.65)
    var new = p
    new.voiceProfile = .studio
    new.studioAmount = 0.8
    let decoded = try JSONDecoder().decode(AudioPlan.self, from: JSONEncoder().encode(new))
    #expect(decoded.voiceProfile == .studio)
    #expect(decoded.studioAmount == 0.8)
}

@Test func studioMicRemainsWithinPeakCeiling() throws {
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 2, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 2)
    tl.audio.speedRampsAuto = false
    tl.audio.voiceProfile = .studio
    tl.audio.studioAmount = 1
    tl.audio.micClean = false
    tl.audio.clickSounds = false
    tl.audio.whooshes = false
    tl = Director.derive(tl, input: DirectorInput(events: [], source: src), revision: 1)
    let fs = AudioIO.fs
    let samples = (0..<Int(fs * 2)).map { Float(0.3 * sin(2 * Double.pi * 3200 * Double($0) / fs)) }
    let mix = try #require(AudioMixer(mic: samples, micOffset: 0, system: nil, systemOffset: 0).mix(tl))
    #expect(mix.truePeakDb <= -1.0 + 0.01)
    #expect(mix.lufs > -20 && mix.lufs < -10)
}
