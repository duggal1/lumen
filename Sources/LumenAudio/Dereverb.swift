import Foundation
import LumenCore

/// Radix-2 complex FFT. Forward in place. `inverse` leaves the real signal in
/// `re`. All tables are built once, so processing allocates nothing per frame
/// beyond the caller's buffers.
struct Radix2FFT {
    let n: Int
    private let cosT: [Float], sinT: [Float], rev: [Int]

    init(n: Int) {
        self.n = n
        var c = [Float](repeating: 0, count: n / 2), s = c
        for i in 0..<(n / 2) {
            let a = -2 * Double.pi * Double(i) / Double(n)
            c[i] = Float(cos(a)); s[i] = Float(sin(a))
        }
        var r = [Int](repeating: 0, count: n)
        let bits = n.trailingZeroBitCount
        for i in 0..<n {
            var x = i, y = 0
            for _ in 0..<bits { y = (y << 1) | (x & 1); x >>= 1 }
            r[i] = y
        }
        cosT = c; sinT = s; rev = r
    }

    func transform(_ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<n {
            let j = rev[i]
            if j > i { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let half = len / 2, step = n / len
            var base = 0
            while base < n {
                for k in 0..<half {
                    let wr = cosT[k * step], wi = sinT[k * step]
                    let a = base + k, b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
                base += len
            }
            len <<= 1
        }
    }

    /// IFFT(X) = conj(DFT(conj(X))) / N.
    func inverse(_ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<n { im[i] = -im[i] }
        transform(&re, &im)
        let scale = 1 / Float(n)
        for i in 0..<n { re[i] *= scale; im[i] = -im[i] * scale }
    }
}

/// Blind room decay estimate from the free-decay slope after speech offsets.
/// It measures the room, not the start of the recording (which has no tail).
enum RoomEstimate {
    static func rt60(_ x: [Float], vad: [ClosedRange<Double>]) -> Double {
        let hop = 480, n = x.count / hop
        guard n > 100, !vad.isEmpty else { return 0.5 }
        var db = [Double](repeating: -120, count: n)
        for f in 0..<n {
            var sum = 0.0
            for i in 0..<hop { let v = Double(x[f * hop + i]); sum += v * v }
            db[f] = 10 * log10(sum / Double(hop) + 1e-12)
        }
        let floorDb = db.sorted()[n / 10]
        var candidates: [Double] = []
        for region in vad {
            let a = Int(region.upperBound * 100) + 5, b = a + 30
            guard b < n else { continue }
            let seg = (a...b).filter { db[$0] > floorDb + 8 }
            guard seg.count >= 10 else { continue }
            let m = Double(seg.count)
            let mx = seg.reduce(0.0) { $0 + Double($1) } / m
            let my = seg.reduce(0.0) { $0 + db[$1] } / m
            var sxy = 0.0, sxx = 0.0
            for i in seg { let dx = Double(i) - mx; sxy += dx * (db[i] - my); sxx += dx * dx }
            let slope = sxy / max(sxx, 1e-9) * 100              // dB per second
            if slope < -15, slope > -400 { candidates.append(-60 / slope) }
        }
        let value = candidates.count >= 3 ? candidates.sorted()[candidates.count / 2] : 0.5
        return min(max(value, 0.2), 1.2)
    }
}

/// Late-reverberation suppression using Polack's exponential decay model with
/// a decision-directed spectral gain. The late tail is estimated from the
/// smoothed power a few frames earlier, so direct speech is protected while
/// the part of the signal that is still decaying after a phrase is attenuated.
public struct LateReverbSuppressor: Sendable {
    /// 0...1. Maps to a -3...-12 dB floor on the late tail.
    public var amount: Double
    public var rt60: Double?
    /// Voice regions in the microphone file's own time, used for RT60.
    public var vad: [ClosedRange<Double>]

    public init(amount: Double = 0.5, rt60: Double? = nil, vad: [ClosedRange<Double>] = []) {
        self.amount = amount; self.rt60 = rt60; self.vad = vad
    }

    public func process(_ x: [Float]) -> [Float] {
        let N = 1024, H = 256, bins = N / 2 + 1, D = 9, fs = AudioIO.fs
        guard amount > 0.01, x.count > N * 8 else { return x }
        let t60 = min(max(rt60 ?? RoomEstimate.rt60(x, vad: vad), 0.2), 1.2)
        // Polack: the tail power falls 60 dB per RT60, i.e. 10^-6 per RT60.
        // Over the D-frame prediction lag the expected power ratio is
        // 10^(6*D*H/fs/t60), so the prediction decays by its inverse.
        let decay = Float(pow(10, -6 * Double(D * H) / fs / t60))
        let kappa = Float(1 + amount)
        let floorPower = Float(pow(10, -(3 + 9 * amount) / 10))

        let fft = Radix2FFT(n: N)
        let win = (0..<N).map { Float(sin(Double.pi * Double($0) / Double(N))) }
        let pad = N
        let padded = [Float](repeating: 0, count: pad) + x + [Float](repeating: 0, count: pad + H)
        let frames = (padded.count - N) / H + 1
        var y = [Float](repeating: 0, count: padded.count)
        var re = [Float](repeating: 0, count: N), im = re
        var history = [Float](repeating: 0, count: (D + 1) * bins)
        var smooth = [Float](repeating: 0, count: bins), flat = smooth
        var gain = [Float](repeating: 1, count: bins)
        var previous = gain, shaped = gain

        for frame in 0..<frames {
            let offset = frame * H
            for i in 0..<N { re[i] = padded[offset + i] * win[i]; im[i] = 0 }
            fft.transform(&re, &im)
            let current = (frame % (D + 1)) * bins
            let old = ((frame + 1) % (D + 1)) * bins
            for k in 0..<bins {
                let power = re[k] * re[k] + im[k] * im[k]
                smooth[k] = 0.6 * smooth[k] + 0.4 * power
            }
            // A single FFT bin of noise is exponentially distributed, so the
            // raw ratio is far too erratic to drive a gain. Averaging over
            // five neighbouring bins raises the effective degrees of freedom
            // and makes the decay estimate stable.
            for k in 0..<bins {
                let a = max(k - 1, 0), b = min(k + 1, bins - 1)
                let c = max(k - 2, 0), d = min(k + 2, bins - 1)
                flat[k] = (smooth[c] + 2 * smooth[a] + 3 * smooth[k] + 2 * smooth[b] + smooth[d]) / 9
            }
            for k in 0..<bins {
                let ratio = decay * history[old + k] / max(flat[k], 1e-12)
                let u = max(ratio - 0.25, 0) / 0.75
                let target = max(floorPower, 1 - kappa * u).squareRoot()
                gain[k] = previous[k] + (target - previous[k]) * (target < previous[k] ? 0.7 : 0.5)
                history[current + k] = flat[k]
            }
            for k in 0..<bins {
                shaped[k] = 0.25 * gain[max(k - 1, 0)] + 0.5 * gain[k] + 0.25 * gain[min(k + 1, bins - 1)]
                previous[k] = gain[k]
            }
            for k in 0..<bins {
                re[k] *= shaped[k]; im[k] *= shaped[k]
                if k > 0 && k < N / 2 { re[N - k] *= shaped[k]; im[N - k] *= shaped[k] }
            }
            fft.inverse(&re, &im)
            for i in 0..<N { y[offset + i] += re[i] * win[i] * 0.5 }
        }
        return Array(y[pad..<(pad + x.count)])
    }
}

/// Self-calibrating downward expander. The threshold sits between the
/// recording's own noise floor and its speech level, so it sinks room noise
/// between words without touching normal speech. Gain is decided per 10 ms
/// frame and smoothed with a fast attack / 60 ms release, so a word is never
/// chopped and the floor still recovers inside a normal pause.
public struct Expander: Sendable {
    public var ratio = 1.8, maxCutDb = 14.0, attack = 0.005, release = 0.06
    public init() {}

    public func process(_ x: [Float], fs: Double) -> [Float] {
        let hop = max(Int(0.01 * fs), 1), n = x.count / hop
        guard n > 40 else { return x }
        var db = [Double](repeating: -120, count: n)
        for f in 0..<n {
            var sum = 0.0
            for i in 0..<hop { let v = Double(x[f * hop + i]); sum += v * v }
            db[f] = 10 * log10(sum / Double(hop) + 1e-12)
        }
        let sorted = db.sorted(), lo = sorted[n / 10], hi = sorted[n * 9 / 10]
        guard hi - lo > 12 else { return x }
        let threshold = lo + 0.35 * (hi - lo)

        let frame = Double(hop) / fs
        let ca = exp(-frame / attack), cr = exp(-frame / release)
        var gain = [Double](repeating: 1, count: n), g = 1.0
        for f in 0..<n {
            let target = db[f] < threshold
                ? pow(10, max((db[f] - threshold) * (ratio - 1), -maxCutDb) / 20)
                : 1
            g = target < g ? target + ca * (g - target) : target + cr * (g - target)
            gain[f] = g
        }

        var out = x
        for i in 0..<x.count {
            let p = Double(i) / Double(hop) - 0.5           // frame centres
            let a = min(max(Int(p.rounded(.down)), 0), n - 1), b = min(a + 1, n - 1)
            out[i] = x[i] * Float(lerp(gain[a], gain[b], clamp(p - Double(a), 0, 1)))
        }
        return out
    }
}
