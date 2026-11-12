import Foundation
import Testing
@testable import LumenAudio
import LumenProject

private struct HalfLevelDenoiser: Denoiser {
    func process(_ x: [Float]) -> [Float] { x.map { $0 * 0.5 } }
}

@Test func neuralCleanupDoesNotAlterDenoiserOutputWithoutExtraControls() {
    var plan = AudioPlan()
    plan.micClean = true
    plan.declick = false
    plan.dereverb = 0
    let samples: [Float] = (0..<4800).map { Float(sin(Double($0) * 0.13)) * 0.2 }
    let result = ProcessedVoiceCache.render(samples, plan: plan, keyTimes: [], denoiser: HalfLevelDenoiser())
    #expect(result == samples.map { $0 * 0.5 })
}

@Test func voiceCacheChangesWhenEchoReductionChanges() throws {
    var first = AudioPlan()
    first.dereverb = 0
    var second = first
    second.dereverb = 0.7
    let samples: [Float] = [0.1, 0.2, 0.3]
    #expect(try ProcessedVoiceCache.key(samples: samples, plan: first, keyTimes: []) != ProcessedVoiceCache.key(samples: samples, plan: second, keyTimes: []))
}

@Test func gentleEchoReductionImprovesSyntheticSpeechWithoutLargeChange() {
    let fs = 48_000, count = fs * 4, delay = 5_760
    let dry: [Float] = (0..<count).map { i in
        let t = Double(i) / Double(fs)
        let envelope = max(0, sin(2 * .pi * 2 * t))
        return Float(0.12 * envelope * (sin(2 * .pi * 170 * t) + 0.4 * sin(2 * .pi * 570 * t) + 0.2 * sin(2 * .pi * 1900 * t)))
    }
    var echoed = dry
    for i in delay..<count { echoed[i] += echoed[i - delay] * 0.5 }
    var plan = AudioPlan()
    plan.micClean = false
    plan.declick = false
    plan.dereverb = 0.5
    let result = ProcessedVoiceCache.render(echoed, plan: plan, keyTimes: [])
    func error(_ samples: [Float]) -> Double {
        zip(samples, dry).reduce(0) { $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1)) }
    }
    #expect(result.count == echoed.count)
    #expect(error(result) < error(echoed))
}
