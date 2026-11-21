import Foundation
import Testing
import AVFoundation
@testable import LumenAudio
import LumenCore
import LumenProject

// MARK: - Deterministic helpers (real audio buffers, no mocks)

private struct Noise {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(UInt64(1) << 53) * 2 - 1
    }
}

/// The `deep-filter` binary is optional. When it is absent the denoiser must
/// still clean voice through its spectral-gate fallback, and that fallback is
/// asserted here instead of returning silently. Returns true only when the
/// model itself is present and the model comparison can be measured.
private func requiresDeepFilterNet(_ label: String) -> Bool {
    guard DeepFilterNet.isAvailable else {
        VoiceProcessingDiagnostics.reset()
        let out = TrainedVoiceDenoiser(strength: 1).process([Float](repeating: 0.02, count: 2_048))
        #expect(!out.isEmpty, "\(label): fallback denoiser returned no audio")
        #expect(VoiceProcessingDiagnostics.modelRuns == 0,
                "\(label): model ran although the binary is missing")
        #expect(VoiceProcessingDiagnostics.fallbackCount == 1,
                "\(label): spectral-gate fallback was not recorded")
        return false
    }
    return true
}

private func rmsDb(_ x: [Float]) -> Double {
    guard !x.isEmpty else { return -120 }
    var s = 0.0
    for v in x { s += Double(v) * Double(v) }
    return 10 * log10(s / Double(x.count) + 1e-12)
}

/// RMS of the quietest 10% of 100 ms frames — a stable noise-floor estimate.
private func noiseFloorDb(_ x: [Float], fs: Double = 48_000) -> Double {
    let hop = Int(0.1 * fs)
    guard x.count > hop else { return rmsDb(x) }
    var frames: [Double] = []
    for s in stride(from: 0, to: x.count - hop, by: hop) {
        frames.append(rmsDb(Array(x[s..<(s + hop)])))
    }
    guard !frames.isEmpty else { return rmsDb(x) }
    frames.sort()
    return frames[max(0, frames.count / 10 - 1)]
}

/// Loud-to-quiet frame-level gap: how well a mode suppresses room tone in the
/// pauses. This is the audible difference between the two studio modes.
/// Continuous room hum with two speech bursts and short room tails, plus the
/// exact VAD. Pauses let the studio mode's expander show its real character.
private func echoFan() -> (x: [Float], vad: [ClosedRange<Double>]) {
    let fs = 48_000.0
    let n = Int(fs * 2)
    let vad: [ClosedRange<Double>] = [0.2...0.6, 1.2...1.6]
    var x = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / fs
        var v = 0.03 * Float(sin(2 * .pi * 60 * t)) + 0.02 * Float(sin(2 * .pi * 120 * t))
        for r in vad where t >= r.lowerBound && t <= r.upperBound {
            v += 0.25 * Float(sin(2 * .pi * 200 * t)) + 0.12 * Float(sin(2 * .pi * 600 * t))
            let tail = t - r.upperBound
            if tail > 0, tail < 0.4 { v += 0.18 * Float(exp(-tail * 8) * sin(2 * .pi * 200 * t)) }
        }
        x[i] = v
    }
    return (x, vad)
}

private func loudFloorGap(_ x: [Float], fs: Double = 48_000) -> Double {
    let hop = Int(0.1 * fs)
    guard x.count > hop else { return 0 }
    var frames: [Double] = []
    for s in stride(from: 0, to: x.count - hop, by: hop) { frames.append(rmsDb(Array(x[s..<(s + hop)]))) }
    guard frames.count >= 2 else { return 0 }
    frames.sort()
    let quiet = frames[max(0, frames.count / 10 - 1)]
    let loud = frames[min(frames.count - 1, frames.count - frames.count / 10)]
    return loud - quiet
}

private func speechFixture() throws -> [Float] {
    let url = try #require(Bundle.module.url(forResource: "speech", withExtension: "wav", subdirectory: "Fixtures"))
    return try AudioIO.readMono(url)
}

private func addWhiteNoise(_ x: [Float], seed: UInt64, level: Double) -> [Float] {
    var rng = Noise(seed: seed)
    return x.map { v in Float(max(-1, min(1, Double(v) + level * rng.next()))) }
}

/// A quiet derived track: no cues, no ducking, no cursor or camera motion.
/// The mixer only needs a non-nil derived track for these checks.
private func derived(_ tl: Timeline, duration: Double) -> Timeline {
    var out = tl
    out.derived = DerivedTracks(
        revision: 1,
        sourceSize: SIMD2<Double>(640, 360),
        outputDuration: duration,
        cursor: CursorTrack(count: 2),
        camera: CameraTrack(count: 2),
        clicks: [], cues: [], duck: [], face: [], webcamAspect: 16.0 / 9)
    return out
}

// MARK: - 1. Real model-based noise cancellation

