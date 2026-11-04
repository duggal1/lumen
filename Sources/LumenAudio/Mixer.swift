import Foundation
import Accelerate
import AVFoundation
import os
import LumenCore
import LumenProject
import LumenDirector

public struct MixedAudio: Sendable {
    public var l: [Float], r: [Float]
    public var lufs: Double, truePeakDb: Double
    public init(l: [Float], r: [Float], lufs: Double, truePeakDb: Double) {
        self.l = l; self.r = r; self.lufs = lufs; self.truePeakDb = truePeakDb
    }
}

/// Offline mix of the whole timeline. Preview plays this buffer; export encodes it. One code path = they always match.
/// Voice chain (HP, denoise, EQ, compressor, -16 LUFS reference) is cached by `micClean`. Thread-safe.
public final class AudioMixer: @unchecked Sendable {
    private struct MusicCache { var path: String; var track: MusicTrack?; var lufs: Double }

    /// Voice sits at -16 LUFS before the master stage. Music reference is 6 dB hotter so the default
    /// `musicGainDb` (-18) lands the bed ~12 dB under the voice at rest (plan 10.3).
    static let voiceRefLUFS = -16.0, musicRefLUFS = -10.0

    private let mic: [Float]?, micOffset: Double, sys: [Float]?, sysOffset: Double
    private let bank = SFXBank()
    private let lock = NSLock()
    private var voice: (clean: Bool, x: [Float])?
    private var music: MusicCache?
    public var denoiser: any Denoiser = defaultDenoiser

    public init(mic: [Float]?, micOffset: Double, system: [Float]?, systemOffset: Double) {
        self.mic = mic; self.micOffset = micOffset; sys = system; sysOffset = systemOffset
    }

    // MARK: Cached stages

    private func voiceChain(_ clean: Bool) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if let v = voice, v.clean == clean { return v.x }
        guard let m = mic else { return nil }
        let fs = AudioIO.fs
        var hp = Biquad.highpass(80, fs: fs), eq = Biquad.peaking(3000, q: 1, db: 2, fs: fs)
        var x = m.map { Float(hp.run(Double($0))) }
        if clean { x = denoiser.process(x) }
        x = x.map { Float(eq.run(Double($0))) }
        x = Compressor().process(x, fs: fs)
        let lu = Loudness.integrated([x])
        if lu > -69 {
            let g = Float(pow(10, clamp(Self.voiceRefLUFS - lu, -24, 24) / 20))
            x = vDSP.multiply(g, x)
        }
        voice = (clean, x)
        return x
    }

    private func loadMusic(_ path: String?) -> MusicCache? {
        guard let path else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let m = music, m.path == path { return m }
        let t = AudioIO.loadMusic(URL(fileURLWithPath: path))
        let c = MusicCache(path: path, track: t, lufs: t.map { Loudness.integrated([$0.l, $0.r]) } ?? -70)
        music = c
        return c
    }

    // MARK: Building blocks

    /// Source-time audio -> output time through the time map (1 ms steps, linear interpolation).
    /// Fades to silence (10 ms) inside speed ramps when `muteRamps` is set.
    static func mapped(_ x: [Float], offset: Double, tm: TimeMap, n: Int, muteRamps: Bool) -> [Float] {
        let fs = AudioIO.fs, spms = Int(fs / 1000)
        var y = [Float](repeating: 0, count: n)
        var prevS = tm.source(atOutput: 0), prevG = 1.0
        for k in 1...(n / spms + 1) {
            let t = Double(k) / 1000, s = tm.source(atOutput: t)
            let target = muteRamps && tm.speed(atOutput: t) > 1.2 ? 0.0 : 1.0
            let g = prevG + clamp(target - prevG, -0.1, 0.1)
            for j in 0..<spms {
                let i = (k - 1) * spms + j
                if i >= n { break }
                let u = Double(j) / Double(spms)
                let ss = (prevS + (s - prevS) * u - offset) * fs
                let gg = prevG + (g - prevG) * u
                if gg > 0.001, ss >= 0, ss < Double(x.count - 1) {
                    let i0 = Int(ss), f = Float(ss - Double(i0))
                    y[i] = (x[i0] * (1 - f) + x[i0 + 1] * f) * Float(gg)
                }
            }
            prevS = s; prevG = g
        }
        return y
    }

    /// Loop with 0.5 s crossfade to length n, 0.3 s fade-in, 1.5 s fade-out.
    static func fit(_ m: MusicTrack, n: Int) -> ([Float], [Float]) {
        let fs = AudioIO.fs, xf = Int(0.5 * fs), len = m.l.count
        var L = [Float](repeating: 0, count: n), R = L
        var i = 0
        while i < n {
            let c = min(len, n - i)
            for k in 0..<c {
                var a: Float = 1
                if i > 0 && k < xf { a = Float(k) / Float(xf) }                                   // crossfade in
                if c == len && k >= len - xf && i + len < n { a = Float(len - k) / Float(xf) }    // overlapped tail fades out
                L[i + k] += m.l[k] * a
                R[i + k] += m.r[k] * a
            }
            i += max(len - xf, 1)
        }
        for k in 0..<n {
            let fin = min(1, Float(k) / Float(0.3 * fs)), fout = min(1, Float(n - k) / Float(1.5 * fs))
            let g = fin * fout
            L[k] *= g; R[k] *= g
        }
        return (L, R)
    }

    // MARK: Mix

    public func mix(_ tl: Timeline) -> MixedAudio? {
        guard let d = tl.derived else { return nil }
        let fs = AudioIO.fs, n = Int(d.outputDuration * fs) + 1, a = tl.audio, tm = tl.timeMap
        var L = [Float](repeating: 0, count: n), R = L
        var hasProgram = false                                   // voice / system / music (not just SFX)

        if let v = voiceChain(a.micClean) {
            let y = Self.mapped(v, offset: micOffset, tm: tm, n: n, muteRamps: a.muteMicInRamps)
            for i in 0..<n { L[i] += y[i]; R[i] += y[i] }
            hasProgram = true
        }
        if let s = sys {
            let y = Self.mapped(s, offset: sysOffset, tm: tm, n: n, muteRamps: true)
            let g: Float = 0.7
            for i in 0..<n { L[i] += y[i] * g; R[i] += y[i] * g }
            hasProgram = true
        }
        if let mc = loadMusic(a.musicPath), let mt = mc.track {
            let (ml, mr) = Self.fit(mt, n: n)
            let norm = mc.lufs > -60 ? clamp(Self.musicRefLUFS - mc.lufs, -24, 24) : 0
            let g = Float(pow(10, (norm + a.musicGainDb) / 20))
            for i in 0..<n {
                var dk: Float = 1
                if !d.duck.isEmpty {
                    let p = Double(i) / fs * 100
                    let i0 = min(Int(p), d.duck.count - 1), i1 = min(i0 + 1, d.duck.count - 1)
                    dk = d.duck[i0] + (d.duck[i1] - d.duck[i0]) * Float(p - Double(i0))
                }
                L[i] += ml[i] * g * dk; R[i] += mr[i] * g * dk
            }
            hasProgram = true
        }

        var rng = SplitMix64(seed: 7), last: [Int: Int] = [:]
        for cue in d.cues {
            let (buf, jit) = bank.render(cue.kind, rng: &rng, last: &last)
            let amp = Float(pow(10, (a.sfxGainDb + cue.gainDb + jit) / 20)), s0 = Int(cue.t * fs)
            for (k, v) in buf.enumerated() where s0 + k >= 0 && s0 + k < n {
                L[s0 + k] += v * amp; R[s0 + k] += v * amp
            }
        }

        var ch = [L, R]
        var lufs = Loudness.integrated(ch)
        // Only normalize when there is real program material; sparse clicks alone must not be pumped to -14 LUFS.
        if hasProgram, lufs > -69 {
            let g = Float(pow(10, clamp(a.targetLUFS - lufs, -30, 30) / 20))
            ch = ch.map { vDSP.multiply(g, $0) }
        }
        let outputGain = Float(pow(10, clamp(a.outputGainDb, -60, 12) / 20))
        ch = ch.map { vDSP.multiply(outputGain, $0) }
        Limiter.apply(&ch, ceiling: Float(pow(10, -1.5 / 20)))
        var tp = Loudness.truePeakDb(ch)
        if tp > -1.0 {
            let g = Float(pow(10, (-1.05 - tp) / 20))
            ch = ch.map { vDSP.multiply(g, $0) }
            tp = Loudness.truePeakDb(ch)
        }
        lufs = Loudness.integrated(ch)
        return MixedAudio(l: ch[0], r: ch[1], lufs: lufs, truePeakDb: tp)
    }
}

