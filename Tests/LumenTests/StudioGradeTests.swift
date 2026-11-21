import Foundation
import Testing
@testable import LumenAudio
import LumenProject

/// Oracle for Plans/studio-audio.md (frozen). RED before the Optimized chain exists.
private func loudFloorGap(_ x: [Float], fs: Double = 48_000) -> Double {
    let hop = Int(0.1 * fs)
    var frames: [Double] = []
    if x.count <= hop { return -120 }
    for s in stride(from: 0, to: x.count - hop, by: hop) {
        var e = 0.0
        for i in s..<(s + hop) { e += Double(x[i]) * Double(x[i]) }
        frames.append(10 * log10(e / Double(hop) + 1e-12))
    }
    guard frames.count >= 2 else { return -120 }
    let sorted = frames.sorted()
    let quiet = sorted[max(0, sorted.count / 10 - 1)]
    let loud = sorted[min(sorted.count - 1, sorted.count - sorted.count / 10)]
    return loud - quiet
}

private func echoFan() -> (x: [Float], vad: [ClosedRange<Double>]) {
    let fs = 48_000.0
    let n = Int(fs * 2)
    var x = [Float](repeating: 0, count: n)
    let vad: [ClosedRange<Double>] = [0.2...0.6, 1.2...1.6]
    for i in 0..<n {
        let t = Double(i) / fs
        var v: Float = 0.03 * Float(sin(2 * .pi * 60 * t)) + 0.02 * Float(sin(2 * .pi * 120 * t)) // fan+hum continuous
        for r in vad where t >= r.lowerBound && t <= r.upperBound {
            v += 0.25 * Float(sin(2 * .pi * 200 * t)) + 0.12 * Float(sin(2 * .pi * 600 * t)) // speech
            let tail = t - r.upperBound
            if tail > 0 && tail < 0.4 { v += 0.18 * Float(exp(-tail * 8) * sin(2 * .pi * 200 * t)) } // room tail
        }
        x[i] = v
    }
    return (x, vad)
}

@MainActor
@Test func studioChainReachesPodcastNoiseFloorTarget() {
    let (raw, vad) = echoFan()
    let plan = AudioPlan()
    let out = VoiceStudio.finish(raw, vad: vad, plan: plan, denoiser: nil)
    let gap = loudFloorGap(out)
    let rep = AudioCheck.analyze(channels: [out], sampleRate: 48_000)
    #expect(gap >= 50, "single Studio chain gap \(gap)dB < 50")
    #expect(rep.truePeakDb <= -1 + 0.01)
    #expect(out.count == raw.count && out.allSatisfy { $0.isFinite })
    #expect(AudioCheck.clickCount(out) <= 2, "Soft expander must not add clicks")
}

@MainActor
@Test func cleanClipDoesNotGetWorse() {
    let fs = 48_000.0
    let tone = (0..<Int(fs * 1)).map { Float(0.251 * sin(2 * .pi * 1000 * Double($0) / fs)) } // -12dBFS
    var plan = AudioPlan()
    plan.micClean = false
    plan.micMode = .standard
    plan.studio = 0.5
    plan.studioMode = .optimized
    let out = VoiceStudio.finish(tone, vad: [0.0...1.0], plan: plan, denoiser: nil)
    let thdnIn = AudioCheck.thdPlusNoise(tone, sampleRate: fs, fundamentalHz: 1000) ?? 0
    let thdnOut = AudioCheck.thdPlusNoise(out, sampleRate: fs, fundamentalHz: 1000) ?? -120
    let rep = AudioCheck.analyze(channels: [out], sampleRate: fs)
    #expect(rep.truePeakDb <= -1 + 0.01)
    #expect(rep.clippedSamples == 0)
    // Clean tone THD+N may shift a few dB from gentle EQ/comp; allow 6dB slack, fail only if clearly worse.
    #expect(thdnOut <= thdnIn + 6, "THD+N worsened \(thdnIn) -> \(thdnOut)")
}
