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
    /// 4th-order Butterworth high-pass.
    static func hp4(_ f: Double, fs: Double) -> [Biquad] { [.highpass(f, q: 0.5412, fs: fs), .highpass(f, q: 1.3066, fs: fs)] }
}

/// Dynamic de-esser: compresses only the 5.2-9.8 kHz band, only above 45% of the
/// recording's own p98 sibilance level. `amount` is the studio strength.
enum DeEsser {
    static func process(_ x: [Float], fs: Double, amount: Double) -> [Float] {
        let n = x.count
        guard amount > 0.01, n > 4800 else { return x }
        var hp = Biquad.highpass(5200, q: 0.7071, fs: fs), lp = Biquad.lowpass(9800, fs: fs)
        var s = [Float](repeating: 0, count: n), env = s
        let ca = Float(exp(-1 / (0.0008 * fs))), cr = Float(exp(-1 / (0.020 * fs)))
        var e: Float = 0
        for i in 0..<n {
            let v = Float(lp.run(hp.run(Double(x[i]))))
            s[i] = v
            let a = abs(v)
            e = a > e ? a + ca * (e - a) : a + cr * (e - a)
            env[i] = e
        }
        var samp: [Float] = []
        var i = 0
        while i < n { samp.append(env[i]); i += 480 }
        samp.sort()
        guard !samp.isEmpty else { return x }
        let threshold = max(0.45 * samp[Int(Double(samp.count - 1) * 0.98)], 1e-5)
        let ratio = Float(0.5 + 0.4 * amount)
        let maxCut = Float(pow(10, -(5 + 7 * amount) / 20))
        let ga = Float(exp(-1 / (0.0006 * fs))), gr = Float(exp(-1 / (0.012 * fs)))
        var out = x, g: Float = 1
        for j in 0..<n {
            var target: Float = 1
            if env[j] > threshold { target = max(pow(threshold / env[j], ratio), maxCut) }
            g = target < g ? target + ga * (g - target) : target + gr * (g - target)
            out[j] = x[j] - s[j] * (1 - g)
        }
        return out
    }
}

/// Slow gain riding on voiced 100 ms frames toward the recording's own median
/// level. Sigma 0.3 s means no word-level pumping.
enum Leveler {
    static func process(_ x: [Float], vad: [ClosedRange<Double>], fs: Double, range: Double) -> [Float] {
        let hop = Int(0.1 * fs), n = x.count / hop
        guard n > 10, range > 0.5 else { return x }
        var db = [Double](repeating: -120, count: n), voiced = [Bool](repeating: false, count: n)
        for f in 0..<n {
            var s = 0.0
            for i in 0..<hop { let v = Double(x[f * hop + i]); s += v * v }
            db[f] = 10 * log10(s / Double(hop) + 1e-12)
            let t = (Double(f) + 0.5) * 0.1
            voiced[f] = db[f] > -55 && vad.contains { $0.lowerBound <= t && t <= $0.upperBound }
        }
        let levels = (0..<n).filter { voiced[$0] }.map { db[$0] }.sorted()
        guard levels.count > 10 else { return x }
        let target = levels[levels.count / 2]
        var gain = [Double](repeating: .nan, count: n)
        for f in 0..<n where voiced[f] { gain[f] = clamp(target - db[f], -range, range) }
        var last = -1
        for f in 0..<n where !gain[f].isNaN {
            if last < 0 { for j in 0..<f { gain[j] = gain[f] } }
            else if f - last > 1 {
                for j in (last + 1)..<f {
                    gain[j] = lerp(gain[last], gain[f], Double(j - last) / Double(f - last))
                }
            }
            last = f
        }
        if last >= 0, last < n - 1 { for j in (last + 1)..<n { gain[j] = gain[last] } }
        guard gain.contains(where: { !$0.isNaN }) else { return x }
        gain = gaussianSmooth(gain.map { $0.isNaN ? 0 : $0 }, sigma: 3)
        var out = x
        for i in 0..<x.count {
            let p = Double(i) / Double(hop) - 0.5
            let a = min(max(Int(p.rounded(.down)), 0), n - 1), b = min(a + 1, n - 1)
            let u = clamp(p - Double(a), 0, 1)
            out[i] = x[i] * Float(pow(10, lerp(gain[a], gain[b], u) / 20))
        }
        return out
    }
}

enum VoiceStudio {
    /// Everything after the cleaner: neural denoise (if present), tone, de-ess, level, compress.
    static func finish(_ x: [Float], vad: [ClosedRange<Double>], plan a: AudioPlan, denoiser: (any Denoiser)?) -> [Float] {
        let fs = AudioIO.fs, s = a.studio
        var y = x
        if let d = denoiser, a.micClean { y = d.process(y) }
        var eq: [Biquad] = []
        if a.micMode == .podcast { eq.append(.highpass(100, fs: fs)); eq.append(.lowShelf(150, db: 1.0, fs: fs)) }
        if s > 0.01 {
            eq.append(.peaking(280, q: 0.9, db: -2.5 * s, fs: fs))            // mud
            eq.append(.peaking(520, q: 1.2, db: -1.5 * s, fs: fs))            // small-room box
            eq.append(.lowShelf(170, db: 1.8 * s, fs: fs))                     // body lost to dereverb
            eq.append(.peaking(3200, q: 0.8, db: 2.5 * s, fs: fs))            // presence
            eq.append(.highShelf(10500, db: 3.0 * s, fs: fs))                  // air
        }
        y = Cascade.apply(y, eq)
        y = DeEsser.process(y, fs: fs, amount: s)
        y = Leveler.process(y, vad: vad, fs: fs, range: 3 + 6 * s)
        var comp = Compressor()
        comp.thresholdDb = -19; comp.ratio = a.micMode == .loud ? 3.2 : 2.4; comp.attack = 0.006; comp.release = 0.2
        return comp.process(y, fs: fs)
    }
}
