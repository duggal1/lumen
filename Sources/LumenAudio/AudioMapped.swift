import Foundation
import LumenCore
import LumenProject

/// Time-map audio sampling (moved from Mixer.swift to keep each file ≤500 lines).
/// Pure function of (samples, TimeMap). Owned by the offline mixer.
extension AudioMixer {
    /// Source-time audio -> output time through the time map (1 ms steps, linear interpolation).
    /// Fades to silence (10 ms) inside speed ramps when `muteRamps` is set.
    /// Cut joins use a 40 ms equal-power crossfade (never an abrupt jump).
    static func mapped(_ x: [Float], offset: Double, tm: TimeMap, n: Int, muteRamps: Bool) -> [Float] {
        let fs = AudioIO.fs, spms = Int(fs / 1000)
        var y = [Float](repeating: 0, count: n)
        var prevS = tm.source(atOutput: 0), prevG = 1.0
        let cutOutputs = tm.cuts.compactMap { (cut: CutRange) -> Double? in
            guard cut.end > cut.start else { return nil }
            return tm.output(atSource: cut.end)
        }
        let halfXfade = Int(0.020 * fs)
        for k in 1...(n / spms + 1) {
            let t = Double(k) / 1000, s = tm.source(atOutput: t)
            let target = muteRamps && tm.speed(atOutput: t) > 1.2 ? 0.0 : 1.0
            let g = prevG + clamp(target - prevG, -0.1, 0.1)
            for j in 0..<spms {
                let i = (k - 1) * spms + j
                if i >= n { break }
                let u = Double(j) / Double(spms)
                let ss = (prevS + (s - prevS) * u - offset) * fs
                let gg = prevG + (g - prevG) * u
                var cross: (pre: Float, post: Float, w: Float)?
                for cutOut in cutOutputs {
                    let cutSample = Int(cutOut * fs)
                    if i >= cutSample - halfXfade && i < cutSample + halfXfade {
                        let w = Float(i - (cutSample - halfXfade)) / Float(halfXfade * 2)
                        let advance = Double(i - cutSample) / fs
                        let prePos = (tm.source(atOutput: max(0, cutOut - 0.001)) + advance - offset) * fs
                        let postPos = (tm.source(atOutput: cutOut + 0.001) + advance - offset) * fs
                        func sample(at pos: Double) -> Float {
                            guard pos >= 0, pos < Double(x.count - 1) else { return 0 }
                            let i0 = Int(pos), f = Float(pos - Double(i0))
                            return x[i0] * (1 - f) + x[i0 + 1] * f
                        }
                        cross = (sample(at: prePos), sample(at: postPos), w)
                        break
                    }
                }
                if let c = cross {
                    let mix = Float(gg) * (c.pre * sqrtf(1 - c.w) + c.post * sqrtf(c.w))
                    if abs(mix) > 0.00001 { y[i] = mix }
                    continue
                }
                if gg > 0.001, ss >= 0, ss < Double(x.count - 1) {
                    let i0 = Int(ss), f = Float(ss - Double(i0))
                    y[i] = (x[i0] * (1 - f) + x[i0 + 1] * f) * Float(gg)
                }
            }
            prevS = s; prevG = g
        }
        return y
    }
}
