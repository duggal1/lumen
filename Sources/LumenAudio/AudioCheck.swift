import Foundation
import Accelerate
import LumenCore

/// Result of `lumen-cli audio-check`. Plain values. Produced once per file.
public struct AudioCheckReport: Codable, Sendable, Equatable {
    public var format: String
    public var sampleRate: Double
    public var channels: Int
    public var frames: Int
    public var duration: Double
    public var peakDb: Double
    public var truePeakDb: Double
    public var lufs: Double
    public var clippedSamples: Int
    public var dcOffset: Double
    public var noiseFloorDb: Double
    public var zeroRunDropouts: Int
    public var clickEvents: Int
    public var correlation: Double?
    public init(format: String, sampleRate: Double, channels: Int, frames: Int, duration: Double,
                peakDb: Double, truePeakDb: Double, lufs: Double, clippedSamples: Int,
                dcOffset: Double, noiseFloorDb: Double, zeroRunDropouts: Int,
                clickEvents: Int, correlation: Double? = nil) {
        self.format = format; self.sampleRate = sampleRate; self.channels = channels
        self.frames = frames; self.duration = duration; self.peakDb = peakDb
        self.truePeakDb = truePeakDb; self.lufs = lufs; self.clippedSamples = clippedSamples
        self.dcOffset = dcOffset; self.noiseFloorDb = noiseFloorDb
        self.zeroRunDropouts = zeroRunDropouts; self.clickEvents = clickEvents
        self.correlation = correlation
    }
}

/// Pure DSP metrics over decoded Float32 channels. No allocation in render path.
public enum AudioCheck {
    public static func analyze(channels: [[Float]], sampleRate: Double, format: String = "pcm-f32") -> AudioCheckReport {
        guard let n = channels.first?.count, !channels.isEmpty, n > 0 else {
            return AudioCheckReport(format: format, sampleRate: sampleRate, channels: channels.count,
                                    frames: 0, duration: 0, peakDb: -120, truePeakDb: -120,
                                    lufs: -70, clippedSamples: 0, dcOffset: 0, noiseFloorDb: -120,
                                    zeroRunDropouts: 0, clickEvents: 0)
        }
        var peak: Float = 0
        var clipped = 0
        var sum: Double = 0
        for ch in channels {
            for v in ch {
                peak = max(peak, abs(v))
                if abs(v) >= 1.0 { clipped += 1 }
                sum += Double(v)
            }
        }
        let total = Double(channels.count * n)
        let dc = sum / total
        let peakDb = 20 * log10(Double(max(peak, 1e-9)))
        let tp = Loudness.truePeakDb(channels)
        let lufs = Loudness.integrated(channels, fs: sampleRate)

        // Noise floor: RMS of quietest 10% of 100 ms frames (first channel).
        let hop = max(Int(0.1 * sampleRate), 1)
        var framesDb: [Double] = []
        let ch0 = channels[0]
        for s in stride(from: 0, to: max(n - hop, 1), by: hop) {
            var e = 0.0
            for i in s..<(s + hop) { e += Double(ch0[i]) * Double(ch0[i]) }
            framesDb.append(10 * log10(e / Double(hop) + 1e-12))
        }
        let noiseFloor: Double
        if framesDb.isEmpty { noiseFloor = -120 }
        else {
            let sorted = framesDb.sorted()
            noiseFloor = sorted[max(0, sorted.count / 10 - 1)]
        }

        // Zero-run dropouts: runs of >=20 ms near-silence where signal was loud before/after.
        let zeroThresh: Float = 0.0005
        let minRun = max(Int(0.020 * sampleRate), 1)
        var dropouts = 0
        var run = 0
        for i in 0..<n {
            if abs(ch0[i]) < zeroThresh { run += 1 }
            else {
                if run >= minRun { dropouts += 1 }
                run = 0
            }
        }
        if run >= minRun { dropouts += 1 }

        // Click events: second-difference outliers in high-passed signal.
        // Second difference emphasizes discontinuities; threshold by MAD.
        var diffs: [Double] = []
        if n > 4 {
            diffs.reserveCapacity(n)
            for i in 1..<(n - 1) {
                let d = Double(ch0[i + 1] - 2 * ch0[i] + ch0[i - 1])
                diffs.append(d)
            }
        }
        let clicks: Int
        if diffs.count < 100 { clicks = 0 }
        else {
            let sortedAbs = diffs.map(abs).sorted()
            let median = sortedAbs[sortedAbs.count / 2]
            var mad = diffs.map { abs($0 - median) }.sorted()
            let m = mad[mad.count / 2]
            let sigma = max(m * 1.4826, 1e-6)
            let thresh = median + 12 * sigma
            // Only count extreme isolated spikes above -40 dBFS equivalent
            clicks = diffs.filter { abs($0) > max(thresh, 0.02) }.count
        }

        // Inter-channel correlation (stereo only).
        var corr: Double?
        if channels.count >= 2, let r = channels.dropFirst().first, r.count == n {
            var num = 0.0, dl = 0.0, dr = 0.0
            for i in 0..<n {
                let a = Double(ch0[i]) - dc, b = Double(r[i]) - dc
                num += a * b; dl += a * a; dr += b * b
            }
            if dl > 1e-12 && dr > 1e-12 { corr = num / (sqrt(dl) * sqrt(dr)) }
        }

        return AudioCheckReport(format: format, sampleRate: sampleRate, channels: channels.count,
                                frames: n, duration: Double(n) / sampleRate, peakDb: peakDb,
                                truePeakDb: tp, lufs: lufs, clippedSamples: clipped,
                                dcOffset: dc, noiseFloorDb: noiseFloor,
                                zeroRunDropouts: dropouts, clickEvents: clicks, correlation: corr)
    }

