import Foundation
import Accelerate
import AVFoundation
import Synchronization

/// Single-producer / single-consumer float ring. Producer = the capture audio queue (never blocks, never allocates).
final class FloatRing: @unchecked Sendable {
    private let buf: UnsafeMutablePointer<Float>
    private let cap: Int
    private let head = Atomic<Int>(0), tail = Atomic<Int>(0), lost = Atomic<Int>(0)
    init(capacity: Int) { cap = capacity; buf = .allocate(capacity: capacity); buf.initialize(repeating: 0, count: capacity) }
    deinit { buf.deallocate() }
    var droppedSamples: Int { lost.load(ordering: .relaxed) }
    func noteLoss(_ n: Int) { _ = lost.wrappingAdd(n, ordering: .relaxed) }
    /// All-or-nothing, so a gap never splices half a buffer.
    @discardableResult func push(_ p: UnsafePointer<Float>, _ n: Int) -> Bool {
        let h = head.load(ordering: .relaxed), t = tail.load(ordering: .acquiring)
        guard n <= cap - (h - t) else { noteLoss(n); return false }
        let i = h % cap, first = min(n, cap - i)
        buf.advanced(by: i).update(from: p, count: first)
        if n > first { buf.update(from: p.advanced(by: first), count: n - first) }
        head.store(h + n, ordering: .releasing)
        return true
    }
    func read(into dst: UnsafeMutablePointer<Float>, max: Int) -> Int {
        let t = tail.load(ordering: .relaxed), h = head.load(ordering: .acquiring)
        let n = min(h - t, max)
        guard n > 0 else { return 0 }
        let i = t % cap, first = min(n, cap - i)
        dst.update(from: buf.advanced(by: i), count: first)
        if n > first { dst.advanced(by: first).update(from: buf, count: n - first) }
        tail.store(t + n, ordering: .releasing)
        return n
    }
}

/// Streaming windowed-sinc resampler (Blackman, 12 zero crossings per side, 128 sub-phases). Linear phase: output sample 0 is input sample 0.
struct StreamResampler {
    static let phases = 128
    private let step: Double, half: Int, taps: Int
    private let table: [Float]
    private var buf: [Float]
    private var pos: Double

    init(from inRate: Double, to outRate: Double) {
        let fc = min(1.0, outRate / inRate) * 0.94
        let h = Int((12 / fc).rounded(.up)), t = 2 * h, ph = Self.phases
        var tb = [Float](repeating: 0, count: ph * t)
        for p in 0..<ph {
            let frac = Double(p) / Double(ph)
            var row = [Double](repeating: 0, count: t), sum = 0.0
            for k in 0..<t {
                let x = Double(k - h + 1) - frac, u = x / Double(h)
                let win = abs(u) < 1 ? 0.42 + 0.5 * cos(Double.pi * u) + 0.08 * cos(2 * Double.pi * u) : 0
                let z = fc * x
                let sinc = abs(z) < 1e-9 ? 1.0 : sin(Double.pi * z) / (Double.pi * z)
                row[k] = fc * sinc * win; sum += row[k]
            }
            for k in 0..<t { tb[p * t + k] = Float(row[k] / sum) }
        }
        step = inRate / outRate; half = h; taps = t; table = tb
        buf = [Float](repeating: 0, count: h); pos = Double(h)
    }

    mutating func process(_ x: UnsafeBufferPointer<Float>, into out: inout [Float]) {
        buf.append(contentsOf: x)
        let n = buf.count, half = half, taps = taps, step = step
        var p = pos
        buf.withUnsafeBufferPointer { b in
            table.withUnsafeBufferPointer { tb in
                while true {
                    let i0 = Int(p)
                    if i0 + half >= n { break }
                    let ph = Int((p - Double(i0)) * Double(Self.phases))
                    var acc: Float = 0
                    vDSP_dotpr(b.baseAddress! + (i0 - half + 1), 1, tb.baseAddress! + ph * taps, 1, &acc, vDSP_Length(taps))
                    out.append(acc)
                    p += step
                }
            }
        }
        let drop = max(Int(p) - half, 0)
        if drop > 0 { buf.removeFirst(drop); p -= Double(drop) }
        pos = p
    }
}

/// Reads an audio file in fixed chunks as mono Float32. Memory stays flat for any length.
final class AudioChunkReader {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    let sampleRate: Double
    let totalFrames: Int64
    var position: Int64 { file.framePosition }
    init(url: URL, chunkFrames: Int = 96_000) throws {
        file = try AVAudioFile(forReading: url)
        sampleRate = file.processingFormat.sampleRate
        totalFrames = file.length
        guard let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
            throw SpeechError.audio("Could not allocate the audio buffer.")
        }
        buffer = b
    }
    func next(into out: inout [Float]) throws -> Bool {
        guard file.framePosition < file.length else { return false }
        buffer.frameLength = 0
        try file.read(into: buffer, frameCount: buffer.frameCapacity)
        let n = Int(buffer.frameLength)
        guard n > 0, let ch = buffer.floatChannelData else { return false }
        let c = Int(buffer.format.channelCount)
        out = Array(UnsafeBufferPointer(start: ch[0], count: n))
        if c > 1 {
            for k in 1..<c { let src = ch[k]; for i in 0..<n { out[i] += src[i] } }
            var g = 1 / Float(c)
            vDSP_vsmul(out, 1, &g, &out, 1, vDSP_Length(n))
        }
        return true
    }
}

/// 100 Hz loudness track of the 16 kHz stream (dB), plus a slowly adapting noise floor. Used for word-boundary snapping and activity gating.
struct EnergyTrack {
    private(set) var db: [Float] = []
    private(set) var floorDb: Float = -60
    private var acc: Float = 0, cnt = 0
    mutating func add(_ x: UnsafeBufferPointer<Float>) {
        for v in x {
            acc += v * v; cnt += 1
            if cnt == 160 {
                let d = 10 * log10f(acc / 160 + 1e-10)
                if db.isEmpty || d < floorDb { floorDb = d } else { floorDb += (d - floorDb) * 0.002 }
                db.append(d); acc = 0; cnt = 0
            }
        }
    }
    func slice(_ a: Double, _ b: Double) -> ArraySlice<Float> {
        let i0 = max(Int(a * 100), 0), i1 = min(Int((b * 100).rounded(.up)), db.count)
        return i0 < i1 ? db[i0..<i1] : []
    }
    /// Any of the last `sec` seconds clearly above the noise floor.
    func activeNow(_ sec: Double = 0.3, margin: Float = 9) -> Bool {
        let n = min(Int(sec * 100), db.count)
        guard n > 0 else { return false }
        return db[(db.count - n)...].contains { $0 > floorDb + margin }
    }
    func quietSeconds(margin: Float = 7, cap: Int = 300) -> Double {
        var n = 0, i = db.count - 1
        while i >= 0, n < cap, db[i] < floorDb + margin { n += 1; i -= 1 }
        return Double(n) / 100
    }
}
