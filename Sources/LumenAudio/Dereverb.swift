import Foundation
import LumenCore

/// Radix-2 complex FFT. Forward in place. Inverse: `transform(&im, &re)` leaves `N * x` in `re`.
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
}

/// Runs `body` on overlapping segments in parallel and crossfades with
/// complementary smoothstep ramps (the sum is exactly 1).
enum Segmented {
    final class Slots: @unchecked Sendable {
        private var a: [[Float]]
        private let lock = NSLock()
        init(_ n: Int) { a = [[Float]](repeating: [], count: n) }
        func set(_ i: Int, _ v: [Float]) { lock.lock(); a[i] = v; lock.unlock() }
        func all() -> [[Float]] { lock.lock(); defer { lock.unlock() }; return a }
    }

    static func run(_ ins: [[Float]], fs: Double, segment: Double, overlap: Double,
                    _ body: @Sendable ([[Float]]) -> [Float]) -> [Float] {
        guard let n = ins.first?.count, n > 0 else { return ins.first ?? [] }
        let S = Int(segment * fs), O = Int(overlap * fs), count = max((n + S - 1) / S, 1)
        if count == 1 { return body(ins) }
        let slots = Slots(count)
        DispatchQueue.concurrentPerform(iterations: count) { i in
            let a = max(i * S - O, 0), b = min((i + 1) * S + O, n)
            slots.set(i, body(ins.map { Array($0[a..<b]) }))
        }
        var out = [Float](repeating: 0, count: n)
        for (i, seg) in slots.all().enumerated() {
            let a = max(i * S - O, 0)
            for k in 0..<seg.count {
                let g = a + k
                var w: Float = 1
                if i > 0 { w *= Float(smoothstep(Double(g - (i * S - O)) / Double(2 * O))) }
                if i < count - 1 { w *= 1 - Float(smoothstep(Double(g - ((i + 1) * S - O)) / Double(2 * O))) }
                out[g] += seg[k] * w
            }
        }
        return out
    }
}

/// Weighted Prediction Error dereverberation (Nakatani 2010), single channel,
/// offline, iterative. Per frequency bin the late reverb is a delayed linear
/// prediction from past frames; weights `1/|X|^2` favour the quiet tails.
public struct WPE: Sendable {
    public var taps = 20, delay = 3, iterations = 3
    /// WPE band. Above it the signal passes unchanged; the post-filter covers it.
    public var maxHz = 8000.0
    public var segment = 10.0, overlap = 1.0
    public init() {}

    public func process(_ x: [Float]) -> [Float] {
        Segmented.run([x], fs: AudioIO.fs, segment: segment, overlap: overlap) { self.run($0[0]) }
    }