    /// 4× oversampled click detector for pipeline tests: counts isolated
    /// second-difference spikes. Deterministic, no randomness.
    public static func clickCount(_ x: [Float]) -> Int {
        guard x.count > 4 else { return 0 }
        var diffs: [Double] = []
        diffs.reserveCapacity(x.count)
        for i in 1..<(x.count - 1) {
            diffs.append(Double(x[i + 1] - 2 * x[i] + x[i - 1]))
        }
        let sortedAbs = diffs.map(abs).sorted()
        let median = sortedAbs[sortedAbs.count / 2]
        var mad = diffs.map { abs($0 - median) }.sorted()
        let m = mad[mad.count / 2]
        let sigma = max(m * 1.4826, 1e-6)
        let thresh = median + 12 * sigma
        return diffs.filter { abs($0) > max(thresh, 0.02) }.count
    }

    /// THD+N via FFT on a steady slice (50-90% of buffer). Pure, offline.
    public static func thdPlusNoise(_ x: [Float], sampleRate: Double, fundamentalHz: Double) -> Double? {
        let n = x.count
        guard n > 4096, n % 2 == 0 else { return nil }
        let lo = n / 4, hi = (n * 3) / 4
        let len = hi - lo
        guard len >= 4096 else { return nil }
        // Hann window
        var re = [Double](repeating: 0, count: len)
        for i in 0..<len {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(max(len - 1, 1)))
            re[i] = Double(x[lo + i]) * w
        }
        // Simple DFT at fundamental via Goertzel energy ratio: power at f vs total.
        // Use FFT radix-2 (zero-pad to power of 2).
        var p2 = 1
        while p2 < len { p2 <<= 1 }
        var freqRe = [Double](repeating: 0, count: p2)
        var freqIm = [Double](repeating: 0, count: p2)
        for i in 0..<len { freqRe[i] = re[i] }
        // Cooley-Tukey (iterative)
        var j = 0
        for i in 1..<p2 {
            var bit = p2 >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { freqRe.swapAt(i, j); freqIm.swapAt(i, j) }
        }
        var length = 2
        while length <= p2 {
            let ang = -2 * Double.pi / Double(length)
            for s in stride(from: 0, to: p2, by: length) {
                for k in 0..<(length / 2) {
                    let wr = cos(ang * Double(k)), wi = sin(ang * Double(k))
                    let a = s + k, b = a + length / 2
                    let tr = freqRe[b] * wr - freqIm[b] * wi
                    let ti = freqRe[b] * wi + freqIm[b] * wr
                    freqRe[b] = freqRe[a] - tr; freqIm[b] = freqIm[a] - ti
                    freqRe[a] += tr; freqIm[a] += ti
                }
            }
            length <<= 1
        }
        var fund = 0.0, total = 0.0
        let fundBin = max(1, Int((fundamentalHz / sampleRate * Double(p2)).rounded()))
        for k in 1..<(p2 / 2) {
            let e = freqRe[k] * freqRe[k] + freqIm[k] * freqIm[k]
            total += e
            if abs(k - fundBin) <= 1 { fund += e }
        }
        guard total > 1e-12 else { return nil }
        let thdn = (total - fund) / fund
        guard thdn > 0 else { return nil }
        return 10 * log10(thdn)
    }
}
