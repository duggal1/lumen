import Foundation
import Testing
@testable import LumenAudio
import LumenProject

// TEMPORARY measurement script for the audio amp task (subagent 5).
// Prints AMP_ lines; deleted after the before/after numbers are taken.

private struct AmpNoise {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(UInt64(1) << 53) * 2 - 1
    }
}

private func ampRmsDb(_ x: [Float]) -> Double {
    guard !x.isEmpty else { return -120 }
    var s = 0.0
    for v in x { s += Double(v) * Double(v) }
    return 10 * log10(s / Double(x.count) + 1e-12)
}

private func ampNoiseFloorDb(_ x: [Float], fs: Double = 48_000) -> Double {
    let hop = Int(0.1 * fs)
    guard x.count > hop else { return ampRmsDb(x) }
    var frames: [Double] = []
    for s in stride(from: 0, to: x.count - hop, by: hop) {
        frames.append(ampRmsDb(Array(x[s..<(s + hop)])))
    }
    guard !frames.isEmpty else { return ampRmsDb(x) }
    frames.sort()
    return frames[max(0, frames.count / 10 - 1)]
}

private func ampSpeech() throws -> [Float] {
    let url = try #require(Bundle.module.url(forResource: "speech", withExtension: "wav", subdirectory: "Fixtures"))
    return try AudioIO.readMono(url)
}

/// Default plan ("now"), optionally with a boosted voice.
private func ampDefaultPlan(_ boost: Double) -> AudioPlan {
    var p = AudioPlan()
    p.voiceBoostDb = boost
    return p
}

@Test func ampMeasureBaseline() throws {
    let speech = try ampSpeech()
    var rng = AmpNoise(seed: 11)
    let noisy = speech.map { v in Float(max(-1, min(1, Double(v) + 0.03 * rng.next()))) }
    print("AMP_RAW lufs=\(Loudness.integrated([noisy, noisy])) peak=\(Loudness.truePeakDb([noisy, noisy]))")

    // Denoise-only stage: the DF render with a flat studio/clarity plan.
    var flat = AudioPlan()
    flat.studio = 0; flat.dereverb = 0; flat.declick = false; flat.voiceBoostDb = 0
    let filtered = Cascade.apply(noisy.map { $0.isFinite ? $0 : 0 }, [.highpass(70, fs: AudioIO.fs)])
    let denoised = ProcessedVoiceCache.render(filtered, plan: flat, keyTimes: [])
    print("AMP_DENOISE floorIn=\(ampNoiseFloorDb(noisy)) floorOut=\(ampNoiseFloorDb(denoised))")

    // Default-plan chain at several boosts: "now" (2.5) and slope calibration.
    for b in [2.5, 6.0, 7.0] {
        let out = ProcessedVoiceCache.process(noisy, plan: ampDefaultPlan(b), keyTimes: [])
        print("AMP_CHAIN boost=\(b) lufs=\(Loudness.integrated([out, out])) peak=\(Loudness.truePeakDb([out, out])) rms=\(ampRmsDb(out))")
    }
}
