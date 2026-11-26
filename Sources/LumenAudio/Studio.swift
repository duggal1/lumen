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

/// Frame-level RMS analysis shared by the expander and the de-esser.
enum VoiceLevels {
    static func frames(_ x: [Float], hop: Int) -> [Double] {
        guard hop > 0, !x.isEmpty else { return [] }
        var out: [Double] = []
        out.reserveCapacity(x.count / hop + 1)
        var i = 0
        while i < x.count {
            let end = min(i + hop, x.count)
            var s = 0.0
            for k in i..<end { let v = Double(x[k]); s += v * v }
            out.append(10 * log10(s / Double(end - i) + 1e-12))
            i = end
        }
        return out
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[Int(clamp(p, 0, 1) * Double(sorted.count - 1))]
    }

    static func noiseFloor(_ x: [Float], vad: [ClosedRange<Double>], fs: Double) -> Double {
        let levels = frames(x, hop: max(Int(0.01 * fs), 1))
        guard !levels.isEmpty else { return -70 }
        var outside: [Double] = []
        for (f, db) in levels.enumerated() {
            let t = (Double(f) + 0.5) * 0.01
            guard db > -85 else { continue }
            if vad.contains(where: { $0.lowerBound <= t && t <= $0.upperBound }) { continue }
            outside.append(db)
        }
        let pool = outside.count >= 8 ? outside : levels.filter { $0 > -85 }
        return percentile(pool, 0.1) ?? -70
    }
}

/// Soft-knee downward expander driven by the voice activity timeline.
struct VoiceExpander {
    var floorDb: Double
    var depthDb: Double
    var kneeDb: Double = 20
    var hold: Double = 0.28
    var preOpen: Double = 0.02
    var open: Double = 0.020
    var close: Double = 0.150
    var speechRefDb: Double = -24

    func process(_ x: [Float], vad: [ClosedRange<Double>], fs: Double) -> [Float] {
        // No detected speech means we cannot tell noise from voice; leave the
        // signal untouched instead of gating the whole clip into silence.
        guard !vad.isEmpty, depthDb > 0.5, !x.isEmpty else { return x }
        let hop = max(Int(0.01 * fs), 1)
        let levels = VoiceLevels.frames(x, hop: hop)
        guard levels.count > 2 else { return x }
        var target = [Double](repeating: 1, count: levels.count)
        for (f, db) in levels.enumerated() {
            let t = (Double(f) + 0.5) * 0.01
            let voiced = vad.contains { $0.lowerBound - preOpen <= t && t <= $0.upperBound + hold }
            guard !voiced, db < speechRefDb + 14 else { continue }
            let above = max(0, db - floorDb)
            guard above < kneeDb else { continue }
            target[f] = pow(10, -depthDb * (1 - above / kneeDb) / 20)
        }
        var gain = target[0]
        let cOpen = exp(-1 / (open * fs)), cClose = exp(-1 / (close * fs))
        var out = x
        for i in 0..<x.count {
            let t = target[min(i / hop, target.count - 1)]
            gain = t + (t < gain ? cClose : cOpen) * (gain - t)
            out[i] = Float(Double(x[i]) * gain)
        }
        return out
    }
}

/// Split-band de-esser.
struct VoiceDeEsser {
    var thresholdDb: Double
    var ratio: Double = 3.5
    var maxReductionDb: Double = 6

    static func band(_ x: [Float], fs: Double) -> [Float] {
        var hp = Biquad.highpass(4_800, fs: fs)
        var lp = Biquad.lowpass(9_500, fs: fs)
        var out = [Float](repeating: 0, count: x.count)
        for i in x.indices {
            let v = lp.run(hp.run(Double(x[i])))
            out[i] = abs(v) < 1e-30 ? 0 : Float(v)
        }
        return out
    }

    static func threshold(band: [Float], vad: [ClosedRange<Double>], fs: Double) -> Double? {
        let hop = max(Int(0.02 * fs), 1)
        let levels = VoiceLevels.frames(band, hop: hop)
        guard levels.count > 3 else { return nil }
        var voiced: [Double] = []
        for (f, db) in levels.enumerated() {
            let t = (Double(f) + 0.5) * 0.02
            guard vad.contains(where: { $0.lowerBound <= t && t <= $0.upperBound }) else { continue }
            voiced.append(db)
        }
        guard voiced.count >= 3, let peak = VoiceLevels.percentile(voiced, 0.95), peak > -50 else { return nil }
        return peak - 4
    }

