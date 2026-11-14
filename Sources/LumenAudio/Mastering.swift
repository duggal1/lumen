import Foundation
import Accelerate
import LumenCore
import LumenProject

/// Shared preview/export master: integrated loudness, linked limiting, true-peak safety.
enum AudioMaster {
    static func process(_ input: [[Float]], plan: AudioPlan, hasProgram: Bool) -> MixedAudio {
        var channels = input
        let initial = Loudness.integrated(channels)
        let output = plan.outputGainDb.isFinite ? clamp(plan.outputGainDb, -60, 24) : 0
        let target = plan.targetLUFS.isFinite ? plan.targetLUFS + output : -16 + output
        let normalize = plan.normalize && hasProgram && initial > -69
        let gainDb = normalize ? clamp(target - initial, -36, 30) : output
        let gain = Float(pow(10, gainDb / 20))
        channels = channels.map { vDSP.multiply(gain, $0) }
        let ceiling = Float(pow(10, -1.5 / 20))
        Limiter.apply(&channels, ceiling: ceiling)
        if normalize {
            let measured = Loudness.integrated(channels)
            let correction = clamp(target - measured, -3, 3)
            if abs(correction) > 0.1 {
                let trim = Float(pow(10, correction / 20))
                channels = channels.map { vDSP.multiply(trim, $0) }
                Limiter.apply(&channels, ceiling: ceiling)
            }
        }
        var peak = Loudness.truePeakDb(channels)
        if peak > -1.0 {
            let safety = Float(pow(10, (-1.05 - peak) / 20))
            channels = channels.map { vDSP.multiply(safety, $0) }
            peak = Loudness.truePeakDb(channels)
        }
        return MixedAudio(l: channels[0], r: channels[1],
                          lufs: Loudness.integrated(channels), truePeakDb: peak)
    }
}
