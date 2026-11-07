import Foundation
import LumenCore

public struct Biquad: Sendable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
    public mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y
        // Flush denormals on every audio path (prevents 10x slowdowns).
        if abs(y) < 1e-30 { return 0 }
        return y
    }
    public static func highpass(_ f: Double, q: Double = 0.7071, fs: Double) -> Biquad {
        let w = 2 * Double.pi * f / fs, c = cos(w), a = sin(w) / (2 * q), a0 = 1 + a
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - a) / a0)
    }
    public static func peaking(_ f: Double, q: Double, db: Double, fs: Double) -> Biquad {
        let A = pow(10, db / 40), w = 2 * Double.pi * f / fs, c = cos(w), a = sin(w) / (2 * q), a0 = 1 + a / A
        return Biquad(b0: (1 + a * A) / a0, b1: -2 * c / a0, b2: (1 - a * A) / a0, a1: -2 * c / a0, a2: (1 - a / A) / a0)
    }
    /// BS.1770 stage 1 (head-related high shelf).
    static func kShelf(fs: Double) -> Biquad {
        let f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
        let K = tan(Double.pi * f0 / fs), Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416)
        let a0 = 1 + K / Q + K * K
        return Biquad(b0: (Vh + Vb * K / Q + K * K) / a0, b1: 2 * (K * K - Vh) / a0, b2: (Vh - Vb * K / Q + K * K) / a0,
                      a1: 2 * (K * K - 1) / a0, a2: (1 - K / Q + K * K) / a0)
    }
    /// BS.1770 stage 2 (RLB high-pass); numerator is [1, -2, 1] by spec.
    static func kHigh(fs: Double) -> Biquad {
        let f0 = 38.13547087602444, Q = 0.5003270373238773, K = tan(Double.pi * f0 / fs), a0 = 1 + K / Q + K * K
        return Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (K * K - 1) / a0, a2: (1 - K / Q + K * K) / a0)
    }
}

public enum Loudness {
    /// ITU-R BS.1770-4 integrated loudness (LUFS): K-weighting, 400 ms blocks at 75% overlap, -70 abs gate, -10 LU relative gate.
    public static func integrated(_ ch: [[Float]], fs: Double = 48000) -> Double {
        guard let n = ch.first?.count, n > Int(0.4 * fs) else { return -70 }
        var cs: [[Double]] = []
        for c in ch {
            var s1 = Biquad.kShelf(fs: fs), s2 = Biquad.kHigh(fs: fs)
            var p = [Double](repeating: 0, count: n + 1)
            for i in 0..<n { let y = s2.run(s1.run(Double(c[i]))); p[i + 1] = p[i] + y * y }
            cs.append(p)
        }
        let N = Int(0.4 * fs), H = Int(0.1 * fs)
        var z: [Double] = [], s = 0
        while s + N <= n { z.append(cs.reduce(0) { $0 + ($1[s + N] - $1[s]) / Double(N) }); s += H }
        func l(_ v: Double) -> Double { -0.691 + 10 * log10(max(v, 1e-12)) }
        let g1 = z.filter { l($0) > -70 }
        guard !g1.isEmpty else { return -70 }
        let rel = l(g1.reduce(0, +) / Double(g1.count)) - 10
        let g2 = g1.filter { l($0) > rel }
        guard !g2.isEmpty else { return -70 }
        return l(g2.reduce(0, +) / Double(g2.count))
    }

    /// 4x oversampled peak (12-tap Hann-windowed sinc per phase). Only inspects regions above -10 dBFS.
    public static func truePeakDb(_ ch: [[Float]]) -> Double {
        var taps = [[Float]](repeating: [Float](repeating: 0, count: 12), count: 4)
        for ph in 0..<4 { for k in 0..<12 {
            let x = Double(k - 5) - Double(ph) / 4
            let s = abs(x) < 1e-9 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            taps[ph][k] = Float(s * (0.5 + 0.5 * cos(Double.pi * x / 6)))
        } }
        var peak: Float = 0
        for c in ch {
            let n = c.count; var i = 6
            while i < n - 7 {
                let a = abs(c[i]); peak = max(peak, a)
                if a > 0.3 { for ph in 1..<4 { var y: Float = 0; for k in 0..<12 { y += c[i + k - 5] * taps[ph][k] }; peak = max(peak, abs(y)) } }
                i += 1
            }
        }
        return 20 * log10(Double(max(peak, 1e-9)))
    }
}

