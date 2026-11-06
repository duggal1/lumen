import Foundation
import Accelerate
import AVFoundation
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

/// An isolated, unmastered 32-bit float audio stem for professional editors.
/// Stems preserve the voice/system gain but do not duplicate effects or the
/// combined master limiter. Recombining stems needs mastering in the NLE.
public struct AudioStem: Sendable {
    public let name: String
    public let left: [Float]
    public let right: [Float]
    public init(name: String, left: [Float], right: [Float]) {
        self.name = name; self.left = left; self.right = right
    }
}

/// Extra recorded audio devices are separate immutable source files, on the
/// same host clock as the original screen and microphone.
public struct RecordedMicrophone: Sendable {
    public let deviceName: String, samples: [Float]
    public let offset: Double
    public init(deviceName: String, samples: [Float], offset: Double) {
        self.deviceName = deviceName; self.samples = samples; self.offset = offset
    }
}

/// Offline mix of the whole timeline. Preview plays this buffer; export encodes it. One code path = they always match.
/// Voice stage A (HP + WPE) is cached on disk for the primary mic; the residual
/// suppressor and studio chain are cached per setting in memory.
public final class AudioMixer: @unchecked Sendable {
    private struct MusicCache { var path: String; var track: MusicTrack?; var lufs: Double }
    private struct StageA { var hp: [Float]; var wpe: [Float]? }
    private struct VoiceKey: Hashable { var mic: Int; var clean: Bool; var room: Int; var studio: Int; var mode: MicMode }

    /// Voice sits at -16 LUFS before the master stage. Music reference is 6 dB hotter so the default
    /// `musicGainDb` (-18) lands the bed ~12 dB under the voice at rest (plan 10.3).
    static let voiceRefLUFS = -16.0, musicRefLUFS = -10.0

    private let mic: [Float]?, micOffset: Double, sys: [Float]?, sysRight: [Float]?, sysOffset: Double
    private let extraMicrophones: [RecordedMicrophone]
    private let cacheDir: URL?
    private let bank = SFXBank()
    private let lock = NSLock()
    private var stages: [Int: StageA] = [:]
    private var voice: [VoiceKey: [Float]] = [:]
    private var music: MusicCache?
    private var imported: [String: MusicTrack] = [:]
    public var denoiser: any Denoiser = defaultDenoiser

