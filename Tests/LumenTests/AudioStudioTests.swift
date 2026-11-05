import Foundation
import Testing
import LumenCore
import LumenProject
import LumenDirector
import LumenAudio

private struct Noise {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
    mutating func next() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(UInt64(1) << 53) * 2 - 1
    }
}

private func rmsDb(_ x: ArraySlice<Float>) -> Double {
    guard !x.isEmpty else { return -120 }
    var sum = 0.0
    for v in x { sum += Double(v) * Double(v) }
    return 10 * log10(sum / Double(x.count) + 1e-12)
}

/// A dry burst followed by an exponential room tail (RT60 0.6 s).
private func reverberantBurst(fs: Double) -> [Float] {
    let n = Int(fs * 2)
    var out = [Float](repeating: 0, count: n)
    var noise = Noise(seed: 7)
    let start = Int(0.30 * fs), end = Int(0.42 * fs)
    for i in start..<end { out[i] = Float(noise.next() * 0.3) }
    for i in end..<n {
        let t = Double(i - end) / fs
        out[i] = Float(noise.next() * 0.3 * pow(10, -3 * t / 0.6))
    }
    return out
}

@Test func lateReverbSuppressorRemovesTailButKeepsDirectSound() {
    let fs = 48_000.0
    let dry = reverberantBurst(fs: fs)
    let wet = LateReverbSuppressor(amount: 0.9, rt60: 0.6, vad: [0.30...0.42]).process(dry)
    #expect(wet.count == dry.count)
    #expect(wet.allSatisfy { $0.isFinite })

    let direct = Int(0.32 * fs)..<Int(0.42 * fs)
    let tail = Int(0.80 * fs)..<Int(1.20 * fs)
    let directChange = rmsDb(wet[direct]) - rmsDb(dry[direct])
    let tailChange = rmsDb(wet[tail]) - rmsDb(dry[tail])
    #expect(abs(directChange) < 1.5, "direct speech changed by \(directChange) dB")
    #expect(tailChange < -7, "room tail only fell by \(tailChange) dB")
}

@Test func expanderLowersRoomNoiseBetweenWordsWithoutTouchingSpeech() {
    let fs = 48_000.0
    let n = Int(fs * 2)
    var x = [Float](repeating: 0, count: n)
    var noise = Noise(seed: 11)
    for i in 0..<n { x[i] = Float(noise.next() * 0.002) }
    for w in [0.20..<0.50, 0.90..<1.20] {
        for i in Int(w.lowerBound * fs)..<Int(w.upperBound * fs) {
            let t = Double(i) / fs
            x[i] += Float(0.2 * sin(2 * .pi * 220 * t))
        }
    }
    let y = Expander().process(x, fs: fs)
    #expect(y.count == x.count)

    let speech = Int(0.30 * fs)..<Int(0.45 * fs)
    let quiet = Int(0.60 * fs)..<Int(0.85 * fs)
    let speechChange = rmsDb(y[speech]) - rmsDb(x[speech])
    let quietChange = rmsDb(y[quiet]) - rmsDb(x[quiet])
    #expect(abs(speechChange) < 1.0, "speech moved by \(speechChange) dB")
    #expect(quietChange < -6, "room noise only fell by \(quietChange) dB")
}

@Test func autoLoudnessOffLeavesOutputGainAsTheOnlyMaster() throws {
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 1, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 1)
    tl.audio.micClean = false
    tl.audio.normalize = false
    tl.audio.speedRampsAuto = false
    tl.audio.clickSounds = false
    tl.audio.whooshes = false
    tl = Director.derive(tl, input: DirectorInput(events: [], source: src), revision: 1)
    let voice = (0..<48_000).map { Float(0.05 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
    let mixer = AudioMixer(mic: voice, micOffset: 0, system: nil, systemOffset: 0)

    let reference = try #require(mixer.mix(tl))
    tl.audio.outputGainDb = -12
    let quieter = try #require(mixer.mix(tl))
    #expect(abs((quieter.lufs - reference.lufs) + 12) < 0.3)
    #expect(quieter.truePeakDb <= -1)
}

@Test func deriveCacheMatchesColdDerive() throws {
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 6, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 6)
    tl.audio.speedRampsAuto = false
    let events = [
        InputEvent(t: 0.5, kind: .move, x: 60, y: 60), InputEvent(t: 0.9, kind: .move, x: 300, y: 200),
        InputEvent(t: 1.4, kind: .down, x: 300, y: 200), InputEvent(t: 1.6, kind: .up, x: 300, y: 200),
        InputEvent(t: 3.0, kind: .move, x: 520, y: 120), InputEvent(t: 3.6, kind: .down, x: 520, y: 120),
        InputEvent(t: 3.8, kind: .up, x: 520, y: 120),
    ]
    let input = DirectorInput(events: events, source: src)

    var cache = DeriveCache()
    _ = Director.derive(tl, input: input, revision: 1, cache: &cache)
    tl.camera.maxScale = 1.9                       // second edit: cursor stage stays warm
    let warm = Director.derive(tl, input: input, revision: 2, cache: &cache)
    let cold = Director.derive(tl, input: input, revision: 2)

    #expect(warm.zoom.map { [$0.start, $0.end, $0.scale] } == cold.zoom.map { [$0.start, $0.end, $0.scale] })
    let a = try #require(warm.derived), b = try #require(cold.derived)
    #expect(a.cursor == b.cursor)
    #expect(a.camera == b.camera)
    #expect(a.clicks == b.clicks)
    #expect(a.cues == b.cues)
}
