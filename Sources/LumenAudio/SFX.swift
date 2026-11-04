import Foundation
import LumenProject

public struct SplitMix64: RandomNumberGenerator, Sendable {
    var s: UInt64
    public init(seed: UInt64) { s = seed }
    public mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// All SFX are synthesized (zero licensing risk). Peak-normalized to 1.0; gain is applied by the mixer.
public struct SFXBank: Sendable {
    public let clicks: [[Float]], keys: [[Float]], whooshIn: [Float], whooshOut: [Float]

    public init(fs: Double = 48000) {
        var rng = SplitMix64(seed: 0xC11C)

        /// Filtered-noise burst + low sine thump, exponential decay.
        func click(_ f: Double, _ ms: Double, _ thump: Double) -> [Float] {
            let n = Int(ms / 1000 * fs)
            var out = [Float](repeating: 0, count: n), lp = 0.0
            for i in 0..<n {
                let t = Double(i) / fs, env = exp(-t / (ms / 1000 / 4))
                lp += (rng.unit() * 2 - 1 - lp) * min(1, 2 * Double.pi * f / fs * 2)
                out[i] = Float((lp * 0.9 + sin(2 * Double.pi * thump * t) * 0.7 * exp(-t / 0.012)) * env)
            }
            return SFXBank.norm(out)
        }
        clicks = [(2400.0, 28.0, 140.0), (3000.0, 24.0, 160.0), (2100.0, 32.0, 130.0), (2700.0, 26.0, 150.0), (3300.0, 22.0, 170.0)]
            .map { click($0.0, $0.1, $0.2) }
        keys = [(3800.0, 14.0, 220.0), (4200.0, 12.0, 240.0), (3500.0, 16.0, 200.0), (4000.0, 13.0, 230.0)]
            .map { click($0.0, $0.1, $0.2) }

        /// Band-swept noise (state-variable filter) under a sin^2 envelope.
        func whoosh(up: Bool) -> [Float] {
            let n = Int(0.45 * fs)
            var out = [Float](repeating: 0, count: n), low = 0.0, band = 0.0
            for i in 0..<n {
                let u = Double(i) / Double(n), sweep = up ? u : 1 - u
                let fc = 400 + 2600 * sweep * sweep
                let coef = 2 * sin(Double.pi * fc / fs), x = rng.unit() * 2 - 1
                low += coef * band
                let high = x - low - 0.6 * band
                band += coef * high
                out[i] = Float(band * pow(sin(Double.pi * u), 2))
            }
            return SFXBank.norm(out)
        }
        whooshIn = whoosh(up: true)
        whooshOut = whoosh(up: false)
    }

    static func norm(_ x: [Float]) -> [Float] {
        let m = x.map { abs($0) }.max() ?? 1
        return m > 0 ? x.map { $0 / m } : x
    }

    /// Variant never repeats twice in a row; pitch +/-3% (resample), gain +/-1.5 dB (returned as jitter).
    public func render(_ kind: SFXCue.Kind, rng: inout SplitMix64, last: inout [Int: Int]) -> (samples: [Float], gainDb: Double) {
        let base: [Float]
        let key: Int
        switch kind {
        case .click: key = 0; base = pick(clicks, key, &rng, &last)
        case .key: key = 1; base = pick(keys, key, &rng, &last)
        case .whooshIn: key = 2; base = whooshIn
        case .whooshOut: key = 3; base = whooshOut
        }
        let r = 1 + (rng.unit() * 2 - 1) * 0.03
        let n = Int(Double(base.count) / r)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = Double(i) * r, i0 = Int(p)
            if i0 + 1 < base.count { out[i] = base[i0] + (base[i0 + 1] - base[i0]) * Float(p - Double(i0)) }
        }
        return (out, (rng.unit() * 2 - 1) * 1.5)
    }

    private func pick(_ v: [[Float]], _ key: Int, _ rng: inout SplitMix64, _ last: inout [Int: Int]) -> [Float] {
        var i = Int(rng.next() % UInt64(v.count))
        if i == last[key] { i = (i + 1) % v.count }
        last[key] = i
        return v[i]
    }
}