    func process(_ x: [Float], band: [Float], fs: Double) -> [Float] {
        guard x.count == band.count, !x.isEmpty else { return x }
        let attack = exp(-1 / (0.0008 * fs)), release = exp(-1 / (0.060 * fs))
        let slope = 1 - 1 / ratio
        var env = 0.0
        var out = x
        for i in x.indices {
            let v = abs(Double(band[i]))
            env = v > env ? v + attack * (env - v) : v + release * (env - v)
            let db = 20 * log10(env + 1e-9)
            guard db > thresholdDb else { continue }
            let reduction = max(-maxReductionDb, -slope * (db - thresholdDb))
            out[i] = Float(Double(x[i]) - Double(band[i]) * (1 - pow(10, reduction / 20)))
        }
        return out
    }
}

enum VoiceStudio {
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

    static func finish(_ x: [Float], vad: [ClosedRange<Double>], plan: AudioPlan,
                       denoiser: (any Denoiser)? = nil) -> [Float] {
        let fs = AudioIO.fs
        var voice = plan.micClean ? (denoiser?.process(x) ?? x) : x
        // ONE fixed Studio chain, always the same shape — no mode or amount
        // branches. Neural suppression (upstream) -> room/expand -> presence
        // EQ -> de-ess -> gentle compression -> voice lift -> shared master.
        // 1. Room tone, fan, hum.
        let floor = VoiceLevels.noiseFloor(voice, vad: vad, fs: fs)
        let speech = speechLevelDb(voice, vad: vad, fs: fs) ?? -24
        // Suppress measured stationary room tone during confirmed pauses;
        // retain pre-open and a continuous gain envelope around speech.
        voice = VoiceExpander(floorDb: floor, depthDb: 45,
                              hold: 0.10, close: 0.055, speechRefDb: speech)
            .process(voice, vad: vad, fs: fs)

        // 2. Tone: fuller chest, no boxiness, crisp presence and air.
        voice = tone(voice)

        // 3. Sibilance, only where there is any.
        let band = VoiceDeEsser.band(voice, fs: fs)
        if let threshold = VoiceDeEsser.threshold(band: band, vad: vad, fs: fs) {
            voice = VoiceDeEsser(thresholdDb: threshold, maxReductionDb: 7)
                .process(voice, band: band, fs: fs)
        }

        // 4. Density. makeup 0 so the compressor's gain reduction (not amplification)
        //    keeps the speech-boundary discontinuity below the click threshold.
        let level = speechLevelDb(voice, vad: vad, fs: fs) ?? speech
        let compressed = VoiceCompressor(thresholdDb: level - 4,
                                         ratio: 2.2, kneeDb: 8,
                                         attack: 0.012, release: 0.180,
                                         makeupDb: 0).process(voice, fs: fs)
        return boosted(compressed, plan: plan)
    }

    /// The user's own voice, lifted ~+2.5 dB (≈30%) before the shared master so
    /// it sits in front of system audio and music. The master limiter still owns
    /// the -1 dBTP ceiling, so raising this never clips the deliverable.
    private static func boosted(_ voice: [Float], plan: AudioPlan) -> [Float] {
        let db = plan.voiceBoostDb.isFinite ? clamp(plan.voiceBoostDb, 0, 6) : 0
        guard db > 0 else { return voice }
        let gain = Float(pow(10, db / 20))
        return voice.map { $0 * gain }
    }

    private static func tone(_ voice: [Float]) -> [Float] {
        let fs = AudioIO.fs
        // One close-mic curve: fuller chest, less boxiness, crisp presence, air.
        return Cascade.apply(voice, [
            .lowShelf(110, db: 0.9, fs: fs),
            .peaking(300, q: 1.05, db: -2.6, fs: fs),
            .peaking(3_000, q: 0.9, db: 2.0, fs: fs),
            .highShelf(9_500, db: 1.0, fs: fs)
        ])
    }
}
