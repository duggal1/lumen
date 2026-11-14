import Foundation
import LumenCore
import LumenProject

extension Biquad {
    static func lowpass(_ f: Double, q: Double = 0.7071, fs: Double) -> Biquad {
        let w = 2 * Double.pi * f / fs, c = cos(w), a = sin(w) / (2 * q), a0 = 1 + a
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0,
                      a1: -2 * c / a0, a2: (1 - a) / a0)
    }
    static func lowShelf(_ f: Double, db: Double, fs: Double) -> Biquad {
        let A = pow(10, db / 40), w = 2 * Double.pi * f / fs, c = cos(w)
        let alpha = sin(w) * 0.70710678, t = 2 * A.squareRoot() * alpha
        let a0 = (A + 1) + (A - 1) * c + t
        return Biquad(b0: A * ((A + 1) - (A - 1) * c + t) / a0,
                      b1: 2 * A * ((A - 1) - (A + 1) * c) / a0,
                      b2: A * ((A + 1) - (A - 1) * c - t) / a0,
                      a1: -2 * ((A - 1) + (A + 1) * c) / a0,
                      a2: ((A + 1) + (A - 1) * c - t) / a0)
    }
    static func highShelf(_ f: Double, db: Double, fs: Double) -> Biquad {
        let A = pow(10, db / 40), w = 2 * Double.pi * f / fs, c = cos(w)
        let alpha = sin(w) * 0.70710678, t = 2 * A.squareRoot() * alpha
        let a0 = (A + 1) - (A - 1) * c + t
        return Biquad(b0: A * ((A + 1) + (A - 1) * c + t) / a0,
                      b1: -2 * A * ((A - 1) + (A + 1) * c) / a0,
                      b2: A * ((A + 1) + (A - 1) * c - t) / a0,
                      a1: 2 * ((A - 1) - (A + 1) * c) / a0,
                      a2: ((A + 1) - (A - 1) * c - t) / a0)
    }
}

enum Cascade {
    static func apply(_ x: [Float], _ filters: [Biquad]) -> [Float] {
        guard !filters.isEmpty else { return x }
        var f = filters, out = x
        for i in 0..<x.count {
            var v = Double(x[i])
            for j in 0..<f.count { v = f[j].run(v) }
            out[i] = Float(v)
        }
        return out
    }
}

/// Feed-forward compressor, soft knee, mean-square detector, attack/release in the dB domain.
struct VoiceCompressor {
    var thresholdDb: Double
    var ratio: Double
    var kneeDb: Double = 6
    var attack: Double
    var release: Double
    var makeupDb: Double = 0

    func process(_ x: [Float], fs: Double) -> [Float] {
        guard !x.isEmpty else { return x }
        let ca = exp(-1 / (attack * fs)), cr = exp(-1 / (release * fs)), cd = exp(-1 / (0.004 * fs))
        let slope = 1 - 1 / ratio, k = 0.11512925464970229          // ln(10) / 20
        var ms = 0.0, gainDb = 0.0
        var out = x
        for i in x.indices {
            let v = Double(x[i])
            ms = v * v + cd * (ms - v * v)
            let level = 10 * log10(ms + 1e-12)
            let over = level - thresholdDb
            let target: Double
            if 2 * over <= -kneeDb { target = 0 }
            else if 2 * abs(over) < kneeDb { let t = over + kneeDb / 2; target = -slope * t * t / (2 * kneeDb) }
            else { target = -slope * over }
            gainDb = target + (target < gainDb ? ca : cr) * (gainDb - target)
            out[i] = Float(v * exp((gainDb + makeupDb) * k))
        }
        return out
    }
}

enum VoiceStudio {
    /// 60th-percentile level (dB, 100 ms RMS) of the voiced frames = the speech body.
    /// Dynamics thresholds are meaningless unless the voice sits at a known level first.
    static func speechLevelDb(_ x: [Float], vad: [ClosedRange<Double>], fs: Double) -> Double? {
        let hop = Int(0.1 * fs), n = x.count / hop
        guard n > 5 else { return nil }
        var levels: [Double] = []
        for f in 0..<n {
            let t = (Double(f) + 0.5) * 0.1
            guard vad.contains(where: { $0.lowerBound <= t && t <= $0.upperBound }) else { continue }
            var s = 0.0
            for i in 0..<hop { let v = Double(x[f * hop + i]); s += v * v }
            let db = 10 * log10(s / Double(hop) + 1e-12)
            if db > -60 { levels.append(db) }
        }
        guard levels.count >= 8 else { return nil }
        levels.sort()
        return levels[levels.count * 6 / 10]
    }

    /// Tone and one soft-knee compressor. Noise and room tails are removed upstream.
    static func finish(_ x: [Float], vad: [ClosedRange<Double>], plan: AudioPlan,
                       denoiser: (any Denoiser)? = nil) -> [Float] {
        let fs = AudioIO.fs
        var voice = plan.micClean ? (denoiser?.process(x) ?? x) : x
        if plan.voiceClarity {
            voice = Cascade.apply(voice, [
                .lowShelf(130, db: 0.8, fs: fs),
                .peaking(300, q: 0.8, db: -1.2, fs: fs),
                .peaking(3000, q: 0.7, db: 1.5, fs: fs)
            ])
        }
        let amount = plan.studio.isFinite ? clamp(plan.studio, 0, 1) : 0
        guard amount > 0 else { return voice }
        let level = speechLevelDb(voice, vad: vad, fs: fs) ?? -24
        return VoiceCompressor(thresholdDb: level - 3 - 3 * amount,
                               ratio: 1 + 1.5 * amount, kneeDb: 8,
                               attack: 0.020, release: 0.200,
                               makeupDb: 2 * amount).process(voice, fs: fs)
    }
}