    private func run(_ x: [Float]) -> [Float] {
        let N = 2048, H = 512, bins = N / 2 + 1, fs = AudioIO.fs
        guard x.count > N * 8 else { return x }
        let K = taps, D = delay
        let kmax = min(Int(maxHz / fs * Double(N)), bins - 1), nb = kmax + 1
        let fft = Radix2FFT(n: N)
        let win = (0..<N).map { Float(sin(Double.pi * Double($0) / Double(N))) }
        let pad = N
        let xp = [Float](repeating: 0, count: pad) + x + [Float](repeating: 0, count: pad + H)
        let F = (xp.count - N) / H + 1
        var sr = [Float](repeating: 0, count: F * bins), si = sr
        var re = [Float](repeating: 0, count: N), im = re
        for l in 0..<F {
            let o = l * H
            for i in 0..<N { re[i] = xp[o + i] * win[i]; im[i] = 0 }
            fft.transform(&re, &im)
            for k in 0..<bins { sr[l * bins + k] = re[k]; si[l * bins + k] = im[k] }
        }

        func buf(_ n: Int) -> UnsafeMutablePointer<Double> {
            let p = UnsafeMutablePointer<Double>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        let yr = buf(F), yi = buf(F), cr = buf(F), ci = buf(F), w = buf(F)
        let ar = buf(K), ai = buf(K), pRe = buf(K), pIm = buf(K), gr = buf(K), gi = buf(K)
        let Rr = buf(K * K), Ri = buf(K * K), Lr = buf(K * K), Li = buf(K * K)
        defer { for p in [yr, yi, cr, ci, w, ar, ai, pRe, pIm, gr, gi, Rr, Ri, Lr, Li] { p.deallocate() } }
        var xr = [Double](repeating: 0, count: nb * F), xi = xr

        for k in 0..<nb {
            var meanP = 0.0
            for l in 0..<F {
                let a = Double(sr[l * bins + k]), b = Double(si[l * bins + k])
                yr[l] = a; yi[l] = b; cr[l] = a; ci[l] = b; meanP += a * a + b * b
            }
            meanP /= Double(F)
            let floorP = max(meanP * 1e-4, 1e-14)
            if meanP > 1e-12 {
                for _ in 0..<iterations {
                    for l in 0..<F {
                        let lo = max(l - 1, 0), hi = min(l + 1, F - 1)
                        var s = 0.0
                        for j in lo...hi { s += cr[j] * cr[j] + ci[j] * ci[j] }
                        w[l] = 1 / max(s / Double(hi - lo + 1), floorP)
                    }
                    for i in 0..<(K * K) { Rr[i] = 0; Ri[i] = 0 }
                    for i in 0..<K { pRe[i] = 0; pIm[i] = 0 }
                    for l in D..<F {
                        for t in 0..<K {
                            let idx = l - D - t
                            ar[t] = idx >= 0 ? yr[idx] : 0
                            ai[t] = idx >= 0 ? yi[idx] : 0
                        }
                        let wl = w[l], ylr = yr[l], yli = yi[l]
                        for a in 0..<K {
                            let xa = ar[a] * wl, xb = ai[a] * wl
                            for b in 0...a {                              // lower triangle of R = sum w * y y^H
                                Rr[a * K + b] += xa * ar[b] + xb * ai[b]
                                Ri[a * K + b] += xb * ar[b] - xa * ai[b]
                            }
                            pRe[a] += xa * ylr + xb * yli                  // P = sum w * y * conj(Y)
                            pIm[a] += xb * ylr - xa * yli
                        }
                    }
                    var tr = 0.0
                    for i in 0..<K { tr += Rr[i * K + i] }
                    let load = tr / Double(K) * 1e-4 + 1e-12
                    for i in 0..<K { Rr[i * K + i] += load }
                    guard Self.solve(K, Rr, Ri, pRe, pIm, Lr, Li, gr, gi) else { break }
                    for l in 0..<F {                                       // X = Y - sum conj(g) * Y[l-D-t]
                        var er = yr[l], ei = yi[l]
                        for t in 0..<K {
                            let idx = l - D - t
                            if idx < 0 { break }
                            er -= gr[t] * yr[idx] + gi[t] * yi[idx]
                            ei -= gr[t] * yi[idx] - gi[t] * yr[idx]
                        }
                        cr[l] = er; ci[l] = ei
                    }
                }
            }
            for l in 0..<F {
                var lr = yr[l] - cr[l], li = yi[l] - ci[l]
                let pl = lr * lr + li * li, py = yr[l] * yr[l] + yi[l] * yi[l]
                if pl > 0.8 * py, pl > 0 {
                    let f = (0.8 * py / pl).squareRoot()
                    lr *= f; li *= f
                }
                xr[k * F + l] = yr[l] - lr; xi[k * F + l] = yi[l] - li
            }
        }

        var y = [Float](repeating: 0, count: xp.count)
        for l in 0..<F {
            for k in 0..<bins {
                let a = k <= kmax ? Float(xr[k * F + l]) : sr[l * bins + k]
                let b = k <= kmax ? Float(xi[k * F + l]) : si[l * bins + k]
                re[k] = a; im[k] = b
                if k > 0 && k < N / 2 { re[N - k] = a; im[N - k] = -b }
            }
            fft.transform(&im, &re)
            let o = l * H
            for i in 0..<N { y[o + i] += re[i] / Float(N) * win[i] * 0.5 }
        }
        return Array(y[pad..<(pad + x.count)])
    }

    /// Complex Hermitian positive-definite solve `R g = p` by Cholesky. `R` lower triangle valid.
    private static func solve(_ K: Int, _ Rr: UnsafeMutablePointer<Double>, _ Ri: UnsafeMutablePointer<Double>,
                              _ pRe: UnsafeMutablePointer<Double>, _ pIm: UnsafeMutablePointer<Double>,
                              _ Lr: UnsafeMutablePointer<Double>, _ Li: UnsafeMutablePointer<Double>,
                              _ gr: UnsafeMutablePointer<Double>, _ gi: UnsafeMutablePointer<Double>) -> Bool {
        for j in 0..<K {
            var s = Rr[j * K + j]
            for m in 0..<j { s -= Lr[j * K + m] * Lr[j * K + m] + Li[j * K + m] * Li[j * K + m] }
            guard s > 1e-30 else { return false }
            let d = s.squareRoot()
            Lr[j * K + j] = d; Li[j * K + j] = 0
            for i in (j + 1)..<K {
                var a = Rr[i * K + j], b = Ri[i * K + j]
                for m in 0..<j {
                    let lr = Lr[i * K + m], li = Li[i * K + m]
                    let mr = Lr[j * K + m], mi = Li[j * K + m]
                    a -= lr * mr + li * mi; b -= li * mr - lr * mi          // L[i][m] * conj(L[j][m])
                }
                Lr[i * K + j] = a / d; Li[i * K + j] = b / d
            }
        }
        for i in 0..<K {                                                    // L z = p
            var a = pRe[i], b = pIm[i]
            for m in 0..<i {
                let lr = Lr[i * K + m], li = Li[i * K + m]
                a -= lr * gr[m] - li * gi[m]; b -= lr * gi[m] + li * gr[m]
            }
            let d = Lr[i * K + i]
            gr[i] = a / d; gi[i] = b / d
        }
        for i in stride(from: K - 1, through: 0, by: -1) {                  // L^H g = z
            var a = gr[i], b = gi[i]
            for m in (i + 1)..<K {
                let lr = Lr[m * K + i], li = -Li[m * K + i]
                a -= lr * gr[m] - li * gi[m]; b -= lr * gi[m] + li * gr[m]
            }
            let d = Lr[i * K + i]
            gr[i] = a / d; gi[i] = b / d
        }
        return true
    }
}

/// Post-filter: Wiener gain against (stationary noise floor + late-reverb
/// residual + decay-model tail). `late` is what WPE removed; its power is the
/// best available estimate of the reverb that survives.
public struct ResidualSuppressor: Sendable {
    public var noise: Double, reverb: Double, rt60: Double
    public init(noise: Double = 0.9, reverb: Double = 0.8, rt60: Double = 0.5) {
        self.noise = noise; self.reverb = reverb; self.rt60 = rt60
    }