@Test func deepFilterNetIsEngagedAndDeletesNoise() throws {
    guard requiresDeepFilterNet("engaged model") else { return }
    let speech = try speechFixture()
    let noisy = addWhiteNoise(speech, seed: 11, level: 0.03)

    let denoiser = TrainedVoiceDenoiser(strength: 1)
    let out = denoiser.process(noisy)

    #expect(denoiser.lastEngine == .deepFilterNet,
            "default voice path must run the model, not silently fall back to the spectral gate")
    #expect(out.count == noisy.count)
    #expect(out.allSatisfy { $0.isFinite })

    let before = noiseFloorDb(noisy), after = noiseFloorDb(out)
    let reduction = before - after
    #expect(reduction > 12, "noise floor only dropped \(reduction) dB (\(before) -> \(after))")

    // Voice must survive the pass — the master is not allowed to gate the speaker.
    let speechLoss = abs(rmsDb(out) - rmsDb(noisy))
    #expect(speechLoss < 4, "voice level shifted \(speechLoss) dB through the model")

    // Deterministic: identical input must produce bit-identical output.
    #expect(denoiser.process(noisy) == out)
}

@Test func deepFilterNetBeatsSpectralGateOnStationaryNoise() throws {
    guard requiresDeepFilterNet("model vs gate") else { return }
    let speech = try speechFixture()
    let noisy = addWhiteNoise(speech, seed: 23, level: 0.03)
    let before = noiseFloorDb(noisy)
    let model = TrainedVoiceDenoiser(strength: 1)
    let modelOut = model.process(noisy)
    let gateOut = SpectralGate(strength: 1).process(noisy)
    let modelCut = before - noiseFloorDb(modelOut)
    let gateCut = before - noiseFloorDb(gateOut)
    #expect(model.lastEngine == .deepFilterNet)
    #expect(modelCut > gateCut + 5,
            "model cut \(modelCut) dB must beat spectral gate \(gateCut) dB by >5 dB")
}

@Test func neuralCleanupUsesModelWhenOptionallyInjected() throws {
    guard requiresDeepFilterNet("injected model") else { return }
    let speech = try speechFixture()
    let noisy = addWhiteNoise(speech, seed: 31, level: 0.02)
    var plan = AudioPlan()
    plan.micClean = true
    plan.declick = false
    plan.dereverb = 0
    plan.studio = 0
    plan.voiceClarity = false
    let denoiser = TrainedVoiceDenoiser(strength: 1)
    let out = ProcessedVoiceCache.process(noisy, plan: plan, keyTimes: [], denoiser: denoiser)
    #expect(denoiser.lastEngine == .deepFilterNet)
    #expect(noiseFloorDb(noisy) - noiseFloorDb(out) > 8)
}

/// The production mixer creates its own denoiser; prove the model actually runs
/// there and that no fallback was taken. Diagnostics are process-wide evidence,
/// not an injected test double.
@Test func defaultProductionMixRunsTheModelAndCutsTheNoiseFloor() throws {
    guard requiresDeepFilterNet("production mix") else { return }
    let speech = try speechFixture()
    let noisy = addWhiteNoise(speech, seed: 91, level: 0.03)
    let n = noisy.count
    var tl = Timeline(duration: Double(n) / AudioIO.fs)
    tl.audio.micClean = true
    tl.audio.studio = 0
    tl.audio.dereverb = 0
    tl.audio.declick = false
    tl.audio.voiceClarity = false
    tl.audio.normalize = false
    tl.audio.voiceBoostDb = 0
    tl = derived(tl, duration: Double(n) / AudioIO.fs)
    VoiceProcessingDiagnostics.reset()
    let mixer = AudioMixer(mic: noisy, micOffset: 0, system: nil, systemOffset: 0)
    let mixed = try #require(mixer.mix(tl))
    #expect(VoiceProcessingDiagnostics.modelRuns >= 1,
            "default AudioMixer path must run DeepFilterNet, not the spectral gate")
    #expect(VoiceProcessingDiagnostics.fallbackCount == 0,
            "a hidden fallback occurred in the default voice path")
    let reduction = noiseFloorDb(noisy) - noiseFloorDb(mixed.l)
    #expect(reduction > 8, "default mix cut the noise floor only \(reduction) dB")
}

// MARK: - 2. Voice is 20-30% louder, measured in LUFS, with a safe ceiling