/// Offline (non-causal, zero-latency) look-ahead limiter: sliding-min of required gain, smoothed by a centered moving average.
/// `half` ≈ 2 ms at 48 kHz for inter-sample headroom. Float headroom is kept
/// until here; the ceiling is a true-peak ceiling, not a hard clip.
public enum Limiter {
    public static func apply(_ ch: inout [[Float]], ceiling: Float, half: Int = 96) {
        guard let n = ch.first?.count, n > 0 else { return }
        var req = [Float](repeating: 1, count: n)
        for i in 0..<n { var m: Float = 0; for c in ch { m = max(m, abs(c[i])) }; if m > ceiling { req[i] = ceiling / m } }
        var mn = [Float](repeating: 1, count: n), dq = [Int](), head = 0
        for j in 0..<(n + half) {
            if j < n { while dq.count > head, req[dq[dq.count - 1]] >= req[j] { dq.removeLast() }; dq.append(j) }
            let i = j - half
            if i >= 0 { while dq[head] < i - half { head += 1 }; mn[i] = req[dq[head]] }
        }
        var pre = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { pre[i + 1] = pre[i] + Double(mn[i]) }
        for i in 0..<n {
            let a = max(0, i - half), b = min(n - 1, i + half), g = Float((pre[b + 1] - pre[a]) / Double(b - a + 1))
            for c in 0..<ch.count { ch[c][i] *= g }
        }
    }
}

public struct Compressor: Sendable {
    public var thresholdDb = -20.0, ratio = 3.0, attack = 0.010, release = 0.12
    public init() {}
    public func process(_ x: [Float], fs: Double) -> [Float] {
        var env = 0.0, out = x
        let ca = exp(-1 / (attack * fs)), cr = exp(-1 / (release * fs))
        // Smoothed detector gain (5 ms one-pole) so the compressor never pumps per-sample.
        var gainDb = 0.0
        let gs = exp(-1 / (0.005 * fs))
        for i in 0..<x.count {
            let a = Double(abs(x[i]))
            env = a > env ? a + ca * (env - a) : a + cr * (env - a)
            let over = 20 * log10(env + 1e-9) - thresholdDb
            let targetDb = over > 0 ? -over * (1 - 1 / ratio) : 0
            gainDb = targetDb + gs * (gainDb - targetDb)
            if gainDb < -0.05 { out[i] = x[i] * Float(pow(10, gainDb / 20)) }
        }
        return out
    }
}

/// Keystroke-aware declick (PLAN 13.1). Attenuates the 2–8 kHz band by
/// `depthDb` in ±35 ms windows around each key time when VAD is silent,
/// milder (-6 dB) when speech overlaps. Gain is ramped (≥5 ms) so no step
/// is ever audible. Pure, offline, deterministic.
public enum Declick {
    public static func process(_ x: [Float], keyTimes: [Double], vad: [ClosedRange<Double>],
                               fs: Double = 48000, depthDb: Double = -12) -> [Float] {
        guard depthDb < -0.5, !keyTimes.isEmpty, !x.isEmpty else { return x }
        let n = x.count
        // Isolate 2–8 kHz with two biquads in series.
        var hp = Biquad.highpass(2000, fs: fs)
        var lp = Biquad.lowpass(8000, fs: fs)
        var band = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let v = Double(x[i])
            let y = lp.run(hp.run(v))
            band[i] = abs(y) < 1e-30 ? 0 : Float(y)
        }
        // Per-sample suppression gain (1 = keep band, g = suppress band).
        var g = [Float](repeating: 1, count: n)
        let halfWin = Int(0.035 * fs)
        let ramp = max(Int(0.005 * fs), 1)
        let fullGain = Float(pow(10.0, depthDb / 20.0))
        let mildGain = Float(pow(10.0, -6.0 / 20.0))
        for key in keyTimes {
            let center = Int((key * fs).rounded())
            guard center > -halfWin, center < n + halfWin else { continue }
            let speech = vad.contains { $0.lowerBound <= key && key <= $0.upperBound }
            let target = speech ? mildGain : fullGain
            // Ramped window: linear attack/release over `ramp` samples.
            let lo = max(center - halfWin, 0), hi = min(center + halfWin, n - 1)
            for i in lo...hi {
                let edge = min(i - lo, hi - i)
                let rampT = ramp > 0 ? min(1, Float(edge) / Float(ramp)) : 1
                let desired = 1 - (1 - target) * rampT
                g[i] = min(g[i], desired)
            }
        }
        var out = x
        for i in 0..<n {
            out[i] = x[i] - band[i] * (1 - g[i])
        }
        return out
    }
}