    public func process(x: [Float], late: [Float]) -> [Float] {
        Segmented.run([x, late], fs: AudioIO.fs, segment: 12, overlap: 1.5) { self.run($0[0], $0[1]) }
    }

    private func run(_ x: [Float], _ late: [Float]) -> [Float] {
        let N = 1024, H = 256, bins = N / 2 + 1, fs = AudioIO.fs
        guard x.count > N * 8, late.count == x.count else { return x }
        let fft = Radix2FFT(n: N)
        let win = (0..<N).map { Float(sin(Double.pi * Double($0) / Double(N))) }
        let pad = N
        let xp = [Float](repeating: 0, count: pad) + x + [Float](repeating: 0, count: pad + H)
        let lp = [Float](repeating: 0, count: pad) + late + [Float](repeating: 0, count: pad + H)
        let F = (xp.count - N) / H + 1
        var xr = [Float](repeating: 0, count: F * bins), xi = xr, px = xr, pl = xr
        var re = [Float](repeating: 0, count: N), im = re
        for l in 0..<F {
            let o = l * H
            for i in 0..<N { re[i] = xp[o + i] * win[i]; im[i] = 0 }
            fft.transform(&re, &im)
            for k in 0..<bins {
                let i = l * bins + k
                xr[i] = re[k]; xi[i] = im[k]; px[i] = re[k] * re[k] + im[k] * im[k]
            }
            for i in 0..<N { re[i] = lp[o + i] * win[i]; im[i] = 0 }
            fft.transform(&re, &im)
            for k in 0..<bins { pl[l * bins + k] = re[k] * re[k] + im[k] * im[k] }
        }
        // Smoothed power (8-frame box in time, 5-bin box in frequency) for the noise floor and the tail model.
        var tm = [Float](repeating: 0, count: F * bins), acc = [Float](repeating: 0, count: bins)
        for l in 0..<F {
            for k in 0..<bins {
                acc[k] += px[l * bins + k]
                if l >= 8 { acc[k] -= px[(l - 8) * bins + k] }
                tm[l * bins + k] = max(acc[k], 0) / Float(min(l + 1, 8))
            }
        }
        var ps = tm
        for l in 0..<F {
            for k in 0..<bins {
                let a = max(k - 2, 0), b = min(k + 2, bins - 1)
                var s: Float = 0
                for j in a...b { s += tm[l * bins + j] }
                ps[l * bins + k] = s / Float(b - a + 1)
            }
        }
        // Stationary noise floor per bin: 10th percentile of the smoothed power (x1.35 bias compensation).
        var nz = [Float](repeating: 0, count: bins), col = [Float](repeating: 0, count: F)
        for k in 0..<bins {
            for l in 0..<F { col[l] = ps[l * bins + k] }
            col.sort()
            nz[k] = max(col[F / 10] * 1.35, 1e-12)
        }
        let ns = Float(noise), rv = Float(reverb), strength = max(noise, reverb)
        let Dp = 12, decay = Float(pow(10, -6 * Double(Dp * H) / fs / max(rt60, 0.15)))
        let over = Float(1 + 1.2 * strength)
        var gam = [Float](repeating: 0, count: F * bins)
        for l in 0..<F {
            let lo = max(l - 1, 0), hi = min(l + 1, F - 1)
            for k in 0..<bins {
                var lt: Float = 0
                for j in lo...hi { lt += pl[j * bins + k] }
                lt /= Float(hi - lo + 1)
                let pol = l >= Dp ? decay * ps[(l - Dp) * bins + k] : 0
                let phi = over * (ns * nz[k] + rv * lt + 0.6 * rv * pol) + 1e-14
                gam[l * bins + k] = px[l * bins + k] / phi
            }
        }
        let gMinBase = Float(pow(10, -(10 + 16 * strength) / 20))
        let gMinK = (0..<bins).map { k -> Float in
            let f = Double(k) * fs / Double(N)
            return pow(gMinBase, Float(1 - 0.35 * smoothstep((f - 2500) / 3000)))
        }
        let aDD: Float = 0.9, expo = Float(1 + 0.5 * strength)
        var prev = [Float](repeating: 0, count: bins), raw = prev, gs = prev
        var y = [Float](repeating: 0, count: xp.count)
        for l in 0..<F {
            for k in 0..<bins {
                let i = l * bins + k
                let ahead: Float = l + 1 < F ? 0.7 * gam[i + bins] : 0
                let xiv = aDD * prev[k] + (1 - aDD) * max(max(gam[i], ahead) - 1, 0)
                var g = pow(xiv / (1 + xiv), expo)
                g = max(g, gMinK[k])
                prev[k] = g * g * gam[i]
                raw[k] = g
            }
            for k in 0..<bins {
                gs[k] = 0.25 * raw[max(k - 1, 0)] + 0.5 * raw[k] + 0.25 * raw[min(k + 1, bins - 1)]
            }
            for k in 0..<bins {
                let i = l * bins + k
                re[k] = xr[i] * gs[k]; im[k] = xi[i] * gs[k]
                if k > 0 && k < N / 2 { re[N - k] = re[k]; im[N - k] = -im[k] }
            }
            fft.transform(&im, &re)
            let o = l * H
            for i in 0..<N { y[o + i] += re[i] / Float(N) * win[i] * 0.5 }
        }
        return Array(y[pad..<(pad + x.count)])
    }
}

enum RoomEstimate {
    /// Free-decay slope of the 10 ms energy envelope 50-350 ms after each speech
    /// offset; median over offsets, default 0.5 s.
    static func rt60(_ x: [Float], vad: [ClosedRange<Double>]) -> Double {
        let hop = 480, n = x.count / hop
        guard n > 100, !vad.isEmpty else { return 0.5 }
        var db = [Double](repeating: -120, count: n)
        for f in 0..<n {
            var s = 0.0
            for i in 0..<hop { let v = Double(x[f * hop + i]); s += v * v }
            db[f] = 10 * log10(s / Double(hop) + 1e-12)
        }
        let floorDb = db.sorted()[n / 10]
        var c: [Double] = []
        for r in vad {
            let a = Int(r.upperBound * 100) + 5, b = a + 30
            guard b < n else { continue }
            let seg = (a...b).filter { db[$0] > floorDb + 8 }
            guard seg.count >= 10 else { continue }
            let m = Double(seg.count)
            let mx = seg.reduce(0.0) { $0 + Double($1) } / m
            let my = seg.reduce(0.0) { $0 + db[$1] } / m
            var sxy = 0.0, sxx = 0.0
            for i in seg {
                let dx = Double(i) - mx
                sxy += dx * (db[i] - my); sxx += dx * dx
            }
            let slope = sxy / max(sxx, 1e-9) * 100
            if slope < -15, slope > -400 { c.append(-60 / slope) }
        }
        let v = c.count >= 3 ? c.sorted()[c.count / 2] : 0.5
        return min(max(v, 0.2), 1.2)
    }
}
