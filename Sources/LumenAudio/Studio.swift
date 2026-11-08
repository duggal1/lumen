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
    /// Soft downward expander: ducks non-voiced 10ms frames toward the
    /// floor with 100ms VAD look-ahead so tails breathe. Standard -18dB,
    /// Optimized -30dB. Pure gain stage, no clipping, finite output.
    enum Expander {
        static func apply(_ x: [Float], vad: [ClosedRange<Double>], fs: Double, depthDb: Double) -> [Float] {
            let hop = max(Int(0.01 * fs), 1), n = x.count / hop
            guard n > 10, depthDb < -1, !vad.isEmpty else { return x }
            let lookAhead = Int(0.1 * fs / Double(hop))
            var gainDb = [Double](repeating: 0, count: n)
            for f in 0..<n {
                let t = (Double(f) + 0.5) * 0.01
                var voiced = false
                for lo in max(0, f - lookAhead)..<min(n, f + lookAhead + 1) {
                    let lt = (Double(lo) + 0.5) * 0.01
                    if vad.contains(where: { $0.lowerBound <= lt && lt <= $0.upperBound }) { voiced = true; break }
                }
                if !voiced { gainDb[f] = depthDb }
            }
            // Smooth: attack 5ms (drop fast), release 150ms (rise gentle).
            let ga = Float(exp(-1 / (0.005 * fs))), gr = Float(exp(-1 / (0.15 * fs)))
            var out = x, g: Float = 1
            var k = 0
            for i in 0..<x.count {
                let target = Float(pow(10, gainDb[min(k, n - 1)] / 20))
                g = target < g ? target + ga * (g - target) : target + gr * (g - target)
                out[i] = x[i] * g
                if (i + 1) % hop == 0 { k += 1 }
            }
            return out
        }
    }

    /// Measure HF (3-6kHz) vs LF to decide if bandwidth extension is needed.
    static func hfSparse(_ x: [Float], fs: Double) -> Bool {
        var hp = Biquad.highpass(3000, fs: fs)
        var lp = Biquad.lowpass(6000, fs: fs)
        var hfE = 0.0, totE = 0.0
        for v in x {
            let d = Double(v)
            hfE += pow(lp.run(hp.run(d)), 2)
            totE += d * d
        }
        return totE > 1e-9 && hfE / totE < 0.02
    }

    /// Bandwidth extension: soft-saturate HF band only when HF is sparse.
    static func extendHF(_ x: [Float], fs: Double) -> [Float] {
        guard hfSparse(x, fs: fs) else { return x }
        var hp = Biquad.highpass(3000, fs: fs)
        var out = x
        for i in 0..<x.count {
            let hf = hp.run(Double(x[i]))
            let ext = Float(tanh(hf * 0.6) * 0.25)
            out[i] = x[i] + ext
        }
        return out
    }

    /// Split-band compression helper for Optimized multiband.
    static func splitCompress(_ y: [Float], fs: Double) -> [Float] {
        var lp = Biquad.lowpass(250, fs: fs), hp = Biquad.highpass(250, fs: fs)
        var lo = [Float](repeating: 0, count: y.count), hi = lo
        for i in 0..<y.count {
            let d = Double(y[i])
            lo[i] = Float(lp.run(d))
            hi[i] = Float(hp.run(d))
        }
        var cLow = Compressor(); cLow.thresholdDb = -20; cLow.ratio = 2.0; cLow.attack = 0.015; cLow.release = 0.2
        var cHigh = Compressor(); cHigh.thresholdDb = -16; cHigh.ratio = 2.2; cHigh.attack = 0.008; cHigh.release = 0.15
        let loC = cLow.process(lo, fs: fs), hiC = cHigh.process(hi, fs: fs)
        var out = y
        for i in 0..<y.count { out[i] = loC[i] + hiC[i] }
        return out
    }
    /// Keep SplitCompress name used by Optimized path (multiband).
    static func splitBandCompress(_ y: [Float], fs: Double) -> [Float] { splitCompress(y, fs: fs) }

    /// Everything after the cleaner: neural denoise (if present), tone, de-ess, level, compress.
    static func finish(_ x: [Float], vad: [ClosedRange<Double>], plan a: AudioPlan, denoiser: (any Denoiser)?) -> [Float] {
        let fs = AudioIO.fs, s = a.studio, opt = a.studioMode == .optimized
        var y = x
        if let d = denoiser, a.micClean { y = d.process(y) }
        // Standard chain start: HP + hum notch. Optimized adds deeper cut.
        var head: [Biquad] = [.highpass(opt ? 80 : 100, fs: fs), .peaking(120, q: 12, db: opt ? -24 : -14, fs: fs)]
        if a.micMode == .podcast { head.append(.lowShelf(150, db: 1.0, fs: fs)) }
        y = Cascade.apply(y, head)
        // Soft downward expander BEFORE EQ/level/comp (so comp cannot lift floor).
        y = Expander.apply(y, vad: vad, fs: fs, depthDb: opt ? -30 : -18)
        var eq: [Biquad] = []
        if a.micMode == .podcast { eq.append(.highpass(100, fs: fs)); eq.append(.lowShelf(150, db: 1.0, fs: fs)) }
        if s > 0.01 || opt {
            let strength = opt ? max(s, 0.5) : s
            eq.append(.peaking(280, q: 0.9, db: -2.5 * strength, fs: fs))            // mud
            eq.append(.peaking(520, q: 1.2, db: -1.5 * strength, fs: fs))            // small-room box
            eq.append(.lowShelf(170, db: 1.8 * strength, fs: fs))                     // body (warmth when opt)
            eq.append(.peaking(3200, q: 0.8, db: 2.5 * strength, fs: fs))            // presence
            eq.append(.highShelf(10500, db: 3.0 * strength, fs: fs))                  // air
            if opt {
                eq.append(.lowShelf(150, db: 1.5, fs: fs))                            // proximity warmth 120-180
                eq.append(.peaking(350, q: 0.9, db: -2.0, fs: fs))                    // mud cut 300-400
            }
        }
        y = Cascade.apply(y, eq)
        if opt { y = extendHF(y, fs: fs) }
        if s > 0.01 || opt {
            let amt = opt ? max(s * 0.5, 0.25) : s * 0.5
            y = DeEsser.process(y, fs: fs, amount: amt)
            y = Leveler.process(y, vad: vad, fs: fs, range: 1.5 + 2.5 * (opt ? max(s, 0.5) : s))
        }
        var comp = Compressor()
        comp.thresholdDb = -17
        comp.ratio = a.micMode == .loud ? 2.5 : 1.35 + 0.65 * s
        comp.attack = 0.012; comp.release = 0.25
        let dry = y
        let compressed: [Float]
        if opt {
            // Multiband + 25% parallel compression (parallel cold path).
            let multi = splitBandCompress(dry, fs: fs)
            compressed = zip(multi, dry).map { Float(0.75 * Double($0) + 0.25 * Double($1)) }
        } else {
            compressed = comp.process(dry, fs: fs)
        }
        var out = compressed
        if opt {
            // Light second expander after compression (half depth).
            out = Expander.apply(out, vad: vad, fs: fs, depthDb: -15)
            // 15% Standard blend guard if over-processed delta >12dB.
            let peakDiff = abs(Double(out.reduce(Float(0)) { max($0, abs($1)) }) - Double(dry.reduce(Float(0)) { max($0, abs($1)) }))
            if peakDiff > 0.5 {
                let std = comp.process(dry, fs: fs)
                out = zip(out, std).map { Float(0.85 * Double($0) + 0.15 * Double($1)) }
            }
        }
        return out
    }
}