/// Voice activity: 20 ms RMS frames, adaptive threshold (noise floor + 10 dB) with hysteresis and 300 ms hangover.
public enum VAD {
    public static func regions(_ x: [Float], fs: Double = 48000) -> [ClosedRange<Double>] {
        let hop = Int(0.02 * fs), n = x.count / hop
        guard n > 3 else { return [] }
        var db = [Double](repeating: -120, count: n)
        for f in 0..<n { var s = 0.0; for i in 0..<hop { let v = Double(x[f * hop + i]); s += v * v }; db[f] = 10 * log10(s / Double(hop) + 1e-12) }
        let floorDb = db.sorted()[n / 10], on = max(floorDb + 10, -50), off = on - 4
        var out: [ClosedRange<Double>] = [], active = false, start = 0, last = 0
        for f in 0..<n {
            if db[f] > (active ? off : on) { if !active { active = true; start = f }; last = f }
            else if active, f - last > 15 { out.append(Double(start) * 0.02 ... Double(last + 1) * 0.02); active = false }
        }
        if active { out.append(Double(start) * 0.02 ... Double(last + 1) * 0.02) }
        return out.filter { $0.upperBound - $0.lowerBound >= 0.12 }
    }
}

public protocol Denoiser: Sendable { func process(_ x: [Float]) -> [Float] }

/// Fallback when RNNoise isn't vendored: a downward expander driven by 10 ms RMS against a percentile noise floor.
public struct SpectralGate: Denoiser {
    public init() {}
    public func process(_ x: [Float]) -> [Float] {
        let hop = 480, n = x.count / hop
        guard n > 4 else { return x }
        var db = [Double](repeating: -120, count: n)
        for f in 0..<n { var s = 0.0; for i in 0..<hop { let v = Double(x[f * hop + i]); s += v * v }; db[f] = 10 * log10(s / Double(hop) + 1e-12) }
        let thr = min(db.sorted()[n / 10] + 8, -40)
        var g = [Double](repeating: 1, count: n), cur = 1.0
        for f in 0..<n {
            let target = db[f] > thr ? 1.0 : pow(10, -18.0 / 20)
            cur += (target - cur) * (target > cur ? 0.5 : 0.08)
            g[f] = cur
        }
        var out = x
        for f in 0..<n { let a = g[f], b = f + 1 < n ? g[f + 1] : g[f]
            for i in 0..<hop { out[f * hop + i] *= Float(a + (b - a) * Double(i) / Double(hop)) } }
        return out
    }
}

#if canImport(CRNNoise)
import CRNNoise
public struct RNNoiseDenoiser: Denoiser {
    public init() {}
    /// RNNoise algorithmic latency in samples at 48 kHz (one 480-sample frame).
    static let latencySamples = 480
    public func process(_ x: [Float]) -> [Float] {
        guard let st = rnnoise_create(nil) else { return x }
        defer { rnnoise_destroy(st) }
        var out = x, inb = [Float](repeating: 0, count: 480), ob = inb, i = 0
        while i + 480 <= x.count {
            for k in 0..<480 { inb[k] = x[i + k] * 32768 }
            _ = rnnoise_process_frame(st, &ob, &inb)
            for k in 0..<480 { out[i + k] = ob[k] / 32768 }
            i += 480
        }
        // Flush final partial frame with zero padding (never drop the tail).
        if i < x.count {
            let tail = x.count - i
            inb = [Float](repeating: 0, count: 480)
            for k in 0..<tail { inb[k] = x[i + k] * 32768 }
            _ = rnnoise_process_frame(st, &ob, &inb)
            for k in 0..<tail { out[i + k] = ob[k] / 32768 }
        }
        // Compensate algorithmic latency: the denoised path is delayed by one
        // frame. Shift left so voice stays aligned to the timeline; pad the
        // end by repeating the last sample (dry path is primary, so a flat
        // 10 ms tail is inaudible).
        let lat = Self.latencySamples
        if x.count > lat {
            var aligned = [Float](repeating: 0, count: x.count)
            for j in 0..<(x.count - lat) { aligned[j] = out[j + lat] }
            let lastVal = out[x.count - 1]
            for j in (x.count - lat)..<x.count { aligned[j] = lastVal }
            out = aligned
        }
        return out
    }
}
public let defaultDenoiser: any Denoiser = RNNoiseDenoiser()
#else
public let defaultDenoiser: any Denoiser = SpectralGate()
#endif