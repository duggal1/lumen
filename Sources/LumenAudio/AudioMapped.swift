import Foundation
import LumenCore
import LumenProject

/// 4-point Catmull-Rom. Linear interpolation at a fractional offset is a low-pass
/// (-2 dB @ 10 kHz, -6 dB @ 16 kHz at half a sample); this keeps the highs.
@inline(__always) private func cubic(_ x: [Float], _ pos: Double) -> Float {
    let i = Int(pos.rounded(.down))
    guard i >= 0, i + 1 < x.count else { return 0 }
    let f = Float(pos - Double(i))
    if f < 1e-6 { return x[i] }
    let p1 = x[i], p2 = x[i + 1]
    let p0 = i >= 1 ? x[i - 1] : p1
    let p3 = i + 2 < x.count ? x[i + 2] : p2
    return p1 + 0.5 * f * (p2 - p0 + f * (2 * p0 - 5 * p1 + 4 * p2 - p3 + f * (3 * (p1 - p2) + p3 - p0)))
}

/// Time-map audio sampling. Pure function of (samples, TimeMap). Owned by the offline mixer.
extension AudioMixer {
    /// Source-time audio -> output time through the time map (1 ms steps, cubic interpolation).
    /// Fades to silence inside speed ramps when `muteRamps` is set.
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
                            return cubic(x, pos)
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
                    y[i] = cubic(x, ss) * Float(gg)
                }
            }
            prevS = s; prevG = g
        }
        return y
    }
}
