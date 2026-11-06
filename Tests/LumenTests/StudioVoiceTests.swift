import Foundation
import Testing
@testable import LumenAudio
import LumenProject
import LumenDirector

@Test func studioPlanDecodesWithNaturalDefaults() throws {
    let p = try JSONDecoder().decode(AudioPlan.self, from: Data("{}".utf8))
    #expect(!p.micClean)
    #expect(p.studio == 0.25)
    #expect(p.dereverb == 0)
    var new = p
    new.studio = 0.65
    new.dereverb = 0.4
    let decoded = try JSONDecoder().decode(AudioPlan.self, from: JSONEncoder().encode(new))
    #expect(decoded.studio == 0.65)
    #expect(decoded.dereverb == 0.4)
    let legacy = try JSONDecoder().decode(AudioPlan.self, from: Data(#"{"studioAmount":0.42}"#.utf8))
    #expect(legacy.studio == 0.42)
}

@Test func voiceStudioIsDeterministicAndRespondsToStudioAmount() {
    let fs = 48_000.0
    let raw = (0..<48_000).map { i -> Float in
        let t = Double(i) / fs
        return Float(0.12 * sin(2 * .pi * 175 * t) + 0.035 * sin(2 * .pi * 3_200 * t))
    }
    var plan = AudioPlan()
    plan.micClean = false
    plan.micMode = .standard
    plan.studio = 0
    let dryPlan = plan
    let dry = VoiceStudio.finish(raw, vad: [0.0...1.0], plan: dryPlan, denoiser: nil)
    plan.studio = 0.65
    let wet = VoiceStudio.finish(raw, vad: [0.0...1.0], plan: plan, denoiser: nil)
    #expect(dry == VoiceStudio.finish(raw, vad: [0.0...1.0], plan: dryPlan, denoiser: nil))
    #expect(wet != dry)
    #expect(wet.allSatisfy { $0.isFinite })
    #expect(wet.reduce(Float(0)) { max($0, abs($1)) } < 1.0)
}

@Test func studioMicRemainsWithinPeakCeiling() throws {
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 2, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 2)
    tl.audio.speedRampsAuto = false
    tl.audio.studio = 1
    tl.audio.dereverb = 0.85
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