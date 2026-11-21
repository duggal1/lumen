import Foundation
import Testing
@testable import LumenAudio
import LumenProject
import LumenDirector

@Test func studioPlanDecodesWithNaturalDefaults() throws {
    let p = try JSONDecoder().decode(AudioPlan.self, from: Data("{}".utf8))
    #expect(p.micClean)
    #expect(p.studio == 0.25)
    #expect(p.dereverb == 0.5)
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
@Test func voiceControlsReachMixerAndInvalidateVoiceCache() throws {
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 1, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 1)
    tl.audio.micClean = false; tl.audio.dereverb = 0; tl.audio.declick = false
    tl.audio.studio = 0; tl.audio.voiceClarity = false; tl.audio.normalize = false
    tl.audio.speedRampsAuto = false; tl.audio.soundEffectsEnabled = false
    tl = Director.derive(tl, input: DirectorInput(events: [], source: src), revision: 1)
    let samples = (0..<48_000).map { i -> Float in
        let amplitude = i < 24_000 ? 0.03 : 0.2
        return Float(amplitude * sin(2 * .pi * 175 * Double(i) / 48_000))
    }
    let mixer = AudioMixer(mic: samples, micOffset: 0, system: nil, systemOffset: 0)
    let base = try #require(mixer.mix(tl))
    let key = try ProcessedVoiceCache.key(samples: samples, plan: tl.audio, keyTimes: [])
    tl.audio.studio = 0.75
    let compressed = try #require(mixer.mix(tl))
    #expect(compressed.l != base.l)
    #expect(key != (try ProcessedVoiceCache.key(samples: samples, plan: tl.audio, keyTimes: [])))
    tl.audio.studio = 0; tl.audio.voiceClarity = true
    let clear = try #require(mixer.mix(tl))
    #expect(clear.l != base.l)
    #expect(key != (try ProcessedVoiceCache.key(samples: samples, plan: tl.audio, keyTimes: [])))
}

@Test func spectralNoiseControlIsBoundedAndBypassesAtZero() {
    let noise = (0..<16_384).map { i -> Float in
        Float(0.015 * sin(Double(i) * 1.731) + 0.008 * sin(Double(i) * 0.119))
    }
    #expect(SpectralGate(strength: 0).process(noise) == noise)
    let clean = SpectralGate(strength: 0.8).process(noise)
    #expect(clean.count == noise.count)
    #expect(clean.allSatisfy { $0.isFinite })
    let before = noise.reduce(0.0) { $0 + Double($1 * $1) }
    let after = clean.reduce(0.0) { $0 + Double($1 * $1) }
    #expect(after < before)
    #expect(after > before * 0.001)
}

@Test func roomTailControlReducesDecayEnergy() {
    let samples = (0..<48_000).map { i -> Float in
        let t = Double(i) / 48_000
        let envelope = t < 0.3 ? 1 : exp(-(t - 0.3) / 0.12)
        return Float(0.2 * envelope * sin(2 * .pi * 220 * t))
    }
    var plan = AudioPlan()
    plan.micClean = false; plan.declick = false; plan.dereverb = 0
    #expect(ProcessedVoiceCache.render(samples, plan: plan, keyTimes: []) == samples)
    plan.dereverb = 0.7
    let clean = ProcessedVoiceCache.render(samples, plan: plan, keyTimes: [])
    #expect(clean.count == samples.count)
    let before = samples[24_000...].reduce(0.0) { $0 + Double($1 * $1) }
    let after = clean[24_000...].reduce(0.0) { $0 + Double($1 * $1) }
    #expect(after < before)
    #expect(clean.allSatisfy { $0.isFinite })
}

@Test func voiceNormalizationMeasuresFinalProgram() throws {
    // One fixed Studio loudness target; stored overrides no longer branch it.
    var plan = AudioPlan()
    plan.targetLUFSOverride = -16
    let signal = (0..<48_000).map { Float(0.04 * sin(2 * .pi * 440 * Double($0) / 48_000)) }
    let mastered = AudioMaster.process([signal, signal], plan: plan, hasProgram: true)
    #expect(plan.targetLUFS == AudioPlan.studioTargetLUFS)
    #expect(abs(mastered.lufs - plan.targetLUFS) < 0.5)
    #expect(mastered.truePeakDb <= -1)
    plan.outputGainDb = -6
    let quieter = AudioMaster.process([signal, signal], plan: plan, hasProgram: true)
    #expect(abs(quieter.lufs - (plan.targetLUFS - 6)) < 0.5)
}