/// Preview playback of a pre-mixed buffer, started in lock-step with the host clock. `load` is safe from any thread.
public final class PreviewAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine(), node = AVAudioPlayerNode()
    private struct Buffer: @unchecked Sendable { let value: AVAudioPCMBuffer }
    private let mixed = OSAllocatedUnfairLock<(audio: MixedAudio?, buffer: Buffer?)>(initialState: (nil, nil))
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!

    public init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
    }

    public func load(_ m: MixedAudio?) {
        var prepared: Buffer?
        if let m, !m.l.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(m.l.count)) {
            b.frameLength = AVAudioFrameCount(m.l.count)
            m.l.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: m.l.count) }
            m.r.withUnsafeBufferPointer { b.floatChannelData![1].update(from: $0.baseAddress!, count: m.r.count) }
            prepared = Buffer(value: b)
        }
        let ready = prepared
        mixed.withLock { $0 = (m, ready) }
    }

    /// Starts playback of output-time `t` at `atHostSeconds` (HostClock seconds).
    @discardableResult public func play(from t: Double, atHostSeconds h: Double) -> Double {
        node.stop()
        let snapshot = mixed.withLock { $0 }
        guard let m = snapshot.audio else { return max(h, HostClock.now() + 0.03) }
        let s = min(max(Int(t * 48000), 0), m.l.count), cnt = m.l.count - s
        guard cnt > 0 else { return max(h, HostClock.now() + 0.03) }
        let b: AVAudioPCMBuffer
        if s == 0, let prepared = snapshot.buffer {
            b = prepared.value
        } else {
            guard let tail = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(cnt)) else { return max(h, HostClock.now() + 0.03) }
            tail.frameLength = AVAudioFrameCount(cnt)
            m.l.withUnsafeBufferPointer { tail.floatChannelData![0].update(from: $0.baseAddress! + s, count: cnt) }
            m.r.withUnsafeBufferPointer { tail.floatChannelData![1].update(from: $0.baseAddress! + s, count: cnt) }
            b = tail
        }
        if !engine.isRunning { do { try engine.start() } catch { return max(h, HostClock.now() + 0.03) } }
        node.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
        let start = max(h, HostClock.now() + 0.03)
        node.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start)))
        return start
    }

    public func stop() { node.stop() }
}