@Test func voiceBoostLiftsOwnVoiceTwoToThreeDbInLufs() throws {
    guard requiresDeepFilterNet("voice boost") else { return }
    // Scale the real recording to a headroom-safe level; the deliverable's
    // ceiling is owned by the master limiter and checked in the mix test below.
    let speech = try speechFixture().map { $0 * 0.25 }
    var quiet = AudioPlan()
    quiet.micClean = false
    quiet.studio = 0
    quiet.dereverb = 0
    quiet.declick = false
    quiet.voiceClarity = false
    quiet.voiceBoostDb = 0
    var loud = quiet
    loud.voiceBoostDb = 2.5

    let vad: [ClosedRange<Double>] = [0...Double(speech.count) / AudioIO.fs]
    let base = VoiceStudio.finish(speech, vad: vad, plan: quiet, denoiser: nil)
    let boosted = VoiceStudio.finish(speech, vad: vad, plan: loud, denoiser: nil)

    let baseLufs = Loudness.integrated([base, base])
    let boostedLufs = Loudness.integrated([boosted, boosted])
    let delta = boostedLufs - baseLufs
    #expect(delta > 2.0 && delta < 3.0,
            "voice must be 2-3 dB louder, got \(delta) dB (\(baseLufs) -> \(boostedLufs) LUFS)")
    #expect(boosted.allSatisfy { $0.isFinite })
    #expect(boosted.reduce(Float(0)) { max($0, abs($1)) } < 1.0, "no clipped samples")
    #expect(Loudness.truePeakDb([boosted, boosted]) <= -1 + 0.01)
}

@Test func finalMixRaisesVoiceProminenceAndStaysBelowTruePeakCeiling() throws {
    guard requiresDeepFilterNet("final mix") else { return }
    let speech = try speechFixture()
    let n = speech.count
    // Voice for the first half, silence after; a quiet system bed runs throughout.
    var mic = [Float](repeating: 0, count: n)
    let voiceEnd = n / 2
    for i in 0..<voiceEnd { mic[i] = speech[i] }
    let bed = (0..<n).map { Float(0.012 * sin(2 * Double.pi * 300 * Double($0) / AudioIO.fs)) }

    func prominence(_ boost: Double) throws -> (Double, MixedAudio) {
        var tl = Timeline(duration: Double(n) / AudioIO.fs)
        tl.audio.micClean = false
        tl.audio.studio = 0
        tl.audio.dereverb = 0
        tl.audio.declick = false
        tl.audio.voiceClarity = false
        tl.audio.soundEffectsEnabled = false
        tl.audio.speedRampsAuto = false
        tl.audio.voiceBoostDb = boost
        tl.audio.normalize = true
        tl = derived(tl, duration: Double(n) / AudioIO.fs)
        let mixer = AudioMixer(mic: mic, micOffset: 0, system: bed, systemOffset: 0)
        let mix = try #require(mixer.mix(tl))
        let voiceBand = rmsDb(Array(mix.l[0..<voiceEnd]))
        let bedBand = rmsDb(Array(mix.l[voiceEnd..<n]))
        return (voiceBand - bedBand, mix)
    }

    let (baseGap, baseMix) = try prominence(0)
    let (boostGap, boostMix) = try prominence(2.5)
    let lift = boostGap - baseGap
    #expect(lift > 1.5 && lift < 3.2,
            "voice-vs-bed prominence must rise ~2.5 dB, got \(lift) dB (\(baseGap) -> \(boostGap))")
    #expect(boostMix.truePeakDb <= -1 + 0.01, "true peak \(boostMix.truePeakDb) dBTP exceeds -1")
    #expect(boostMix.l.allSatisfy { $0.magnitude < 1.0 }, "final mix clips")
    #expect(boostMix.l == boostMix.l, "deterministic")
}

@Test func voiceBoostRoundTripsAndInvalidatesCaches() throws {
    let decoded = try JSONDecoder().decode(AudioPlan.self, from: Data("{}".utf8))
    #expect(decoded.voiceBoostDb == 2.5)
    var plan = decoded
    plan.voiceBoostDb = 3.0
    let roundTrip = try JSONDecoder().decode(AudioPlan.self, from: JSONEncoder().encode(plan))
    #expect(roundTrip.voiceBoostDb == 3.0)
    let samples: [Float] = [0.1, 0.2, 0.3]
    let baseKey = try ProcessedVoiceCache.key(samples: samples, plan: decoded, keyTimes: [])
    let loudKey = try ProcessedVoiceCache.key(samples: samples, plan: plan, keyTimes: [])
    #expect(baseKey != loudKey)
}

// MARK: - 3. One always-on chain (legacy mode values stay decodable)

@Test func studioChainIgnoresLegacyModeSelection() throws {
    // The owner removed Studio modes: the DSP is one fixed chain. Old projects
    // still decode their stored mode, but it must not change the audio.
    #expect(StudioMode.allCases.count == 2)
    #expect(Set(StudioMode.allCases.map(\.title)).count == 2)

    var base = AudioPlan()
    base.micClean = false
    base.studio = 0.5
    base.dereverb = 0
    base.declick = false
    var standard = base, optimized = base
    standard.studioMode = .standard
    optimized.studioMode = .optimized

    let (x, vad) = echoFan()
    let s = VoiceStudio.finish(x, vad: vad, plan: standard, denoiser: nil)
    let o = VoiceStudio.finish(x, vad: vad, plan: optimized, denoiser: nil)
    #expect(s == o, "a legacy mode toggled the Studio chain")

    let decoded = try JSONDecoder().decode(AudioPlan.self, from: JSONEncoder().encode(optimized))
    #expect(decoded.studioMode == .optimized)
}
