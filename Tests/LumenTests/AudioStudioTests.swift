import Foundation
import Testing
@testable import LumenAudio
import LumenCore
import LumenProject
import LumenDirector

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

private func nextPow2(_ n: Int) -> Int {
    var p = 1
    while p < n { p <<= 1 }
    return p
}

private func fftConvolve(_ a: [Float], _ b: [Float]) -> [Float] {
    let n = a.count + b.count - 1
    let N = nextPow2(n)
    var ar = a + [Float](repeating: 0, count: N - a.count)
    var ai = [Float](repeating: 0, count: N)
    var br = b + [Float](repeating: 0, count: N - b.count)
    var bi = [Float](repeating: 0, count: N)
    let fft = Radix2FFT(n: N)
    fft.transform(&ar, &ai); fft.transform(&br, &bi)
    for i in 0..<N { let re = ar[i] * br[i] - ai[i] * bi[i]; let im = ar[i] * bi[i] + ai[i] * br[i]; ar[i] = re; ai[i] = im }
    fft.transform(&ai, &ar)
    return (0..<n).map { ar[$0] / Float(N) }
}

private func harmonicWords(fs: Double, seconds: Double) -> (x: [Float], onsets: [Double], offsets: [Double]) {
    let n = Int(fs * seconds)
    var x = [Float](repeating: 0, count: n)
    var onsets: [Double] = [], offsets: [Double] = []
    var t = 0.15
    let f0s = [120.0, 150.0, 180.0]
    var k = 0
    while t + 0.3 < seconds - 0.2 {
        let f0 = f0s[k % f0s.count]
        let start = Int(t * fs), len = Int(0.3 * fs)
        for i in 0..<len {
            let u = Double(i) / Double(len)
            let env = 0.5 - 0.5 * cos(2 * Double.pi * u)
            let time = Double(i) / fs
            var s = 0.0
            for h in 1...40 {
                let f = f0 * Double(h)
                if f > 8000 { break }
                let a = exp(-pow((f - 700) / 180, 2)) + 0.7 * exp(-pow((f - 1200) / 220, 2))
                      + 0.35 * exp(-pow((f - 2600) / 300, 2)) + 0.05
                s += a * sin(2 * Double.pi * f * time)
            }
            x[start + i] += Float(0.05 * env * s)
        }
        onsets.append(t); offsets.append(t + 0.3)
        t += 0.7
        k += 1
    }
    let peak = x.map { abs($0) }.max() ?? 1
    let g = Float(0.5 / max(peak, 1e-6))
    for i in 0..<n { x[i] *= g }
    return (x, onsets, offsets)
}

private func rir(fs: Double, rt60: Double) -> [Float] {
    let len = Int(rt60 * fs * 1.2)
    var r = [Float](repeating: 0, count: len)
    var nz = Noise(seed: 99)
    r[0] = 1
    for i in 1..<len {
        let t = Double(i) / fs
        r[i] = Float(0.6 * nz.next() * exp(-6.9078 * t / rt60))
    }
    return r
}

private func pinkNoise(fs: Double, n: Int, levelDb: Double) -> [Float] {
    var nz = Noise(seed: 123)
    var b0 = 0.0, b1 = 0.0, b2 = 0.0
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let w = nz.next()
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        out[i] = Float(b0 + b1 + b2 + w * 0.1848)
    }
    var s = 0.0
    for v in out { s += Double(v) * Double(v) }
    let rms = sqrt(s / Double(n))
    let g = pow(10, levelDb / 20) / max(rms, 1e-12)
    for i in 0..<n { out[i] *= Float(g) }
    return out
}

@Test func autoLoudnessOffLeavesOutputGainAsTheOnlyMaster() throws {
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 1, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 1)
    tl.audio.micClean = false
    tl.audio.normalize = false
    tl.audio.speedRampsAuto = false
    tl.audio.clickSounds = false
    tl.audio.whooshes = false
    tl.audio.studio = 0
    tl.audio.dereverb = 0
    tl = Director.derive(tl, input: DirectorInput(events: [], source: src), revision: 1)
    let voice = (0..<48_000).map { Float(0.05 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
    let mixer = AudioMixer(mic: voice, micOffset: 0, system: nil, systemOffset: 0)
    let reference = try #require(mixer.mix(tl))
    tl.audio.outputGainDb = -12
    let quieter = try #require(mixer.mix(tl))
    #expect(abs((quieter.lufs - reference.lufs) + 12) < 0.3)
    #expect(quieter.truePeakDb <= -1)
}

@Test func micGainIsPureGainWhenNormalizeIsOff() throws {
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 1, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 1)
    tl.audio.micClean = false
    tl.audio.normalize = false
    tl.audio.speedRampsAuto = false
    tl.audio.clickSounds = false
    tl.audio.whooshes = false
    tl.audio.studio = 0
    tl.audio.dereverb = 0
    tl = Director.derive(tl, input: DirectorInput(events: [], source: src), revision: 1)
    let voice = (0..<48_000).map { Float(0.02 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
    let mixer = AudioMixer(mic: voice, micOffset: 0, system: nil, systemOffset: 0)
    let base = try #require(mixer.mix(tl))
    tl.audio.micGainDb = 6
    let louder = try #require(mixer.mix(tl))
    #expect(abs((louder.lufs - base.lufs) - 6) < 0.3)
}

@Test func stageACacheIsWrittenAndReused() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-wpe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 2, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 2)
    tl.audio.micClean = false
    tl.audio.dereverb = 0.85
    tl.audio.normalize = false
    tl.audio.speedRampsAuto = false
    tl.audio.clickSounds = false
    tl.audio.whooshes = false
    tl.audio.studio = 0
    tl = Director.derive(tl, input: DirectorInput(events: [], source: src), revision: 1)
    let fs = AudioIO.fs
    let samples = (0..<Int(fs * 2)).map { Float(0.1 * sin(2 * Double.pi * 180 * Double($0) / fs)) }
    let a = AudioMixer(mic: samples, micOffset: 0, system: nil, systemOffset: 0, cacheDir: dir)
    _ = try #require(a.mix(tl))
    let url = dir.appendingPathComponent("voice-wpe-v1.f32")
    #expect(FileManager.default.fileExists(atPath: url.path))
    let data = try Data(contentsOf: url)
    #expect(data.count == 8 + samples.count * 4)
    let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    let b = AudioMixer(mic: samples, micOffset: 0, system: nil, systemOffset: 0, cacheDir: dir)
    _ = try #require(b.mix(tl))
    let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
    #expect(before == after, "stage A cache was rewritten instead of reused")
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
    tl.camera.maxScale = 1.9
    let warm = Director.derive(tl, input: input, revision: 2, cache: &cache)
    let cold = Director.derive(tl, input: input, revision: 2)
    #expect(warm.zoom.map { [$0.start, $0.end, $0.scale] } == cold.zoom.map { [$0.start, $0.end, $0.scale] })
    let a = try #require(warm.derived), b = try #require(cold.derived)
    #expect(a.cursor == b.cursor)
    #expect(a.camera == b.camera)
    #expect(a.clicks == b.clicks)
    #expect(a.cues == b.cues)
}