    public init(mic: [Float]?, micOffset: Double, system: [Float]?, systemOffset: Double,
                systemRight: [Float]? = nil,
                additionalMicrophones: [RecordedMicrophone] = [], cacheDir: URL? = nil) {
        self.mic = mic; self.micOffset = micOffset; sys = system
        sysRight = systemRight; sysOffset = systemOffset
        extraMicrophones = additionalMicrophones; self.cacheDir = cacheDir
        if let cacheDir { try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true) }
    }

    static func fingerprint(_ x: [Float]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325 ^ UInt64(x.count), i = 0
        while i < x.count { h = (h ^ UInt64(x[i].bitPattern)) &* 0x100000001b3; i += 997 }
        return h
    }

    /// WPE is the expensive stage, so it is written next to the project and reused on reopen.
    /// Only the primary mic is persisted on disk; extra mics run WPE in memory.
    // Called only by voiceChain while holding `lock`. Re-acquiring NSLock here
    // deadlocks every microphone mix, including the CI audio tests.
    private func stageA(_ m: [Float], index: Int, needWPE: Bool) -> StageA {
        if let s = stages[index], !needWPE || s.wpe != nil { return s }
        let hp = Cascade.apply(m, Cascade.hp4(80, fs: AudioIO.fs))
        guard needWPE else {
            let s = StageA(hp: hp, wpe: nil)
            stages[index] = s
            return s
        }
        let url = index == 0 ? cacheDir?.appendingPathComponent("voice-wpe-v1.f32") : nil
        let sig = Self.fingerprint(m)
        if let url, let d = try? Data(contentsOf: url), d.count == 8 + m.count * 4,
           d.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self) }) == sig {
            var out = [Float](repeating: 0, count: m.count)
            out.withUnsafeMutableBytes { dst in
                d.withUnsafeBytes { src in dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[8...])) }
            }
            let s = StageA(hp: hp, wpe: out)
            stages[index] = s
            return s
        }
        let w = WPE().process(hp)
        if let url {
            var data = Data()
            withUnsafeBytes(of: sig) { data.append(contentsOf: $0) }
            w.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
            try? data.write(to: url, options: .atomic)
        }
        let s = StageA(hp: hp, wpe: w)
        stages[index] = s
        return s
    }

    /// Every microphone is enhanced independently, never mixed before denoising/compression.
    /// The room tail is removed before EQ and compression, which would otherwise lift it after every phrase.
    private func voiceChain(_ plan: AudioPlan, micIndex: Int, samples: [Float]) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard plan.micMode != .off else { return nil }
        let key = VoiceKey(mic: micIndex, clean: plan.micClean,
                           room: Int(max(0, min(plan.dereverb, 1)) * 20),
                           studio: Int(max(0, min(plan.studio, 1)) * 20),
                           mode: plan.micMode)
        if let v = voice[key] { return v }
        let regions = VAD.regions(samples)
        // WPE models speech reverberation. On unvoiced material (e.g. loopback
        // tones), it can mistake the sustained signal for a room tail and erase it.
        let useWPE = plan.dereverb > 0.01 && !regions.isEmpty
        let st = stageA(samples, index: micIndex, needWPE: useWPE)
        // Keep the raw high-passed voice as the dry reference. Never cascade
        // residual suppression and neural denoising, which erases syllables.
        var x = st.hp
        if useWPE, let dereverbed = st.wpe, dereverbed.count == x.count {
            let wet = Float(min(max(plan.dereverb, 0), 1) * 0.30)
            for i in x.indices { x[i] = x[i] * (1 - wet) + dereverbed[i] * wet }
            // ResidualSuppressor was dead code (defined, never called).
            // `late` = what WPE removed is the best reverb-tail estimate;
            // suppressing against it is what makes the tail actually quieter
            // instead of just spectrally reshaped.
            let late = zip(st.hp, dereverbed).map { $0 - $1 }
            let suppressed = ResidualSuppressor(noise: 0.9,
                                                reverb: min(max(plan.dereverb, 0), 1),
                                                rt60: RoomEstimate.rt60(st.hp, vad: regions))
                .process(x: x, late: late)
            if suppressed.count == x.count {
                for i in x.indices { x[i] = x[i] * 0.5 + suppressed[i] * 0.5 }
            }
        }
        if plan.micClean {
            let cleaned = denoiser.process(x)
            if cleaned.count == x.count {
                let wet: Float = 0.35
                for i in x.indices { x[i] = x[i] * (1 - wet) + cleaned[i] * wet }
            }
        }
        x = VoiceStudio.finish(x, vad: regions, plan: plan, denoiser: nil)
        let lu = Loudness.integrated([x])
        if lu > -69 {
            let g = Float(pow(10, clamp(Self.voiceRefLUFS - lu, -24, 24) / 20))
            x = vDSP.multiply(g, x)
        }
        // Cap the cache: keep the most recent few settings, drop the rest.
        let cap = max(3, extraMicrophones.count + 1)
        if voice.count >= cap { voice.removeAll() }
        voice[key] = x
        return x
    }

    private func voiceChain(_ plan: AudioPlan) -> [Float]? {
        guard let mic else { return nil }
        return voiceChain(plan, micIndex: 0, samples: mic)
    }

    private func extraVoiceChain(_ index: Int, plan: AudioPlan) -> [Float]? {
        guard extraMicrophones.indices.contains(index) else { return nil }
        return voiceChain(plan, micIndex: index + 1, samples: extraMicrophones[index].samples)
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

    private func importTrack(_ path: String) -> MusicTrack? {
        lock.lock()
        let cached = imported[path]
        lock.unlock()
        if let cached { return cached }
        guard let (l, r) = try? AudioIO.readStereo(URL(fileURLWithPath: path)),
              !l.isEmpty, l.count == r.count else { return nil }
        let result = MusicTrack(l: l, r: r)
        lock.lock()
        imported[path] = result
        lock.unlock()
        return result
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
        var L = [Float](repeating: 0, count: n), R = L, i = 0
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

    /// Separate WAV stems in the same OUTPUT timeline as the encoded movie.
    /// This is intentionally opt-in, since it requires extra offline processing.
    public func stems(_ tl: Timeline) -> [AudioStem] {
        guard tl.derived != nil else { return [] }
        let fs = AudioIO.fs, n = Int(tl.compositionDuration * fs) + 1
        guard n > 0 else { return [] }
        let a = tl.audio, tm = tl.timeMap
        var result: [AudioStem] = []

        if a.micMode != .off, let voice = voiceChain(a) {
            let mapped = Self.mapped(voice, offset: micOffset, tm: tm,
                                     n: n, muteRamps: a.muteMicInRamps)
            let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
            let channel = mapped.map { $0 * gain }
            result.append(AudioStem(name: "microphone", left: channel, right: channel))
        }
        if a.micMode != .off {
            for index in extraMicrophones.indices {
                guard let processed = extraVoiceChain(index, plan: a) else { continue }
                let input = extraMicrophones[index]
                let mapped = Self.mapped(processed, offset: input.offset,
                                         tm: tm, n: n, muteRamps: a.muteMicInRamps)
                let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
                let channel = mapped.map { $0 * gain }
                result.append(AudioStem(name: "microphone-\(index + 2)", left: channel, right: channel))
            }
        }

        if let system = sys {
            let left = Self.mapped(system, offset: sysOffset, tm: tm, n: n, muteRamps: true)
            let right = sysRight.map { Self.mapped($0, offset: sysOffset, tm: tm, n: n, muteRamps: true) } ?? left
            let gain = Float(pow(10, clamp(a.systemGainDb, -60, 24) / 20))
            result.append(AudioStem(name: "system",
                                    left: left.map { $0 * gain }, right: right.map { $0 * gain }))
        }

        var voiceIndex = 0
        for lane in a.lanes where lane.role == .voiceover && !lane.mute {
            guard let path = lane.path, let track = importTrack(path) else { continue }
            voiceIndex += 1
            var left = [Float](repeating: 0, count: n), right = left
            let start = max(0, Int(lane.placement * fs))
            guard start < n else { continue }
            let count = min(track.l.count, n - start)
            let gain = Float(pow(10, clamp(lane.gainDb, -60, 24) / 20))
            let fade = min(Int(fs * 0.01), count / 2)
            for i in 0..<count {
                let edge = fade > 0 ? min(1, Float(min(i, count - i - 1)) / Float(fade)) : 1
                left[start + i] = track.l[i] * gain * edge
                right[start + i] = track.r[i] * gain * edge
            }
            result.append(AudioStem(name: "voiceover-\(voiceIndex)", left: left, right: right))
        }
        return result.map { stem in
            var left = stem.left, right = stem.right
            Self.silenceClips(tl, &left, &right, fs: fs)
            return AudioStem(name: stem.name, left: left, right: right)
        }
    }

    /// Imported clips have picture but no mixable audio yet. Zeroing their
    /// spans stops the recording's last sample from droning under them.
    static func silenceClips(_ tl: Timeline, _ L: inout [Float], _ R: inout [Float], fs: Double) {
        for clip in tl.clips {
            let a = max(Int(clip.start * fs), 0), b = min(Int(clip.end * fs) + 1, L.count)
            guard b > a else { continue }
            for i in a..<b { L[i] = 0; R[i] = 0 }
        }
    }

    public func mix(_ tl: Timeline) -> MixedAudio? {
        guard let d = tl.derived else { return nil }
        let fs = AudioIO.fs, n = Int(tl.compositionDuration * fs) + 1, a = tl.audio, tm = tl.timeMap
        var L = [Float](repeating: 0, count: n), R = L
        var hasProgram = false                                   // voice / system / music (not just SFX)

        if a.micMode != .off, let v = voiceChain(a) {
            let y = Self.mapped(v, offset: micOffset, tm: tm, n: n, muteRamps: a.muteMicInRamps)
            let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
            for i in 0..<n { L[i] += y[i] * gain; R[i] += y[i] * gain }
            hasProgram = true
        }
        if a.micMode != .off {
            for index in extraMicrophones.indices {
                guard let processed = extraVoiceChain(index, plan: a) else { continue }
                let mapped = Self.mapped(processed, offset: extraMicrophones[index].offset,
                                         tm: tm, n: n, muteRamps: a.muteMicInRamps)
                let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
                for i in 0..<n { L[i] += mapped[i] * gain; R[i] += mapped[i] * gain }
                hasProgram = true
            }
        }
        if let s = sys {
            let left = Self.mapped(s, offset: sysOffset, tm: tm, n: n, muteRamps: true)
            let right = sysRight.map { Self.mapped($0, offset: sysOffset, tm: tm, n: n, muteRamps: true) } ?? left
            let gain = Float(pow(10, clamp(a.systemGainDb, -60, 24) / 20))
            for i in 0..<n { L[i] += left[i] * gain; R[i] += right[i] * gain }
            hasProgram = true
        }
        for lane in a.lanes where !lane.mute && (lane.role == .voiceover || lane.role == .music) {
            guard let path = lane.path, let track = importTrack(path) else { continue }
            let offset = Int(max(0, lane.placement) * fs)
            guard offset < n else { continue }
            let count = min(n - offset, track.l.count)
            let gain = Float(pow(10, clamp(lane.gainDb, -60, 24) / 20))
            let fadeLength = min(Int(0.01 * fs), count / 2)
            for i in 0..<count {
                let fadeIn = fadeLength > 0 ? min(1, Float(i) / Float(fadeLength)) : 1
                let fadeOut = fadeLength > 0 ? min(1, Float(count - i - 1) / Float(fadeLength)) : 1
                let g = gain * min(fadeIn, fadeOut)
                L[offset + i] += track.l[i] * g
                R[offset + i] += track.r[i] * g
            }
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

        for cue in d.cues {
            let (buf, gain) = bank.render(cue.kind, clickTone: a.clickTone)
            let amp = Float(pow(10, (a.sfxGainDb + cue.gainDb + gain) / 20)), s0 = Int(cue.t * fs)
            for (k, v) in buf.enumerated() where s0 + k >= 0 && s0 + k < n {
                L[s0 + k] += v * amp; R[s0 + k] += v * amp
            }
        }

        Self.silenceClips(tl, &L, &R, fs: fs)
        var ch = [L, R]
        var lufs = Loudness.integrated(ch)
        let offsetDb: Double
        if a.normalize, hasProgram, lufs > -69 {
            offsetDb = a.targetLUFS - lufs + a.outputGainDb
        } else {
            offsetDb = a.outputGainDb
        }
        let master = Float(pow(10, clamp(offsetDb, -36, 30) / 20))
        ch = ch.map { vDSP.multiply(master, $0) }
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
    private let engine = AVAudioEngine(), node = AVAudioPlayerNode(), previewNode = AVAudioPlayerNode()
    private struct Buffer: @unchecked Sendable { let value: AVAudioPCMBuffer }
    private let mixed = OSAllocatedUnfairLock<(audio: MixedAudio?, buffer: Buffer?)>(initialState: (nil, nil))
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!

    public init() {
        engine.attach(node); engine.attach(previewNode)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.connect(previewNode, to: engine.mainMixerNode, format: fmt)
    }

    /// Hardware output latency (Bluetooth sinks are large). Used to schedule
    /// audio so it is HEARD on the same host instant as the video frame.
    public var outputLatency: Double { engine.isRunning ? engine.outputNode.presentationLatency : 0 }

    /// Plays the selected click at the current click level without touching
    /// the timeline playback node, so the preview never desyncs transport.
    public func previewClick(_ plan: AudioPlan) {
        let (samples, bankGain) = SFXBank().render(.click, clickTone: plan.clickTone)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        let amp = Float(pow(10, (plan.sfxGainDb + bankGain) / 20))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in samples.indices {
            buffer.floatChannelData![0][i] = samples[i] * amp
            buffer.floatChannelData![1][i] = samples[i] * amp
        }
        if !engine.isRunning { try? engine.start() }
        previewNode.stop()
        previewNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        previewNode.play()
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
        let latency = outputLatency
        let start = max(h - latency, HostClock.now() + 0.005)
        node.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start)))
        return max(h, start + latency)
    }

    public func stop() { node.stop() }
}
