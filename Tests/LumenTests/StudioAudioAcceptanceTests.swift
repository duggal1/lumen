import Foundation
import Testing
@testable import LumenAudio
import LumenProject

/// P6 acceptance on the real offline mix: one fixed Studio chain, >= +1.6 dB
/// louder than the old -14 LUFS program, <= -1 dBTP, real noise suppression,
/// no clipping, deterministic. All six fixtures reuse the bundled speech.
private enum SAT {
    struct Noise {
        private var s: UInt64
        init(_ seed: UInt64) { s = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        mutating func next() -> Double {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Double(s >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    static func speech() throws -> [Float] {
        let url = try #require(Bundle.module.url(forResource: "speech", withExtension: "wav", subdirectory: "Fixtures"))
        return try AudioIO.readMono(url)
    }

    static func mix(_ x: [Float], seed: UInt64, hum: Double, hiss: Double,
                    quiet: Double = 1, loud: Double = 1) -> [Float] {
        var rng = Noise(seed)
        let fs = AudioIO.fs
        return x.enumerated().map { i, v in
            let t = Double(i) / fs
            let fan = hum * (0.6 * sin(2 * .pi * 60 * t) + 0.4 * sin(2 * .pi * 120 * t))
            let room = hiss * rng.next()
            return Float(max(-0.95, min(0.95, (Double(v) + fan + room) * quiet * loud)))
        }
    }

    static func floorDb(_ x: [Float]) -> Double {
        let hop = Int(0.1 * AudioIO.fs)
        guard x.count > hop else { return -120 }
        var frames: [Double] = []
        for s in stride(from: 0, to: x.count - hop, by: hop) {
            var sum = 0.0
            for v in x[s..<(s + hop)] { sum += Double(v) * Double(v) }
            frames.append(10 * log10(sum / Double(hop) + 1e-12))
        }
        frames.sort()
        return frames[max(0, frames.count / 10 - 1)]
    }

    /// The same offline master path preview and export both use.
    static func master(_ x: [Float]) -> MixedAudio {
        AudioMaster.process([x, x], plan: AudioPlan(), hasProgram: true)
    }
}

@Suite struct StudioAudioAcceptanceTests {
    @Test func sixFixturesStayLoudCleanAndBelowTruePeak() throws {
        let speech = try SAT.speech()
        let fixtures: [(String, [Float])] = [
            ("clean", speech),
            ("fan", SAT.mix(speech, seed: 3, hum: 0.02, hiss: 0.004)),
            ("keyboard", SAT.mix(speech, seed: 7, hum: 0.004, hiss: 0.02)),
            ("room", SAT.mix(speech, seed: 11, hum: 0.01, hiss: 0.03)),
            ("quiet", SAT.mix(speech, seed: 13, hum: 0.005, hiss: 0.003, quiet: 0.25)),
            ("loud", SAT.mix(speech, seed: 17, hum: 0.005, hiss: 0.003, loud: 1.35)),
        ]
        for (name, input) in fixtures {
            let out = SAT.master(ProcessedVoiceCache.process(input, plan: AudioPlan(), keyTimes: []))
            print("P6 \(name): lufs=\(String(format: "%.2f", out.lufs)) peak=\(String(format: "%.2f", out.truePeakDb))")
            #expect(abs(out.lufs - AudioPlan.studioTargetLUFS) < 0.8, "\(name) missed target: \(out.lufs)")
            #expect(out.truePeakDb <= -1 + 1e-3, "\(name) true peak \(out.truePeakDb) > -1 dBTP")
            #expect(out.l.allSatisfy { $0.isFinite && abs($0) < 1 }, "\(name) clipped")
        }
    }

    @Test func studioChainIsAtLeastOnePointSixDbLouderThanOldProgram() throws {
        let speech = try SAT.speech()
        let voice = ProcessedVoiceCache.process(speech, plan: AudioPlan(), keyTimes: [])
        let newOut = SAT.master(voice)
        // The old pipeline is the same mix with a -14 LUFS program target, i.e.
        // exactly 2 dB below the new single -12 LUFS target.
        var old = AudioPlan()
        // Old program target -14 = new target (-12) plus -2 dB of output gain.
        old.outputGainDb = -14 - AudioPlan.studioTargetLUFS
        let oldOut = AudioMaster.process([voice, voice], plan: old, hasProgram: true)
        let gain = newOut.lufs - oldOut.lufs
        print("P6 gain over old -14 program: \(String(format: "%.2f", gain)) dB")
        #expect(gain >= 1.6, "only \(gain) dB louder than the old pipeline")
        #expect(newOut.truePeakDb <= -1 + 1e-3)
    }

    @Test func studioChainReducesNoiseFloorAndIsDeterministic() throws {
        let speech = try SAT.speech()
        let noisy = SAT.mix(speech, seed: 23, hum: 0.02, hiss: 0.03)
        let before = SAT.floorDb(noisy)
        let after = SAT.floorDb(ProcessedVoiceCache.process(noisy, plan: AudioPlan(), keyTimes: []))
        print("P6 noise floor \(String(format: "%.1f", before)) -> \(String(format: "%.1f", after)) dB")
        #expect(after < before - 10, "noise floor only fell \(before - after) dB")

        let a = ProcessedVoiceCache.process(noisy, plan: AudioPlan(), keyTimes: [])
        let b = ProcessedVoiceCache.process(noisy, plan: AudioPlan(), keyTimes: [])
        #expect(a == b, "Studio Audio is not deterministic")
    }
}
