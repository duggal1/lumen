import Foundation
import Testing
@testable import LumenAudio
import LumenProject

/// Studio Audio measurement, now with assertions so it can actually fail.
/// Keeps the AMP_ lines for before/after evidence in .proof logs.
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

private func ampDefaultPlan(_ boost: Double) -> AudioPlan {
    var p = AudioPlan()
    p.voiceBoostDb = boost
    return p
}

@Test func ampMeasureStudioChain() throws {
    let speech = try ampSpeech()
    var rng = AmpNoise(seed: 11)
    let noisy = speech.map { v in Float(max(-1, min(1, Double(v) + 0.03 * rng.next()))) }
    let raw = Loudness.integrated([noisy, noisy])
    print("AMP_RAW lufs=\(raw) peak=\(Loudness.truePeakDb([noisy, noisy]))")

    var flat = AudioPlan()
    flat.studio = 0; flat.dereverb = 0; flat.declick = false; flat.voiceBoostDb = 0
    let filtered = Cascade.apply(noisy.map { $0.isFinite ? $0 : 0 }, [.highpass(70, fs: AudioIO.fs)])
    let denoised = ProcessedVoiceCache.render(filtered, plan: flat, keyTimes: [])
    let floorIn = ampNoiseFloorDb(noisy), floorOut = ampNoiseFloorDb(denoised)
    print("AMP_DENOISE floorIn=\(floorIn) floorOut=\(floorOut)")
    // Real suppression, not a cosmetic filter: the quiet-window floor must drop
    // by a wide margin (measured 31.34 dB before this assertion existed).
    #expect(floorOut < floorIn - 15, "noise floor only fell \(floorIn - floorOut) dB")

    let quiet = ProcessedVoiceCache.process(noisy, plan: ampDefaultPlan(2.5), keyTimes: [])
    let loud = ProcessedVoiceCache.process(noisy, plan: ampDefaultPlan(6.0), keyTimes: [])
    let quietLufs = Loudness.integrated([quiet, quiet])
    let loudLufs = Loudness.integrated([loud, loud])
    print("AMP_CHAIN boost=2.5 lufs=\(quietLufs) peak=\(Loudness.truePeakDb([quiet, quiet]))")
    print("AMP_CHAIN boost=6.0 lufs=\(loudLufs) peak=\(Loudness.truePeakDb([loud, loud]))")
    #expect(loudLufs > quietLufs + 3, "voice boost slope is not audible in the chain")
    #expect(quiet.allSatisfy { $0.isFinite })
    #expect(loud.allSatisfy { $0.isFinite })
}

@Test func ampStudioChainIsDeterministic() throws {
    let speech = try ampSpeech()
    let a = ProcessedVoiceCache.process(speech, plan: ampDefaultPlan(2.5), keyTimes: [])
    let b = ProcessedVoiceCache.process(speech, plan: ampDefaultPlan(2.5), keyTimes: [])
    #expect(a == b, "same input produced different Studio Audio output")
}
