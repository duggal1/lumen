import Foundation
import Accelerate
import AVFoundation
import CryptoKit
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

/// A bounded provisional PCM interval with an exact output-clock origin.
public struct PreviewAudioWindow: Sendable {
    public let startFrame: Int64
    public let audio: MixedAudio
    public var endFrame: Int64 { startFrame + Int64(audio.l.count) }
    public var start: Double { Double(startFrame) / AudioIO.fs }
    public var end: Double { Double(endFrame) / AudioIO.fs }
    public init(startFrame: Int64, audio: MixedAudio) {
        self.startFrame = startFrame; self.audio = audio
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

/// A recorded track that is still on disk. Studio opens without decoding any
/// audio: the mixer resolves each source through a single-flight slot the first
/// time a sample is actually needed.
public struct RecordedMicrophoneSource: Sendable {
    public let deviceName: String
    public let url: URL
    public let offset: Double
    public init(deviceName: String, url: URL, offset: Double) {
        self.deviceName = deviceName; self.url = url; self.offset = offset
    }
}

/// Which part of the program a render covers. Both the preview prefix and the
/// exported program go through the same DSP and the same time map; only the
/// number of output samples differs.
public enum AudioRange: Sendable, Equatable {
    case whole
    case prefix(Double)

    public var seconds: Double? {
        if case .prefix(let s) = self { return s }
        return nil
    }
}

/// Single-flight, thread-safe cache of decoded source samples. The load runs
/// outside the lock, so a long decode never serialises other work; a second
/// caller for the same key waits for the first instead of decoding again.
private final class SampleCache: @unchecked Sendable {
    private let lock = NSCondition()
    private var values: [String: [Float]] = [:]
    private var loading: Set<String> = []

    func value(_ key: String, _ load: () -> [Float]?) -> [Float]? {
        lock.lock()
        if let v = values[key] { lock.unlock(); return v }
        if loading.contains(key) {
            while loading.contains(key) { lock.wait() }
            let v = values[key]
            lock.unlock()
            return v
        }
        loading.insert(key)
        lock.unlock()
        let produced = load()
        lock.lock()
        loading.remove(key)
        if let produced { values[key] = produced }
        lock.broadcast()
        lock.unlock()
        return produced
    }

    func install(_ key: String, _ value: [Float]) {
        lock.lock(); values[key] = value; loading.remove(key); lock.broadcast(); lock.unlock()
    }

    func has(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values[key] != nil }

    /// Drops the whole-program copy once a bounded render has published its own
    /// prefix, so a long take does not hold two full decodes in memory.
    func remove(_ key: String) { lock.lock(); values[key] = nil; lock.unlock() }
}

/// The same single-flight shape for the one genuinely stereo source (the system
/// audio track), decoded once for both channels.
private final class StereoSampleCache: @unchecked Sendable {
    private let lock = NSCondition()
    private var values: [String: ([Float], [Float])] = [:]
    private var loading: Set<String> = []

    func value(_ key: String, _ load: () -> ([Float], [Float])?) -> ([Float], [Float])? {
        lock.lock()
        if let v = values[key] { lock.unlock(); return v }
        if loading.contains(key) {
            while loading.contains(key) { lock.wait() }
            let v = values[key]
            lock.unlock()
            return v
        }
        loading.insert(key)
        lock.unlock()
        let produced = load()
        lock.lock()
        loading.remove(key)
        if let produced { values[key] = produced }
        lock.broadcast()
        lock.unlock()
        return produced
    }

    func install(_ key: String, _ value: ([Float], [Float])) {
        lock.lock(); values[key] = value; loading.remove(key); lock.broadcast(); lock.unlock()
    }
}

/// One in-flight voice render. Waiters block on the job condition, never on a
/// lock that the DSP holds, and a cancelled waiter stops waiting immediately.
private final class VoiceJob: @unchecked Sendable {
    let key: String
    let lock = NSCondition()
    var result: [Float]?
    var finished = false
    var waiters = 0
    init(key: String) { self.key = key }
}

/// Offline mix of the whole timeline. Preview plays this buffer; export encodes it. One code path = they always match.
/// Processed microphone Float32 WAVs are cached by source content and exact settings.
public final class AudioMixer: @unchecked Sendable {
    private struct MusicCache { var path: String; var track: MusicTrack?; var lufs: Double }
    private struct VoiceKey: Hashable { var mic: Int; var settings: String }

    /// Voice sits at -16 LUFS before the master stage. Music reference is 6 dB hotter so the default
    /// `musicGainDb` (-18) lands the bed ~12 dB under the voice at rest (plan 10.3).
    static let voiceRefLUFS = -16.0, musicRefLUFS = -10.0

    /// The first audible window. Long enough to cover a click cue, the typing
    /// cues that follow it and the first phrase of speech; short enough that
    /// the neural denoiser renders it in a fraction of a second.
    public static let firstWindowSeconds = 4.0

    private let mic: [Float]?, micOffset: Double, sys: [Float]?, sysRight: [Float]?, sysOffset: Double
    private let extraMicrophones: [RecordedMicrophone]
    private let cacheDir: URL?
    /// Key-down times in MIC-FILE time (events rebased by micOffset by the caller).
    /// Empty disables declick (tests call this directly).
    private let keyTimes: [Double]
    private let bank = SFXBank()

    // MARK: Source resolution (lazy: opening a project reads no audio)

    private let samples = SampleCache()
    private let stereo = StereoSampleCache()
    private let micURL: URL?
    private let systemURL: URL?
    private var extraSources: [RecordedMicrophoneSource] = []
    private let prefixSeconds: Double

    // MARK: Voice work (single-flight, cancellable; one lock, held only for
    // cache lookup and publication)

    private let state = NSLock()
    private var voice: [VoiceKey: [Float]] = [:]
    private var jobs: [String: VoiceJob] = [:]
    private var music: MusicCache?
    private var imported: [String: MusicTrack] = [:]
    private let keyBankLock = NSLock()
    private var keyBank: [String: [Int: [Float]]] = [:]
    private var customDenoiser: (any Denoiser)?

    public var denoiser: any Denoiser {
        get { state.lock(); defer { state.unlock() }; return customDenoiser ?? defaultDenoiser }
        set {
            state.lock()
            customDenoiser = newValue
            voice.removeAll()
            state.unlock()
        }
    }

    private var defaultDenoiser: any Denoiser { TrainedVoiceDenoiser(strength: 1) }

    public init(mic: [Float]?, micOffset: Double, system: [Float]?, systemOffset: Double,
                systemRight: [Float]? = nil,
                additionalMicrophones: [RecordedMicrophone] = [], cacheDir: URL? = nil,
                keyTimes: [Double] = []) {
        self.mic = mic; self.micOffset = micOffset; sys = system
        sysRight = systemRight; sysOffset = systemOffset
        extraMicrophones = additionalMicrophones; self.cacheDir = cacheDir
        self.keyTimes = keyTimes
        micURL = nil; systemURL = nil; prefixSeconds = Self.firstWindowSeconds
        if let mic { samples.install("mic:whole", mic) }
        if let system { stereo.install("system:whole", (system, systemRight ?? system)) }
        for (i, extra) in additionalMicrophones.enumerated() { samples.install("extra:\(i)", extra.samples) }
        if let cacheDir { try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true) }
    }

    /// Studio's opening path: the tracks stay on disk until a render needs
    /// them. Nothing here touches the file system.
    public init(micURL: URL?, micOffset: Double, systemURL: URL?, systemOffset: Double,
                additionalMicrophones: [RecordedMicrophoneSource] = [], cacheDir: URL? = nil,
                keyTimes: [Double] = [], prefixSeconds: Double = AudioMixer.firstWindowSeconds) {
        self.mic = nil; self.micOffset = micOffset; self.sys = nil; sysRight = nil; sysOffset = systemOffset
        self.micURL = micURL; self.systemURL = systemURL
        extraMicrophones = []; extraSources = additionalMicrophones
        self.cacheDir = cacheDir; self.keyTimes = keyTimes
        self.prefixSeconds = max(0.25, prefixSeconds)
        if let cacheDir { try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true) }
    }

    /// Background preparation publishes decoded tracks here, so the first Play
    /// never pays for a decode it could have done while the window opened.
    public func installAudio(mic: [Float]? = nil, system: [Float]? = nil, systemRight: [Float]? = nil,
                             additionalMicrophones: [RecordedMicrophone] = []) {
        if let mic { samples.install("mic:whole", mic) }
        if let system { stereo.install("system:whole", (system, systemRight ?? system)) }
        for (i, extra) in additionalMicrophones.enumerated() { samples.install("extra:\(i)", extra.samples) }
    }

    private func micSamples(_ range: AudioRange) -> [Float]? {
        if let mic { return mic }
        guard let micURL else { return nil }
        switch range {
        case .whole: return samples.value("mic:whole") { try? AudioIO.readMono(micURL) }
        case .prefix(let s): return samples.value("mic:\(s)s") { try? AudioIO.readMonoPrefix(micURL, seconds: s) }
        }
    }

    private func systemSamples(_ range: AudioRange) -> ([Float], [Float])? {
        if let sys { return (sys, sysRight ?? sys) }
        guard let systemURL else { return nil }
        switch range {
        case .whole: return stereo.value("system:whole") { try? AudioIO.readStereo(systemURL) }
        case .prefix(let s): return stereo.value("system:\(s)s") { try? AudioIO.readStereoPrefix(systemURL, seconds: s) }
        }
    }

    private func extraCount() -> Int { extraMicrophones.count + extraSources.count }

    private func extraSource(_ index: Int) -> (name: String, offset: Double, url: URL?, samples: [Float]?) {
        if index < extraMicrophones.count {
            let m = extraMicrophones[index]
            return (m.deviceName, m.offset, nil, m.samples)
        }
        let s = extraSources[index - extraMicrophones.count]
        return (s.deviceName, s.offset, s.url, nil)
    }

    private func extraSamples(_ index: Int, _ range: AudioRange) -> [Float]? {
        let source = extraSource(index)
        if let provided = source.samples { return provided }
        guard let url = source.url else { return nil }
        let key = "extra:\(index)"
        switch range {
        case .whole: return samples.value(key) { try? AudioIO.readMono(url) }
        case .prefix(let s): return samples.value("\(key):\(s)s") { try? AudioIO.readMonoPrefix(url, seconds: s) }
        }
    }

    // MARK: Voice processing

    /// The processed microphone for one output range. Single-flight per
    /// (source, settings, sample count): a second caller for the same key waits
    /// on the job instead of re-running the denoiser, and no lock is held
    /// across the DSP, the disk cache read or the disk cache write.
    private func voiceChain(_ plan: AudioPlan, micIndex: Int, range: AudioRange,
                            cancelled: (@Sendable () -> Bool)? = nil) -> [Float]? {
        guard plan.micMode != .off else { return nil }
        guard let samples = extraOrMicSamples(micIndex, range), !samples.isEmpty else { return nil }
        let keys = micIndex == 0 && plan.declick ? keyTimes : []
        let signature: String
        do { signature = try ProcessedVoiceCache.key(samples: samples, plan: plan, keyTimes: keys) }
        catch { return nil }
        let key = VoiceKey(mic: micIndex, settings: signature)
        // Only the full-program render is worth persisting: a prefix is a
        // provisional window and must never occupy the full render's slot.
        let diskURL: URL? = {
            guard !hasCustomDenoiser, range.seconds == nil, let cacheDir else { return nil }
            return cacheDir.appendingPathComponent("voice-\(signature)-48000.wav")
        }()
        return voiceProcessed(key: key, signature: signature, samples: samples, plan: plan,
                              keyTimes: keys, diskURL: diskURL, cancelled: cancelled)
    }

    private var hasCustomDenoiser: Bool {
        state.lock(); defer { state.unlock() }
        return customDenoiser != nil
    }

    private func extraOrMicSamples(_ micIndex: Int, _ range: AudioRange) -> [Float]? {
        micIndex == 0 ? micSamples(range) : extraSamples(micIndex - 1, range)
    }

    private func voiceProcessed(key: VoiceKey, signature: String, samples: [Float], plan: AudioPlan,
                                keyTimes: [Double], diskURL: URL?,
                                cancelled: (@Sendable () -> Bool)?) -> [Float]? {
        state.lock()
        if let cached = voice[key] { state.unlock(); return cached }
        if let existing = jobs[signature] {
            existing.waiters += 1
            state.unlock()
            return waitFor(existing, cancelled: cancelled)
        }
        let job = VoiceJob(key: signature)
        jobs[signature] = job
        let denoiser = customDenoiser
        state.unlock()

        if let diskURL, let cached = ProcessedVoiceCache.read(diskURL, count: samples.count, rate: AudioIO.fs) {
            publish(job, key: key, value: cached)
            return cached
        }
        let processed = ProcessedVoiceCache.process(samples, plan: plan, keyTimes: keyTimes,
                                                   denoiser: denoiser, cancelled: cancelled)
        // A cancelled render produces no result at all: silence would be a lie.
        guard !(processed.isEmpty && cancelled?() == true) else {
            finish(job, key: key, value: nil)
            return nil
        }
        if let diskURL, cancelled?() != true { try? ProcessedVoiceCache.write(processed, rate: AudioIO.fs, to: diskURL) }
        publish(job, key: key, value: processed)
        return processed
    }

    private func publish(_ job: VoiceJob, key: VoiceKey, value: [Float]?) {
        state.lock()
        if let value { voice[key] = value }
        if voice.count >= max(3, extraCount() + 1) { voice.removeAll() }
        jobs.removeValue(forKey: job.key)
        state.unlock()
        job.lock.lock()
        job.result = value
        job.finished = true
        job.lock.broadcast()
        job.lock.unlock()
    }

    /// Same as `publish`, but the job produced nothing: waiters still wake up
    /// instead of blocking behind work that no longer exists.
    private func finish(_ job: VoiceJob, key: VoiceKey, value: [Float]?) {
        state.lock(); jobs.removeValue(forKey: job.key); state.unlock()
        job.lock.lock(); job.result = value; job.finished = true; job.lock.broadcast(); job.lock.unlock()
    }

    private func waitFor(_ job: VoiceJob, cancelled: (@Sendable () -> Bool)?) -> [Float]? {
        job.lock.lock()
        while !job.finished {
            if cancelled?() == true {
                job.waiters -= 1
                job.lock.unlock()
                return nil
            }
            // Recompute the deadline every round. A fixed deadline that has
            // already passed makes `wait(until:)` return immediately forever:
            // the waiter then spins on the condition lock at 100 % CPU and can
            // starve the publisher, so a 400 ms render never lands. Polling in
            // 50 ms slices keeps cancellation responsive without the spin.
            job.lock.wait(until: Date().addingTimeInterval(0.05))
        }
        let result = job.result
        job.waiters -= 1
        job.lock.unlock()
        return result
    }

    /// Start the expensive neural pass while the editor prepares its first
    /// frame. Cancellable by default: a warm-up runs inside a task, and
    /// cancelling that task stops the DSP between chunks instead of leaving a
    /// subprocess and a render running for a closed editor.
    public func prepareVoice(_ plan: AudioPlan, cancelled: (@Sendable () -> Bool)? = { Task.isCancelled }) {
        for index in -1..<extraCount() where cancelled?() != true {
            _ = voiceChain(plan, micIndex: index + 1, range: .whole, cancelled: cancelled)
        }
    }

    /// Renders the first audible window now. Studio calls this before it lets
    /// the clock start, so the first played frames have their audio.
    public func prepareFirstWindow(_ plan: AudioPlan, cancelled: (@Sendable () -> Bool)? = nil) -> Bool {
        guard cancelled?() != true else { return false }
        for index in -1..<extraCount() where cancelled?() != true {
            _ = voiceChain(plan, micIndex: index + 1, range: .prefix(prefixSeconds), cancelled: cancelled)
        }
        return cancelled?() != true
    }

    private func loadMusic(_ path: String?) -> MusicCache? {
        guard let path else { return nil }
        state.lock()
        if let m = music, m.path == path { state.unlock(); return m }
        state.unlock()
        let t = AudioIO.loadMusic(URL(fileURLWithPath: path))
        let c = MusicCache(path: path, track: t, lufs: t.map { Loudness.integrated([$0.l, $0.r]) } ?? -70)
        state.lock(); music = c; state.unlock()
        return c
    }

    private func importTrack(_ path: String) -> MusicTrack? {
        state.lock()
        let cached = imported[path]
        state.unlock()
        if let cached { return cached }
        guard let (l, r) = try? AudioIO.readStereo(URL(fileURLWithPath: path)),
              !l.isEmpty, l.count == r.count else { return nil }
        let result = MusicTrack(l: l, r: r)
        state.lock()
        imported[path] = result
        state.unlock()
        return result
    }

    // MARK: Building blocks (mapped lives in AudioMapped.swift)

    /// Loop with 0.5 s crossfade to length n, 0.3 s fade-in, 1.5 s fade-out.
    /// A bounded render keeps the fade-in and drops the fade-out, so the prefix
    /// of the music bed is the same signal the full mix will have.
    static func fit(_ m: MusicTrack, n: Int, fadeOut: Bool = true) -> ([Float], [Float]) {
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
            let fin = min(1, Float(k) / Float(0.3 * fs))
            let fout = fadeOut ? min(1, Float(n - k) / Float(1.5 * fs)) : 1
            let g = fin * fout
            L[k] *= g; R[k] *= g
        }
        return (L, R)
    }

    /// Resolve every unmuted music lane into a value-level bed and its decoded
    /// stereo track. A bed whose file cannot be decoded is skipped, never
    /// replaced by silence or a fabricated loop.
    private func musicBeds(_ tl: Timeline) -> ([MusicBed], [UUID: MusicBed.PCM]) {
        var beds: [MusicBed] = []
        var tracks: [UUID: MusicBed.PCM] = [:]
        for lane in tl.audio.lanes where lane.role == .music && !lane.mute {
            guard let path = lane.path, let track = importTrack(path) else { continue }
            let bed = MusicBed(lane: lane)
            beds.append(bed)
            tracks[bed.id] = MusicBed.PCM(left: track.l, right: track.r)
        }
        return (beds, tracks)
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

        if a.micMode != .off, let voice = voiceChain(a, micIndex: 0, range: .whole) {
            let mapped = Self.mapped(voice, offset: micOffset, tm: tm,
                                     n: n, muteRamps: a.muteMicInRamps)
            let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
            let channel = mapped.map { $0 * gain }
            result.append(AudioStem(name: "microphone", left: channel, right: channel))
        }
        if a.micMode != .off {
            for index in 0..<extraCount() {
                guard let processed = voiceChain(a, micIndex: index + 1, range: .whole) else { continue }
                let mapped = Self.mapped(processed, offset: extraSource(index).offset,
                                         tm: tm, n: n, muteRamps: a.muteMicInRamps)
                let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
                let channel = mapped.map { $0 * gain }
                result.append(AudioStem(name: "microphone-\(index + 2)", left: channel, right: channel))
            }
        }

        if let (left, right) = systemSamples(.whole) {
            let l = Self.mapped(left, offset: sysOffset, tm: tm, n: n, muteRamps: true)
            let r = Self.mapped(right, offset: sysOffset, tm: tm, n: n, muteRamps: true)
            let gain = Float(pow(10, clamp(a.systemGainDb, -60, 24) / 20))
            result.append(AudioStem(name: "system", left: l.map { $0 * gain }, right: r.map { $0 * gain }))
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
        let (beds, bedTracks) = musicBeds(tl)
        if !beds.isEmpty {
            for musicStem in MusicBed.stems(beds, tracks: bedTracks, duck: tl.derived?.duck,
                                             outputSamples: n, fs: fs) {
                result.append(AudioStem(name: musicStem.name, left: musicStem.left, right: musicStem.right))
            }
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

    /// Full-program mix, exactly what export encodes. An exact valid cache is
    /// reused: reopening a project must not re-run a multi-minute DSP pass to
    /// produce a buffer that is already on disk.
    public func mix(_ tl: Timeline, cancelled: (@Sendable () -> Bool)? = nil) -> MixedAudio? {
        guard let d = tl.derived else { return nil }
        let n = Int(tl.compositionDuration * AudioIO.fs) + 1
        guard n > 0 else { return nil }
        if let cached = mixCacheRead(tl, n: n) { return cached }
        let out = render(tl, derived: d, n: n, range: .whole, cancelled: cancelled)
        if let out, cancelled?() != true { mixCacheWrite(tl, n: n, mix: out) }
        return out
    }

    /// True when this project has anything to play. A silent project (no mic,
    /// no system track, no lanes, no music and no cues) must not be blocked on
    /// audio that does not exist.
    public func hasProgram(_ tl: Timeline) -> Bool {
        let a = tl.audio
        if a.micMode != .off, micURL != nil || mic != nil || extraCount() > 0 { return true }
        if sys != nil || systemURL != nil { return true }
        if a.musicPath != nil { return true }
        if a.lanes.contains(where: { !$0.mute && $0.path != nil && ($0.role == .voiceover || $0.role == .music) }) { return true }
        if a.soundEffectsEnabled, let cues = tl.derived?.cues, !cues.isEmpty { return true }
        return false
    }

    /// The bounded first audible window. Same DSP, same time map, same master
    /// formula; provisional only in the loudness reference, which the full mix
    /// replaces at a synchronized boundary.
    public func mixFirstWindow(_ tl: Timeline, cancelled: (@Sendable () -> Bool)? = nil) -> MixedAudio? {
        guard let d = tl.derived else { return nil }
        let full = Int(tl.compositionDuration * AudioIO.fs) + 1
        let n = min(full, max(Int(prefixSeconds * AudioIO.fs) + 1, 1))
        guard n > 0 else { return nil }
        return render(tl, derived: d, n: n, range: .prefix(prefixSeconds), cancelled: cancelled)
    }

    private func render(_ tl: Timeline, derived d: DerivedTracks, n: Int, range: AudioRange,
                        cancelled: (@Sendable () -> Bool)?) -> MixedAudio? {
        let fs = AudioIO.fs, a = tl.audio, tm = tl.timeMap
        var L = [Float](repeating: 0, count: n), R = L
        var hasProgram = false                                   // voice / system / music (not just SFX)

        if a.micMode != .off, let v = voiceChain(a, micIndex: 0, range: range, cancelled: cancelled) {
            let y = Self.mapped(v, offset: micOffset, tm: tm, n: n, muteRamps: a.muteMicInRamps)
            let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
            for i in 0..<n { L[i] += y[i] * gain; R[i] += y[i] * gain }
            hasProgram = true
        }
        if a.micMode != .off {
            for index in 0..<extraCount() {
                guard let processed = voiceChain(a, micIndex: index + 1, range: range, cancelled: cancelled) else { continue }
                let mapped = Self.mapped(processed, offset: extraSource(index).offset,
                                         tm: tm, n: n, muteRamps: a.muteMicInRamps)
                let gain = Float(pow(10, clamp(a.micGainDb, -60, 24) / 20))
                for i in 0..<n { L[i] += mapped[i] * gain; R[i] += mapped[i] * gain }
                hasProgram = true
            }
        }
        if let (left, right) = systemSamples(range) {
            let l = Self.mapped(left, offset: sysOffset, tm: tm, n: n, muteRamps: true)
            let r = Self.mapped(right, offset: sysOffset, tm: tm, n: n, muteRamps: true)
            let gain = Float(pow(10, clamp(a.systemGainDb, -60, 24) / 20))
            for i in 0..<n { L[i] += l[i] * gain; R[i] += r[i] * gain }
            hasProgram = true
        }
        for lane in a.lanes where !lane.mute && lane.role == .voiceover {
            guard let path = lane.path, let track = importTrack(path) else { continue }
            let offset = Int(max(0, lane.placement) * fs)
            guard offset < n else { continue }
            let sourceCount = min(track.l.count, track.r.count)
            let trimStart = lane.trimStart.flatMap { $0.isFinite ? max($0, 0) : nil } ?? 0
            let sourceOffset = Int(min(trimStart * fs, Double(sourceCount)))
            let available = sourceCount - sourceOffset
            let duration = lane.trimDuration.flatMap { $0.isFinite ? max($0, 0) : nil }
            let trimmedCount = duration.map { Int(min($0 * fs, Double(available))) } ?? available
            let count = min(n - offset, trimmedCount)
            guard count > 0 else { continue }
            let gain = Float(pow(10, clamp(lane.gainDb, -60, 24) / 20))
            let fadeLength = min(Int(0.01 * fs), count / 2)
            for i in 0..<count {
                let fadeIn = fadeLength > 0 ? min(1, Float(i) / Float(fadeLength)) : 1
                let fadeOut = fadeLength > 0 ? min(1, Float(count - i - 1) / Float(fadeLength)) : 1
                let g = gain * min(fadeIn, fadeOut)
                L[offset + i] += track.l[sourceOffset + i] * g
                R[offset + i] += track.r[sourceOffset + i] * g
            }
            hasProgram = true
        }
        let (beds, bedTracks) = musicBeds(tl)
        if !beds.isEmpty {
            let rendered = MusicBed.render(beds: beds, tracks: bedTracks, duck: d.duck,
                                            outputSamples: n, fs: fs)
            for i in 0..<n { L[i] += rendered.left[i]; R[i] += rendered.right[i] }
            hasProgram = true
        }
        if let mc = loadMusic(a.musicPath), let mt = mc.track {
            let (ml, mr) = Self.fit(mt, n: n, fadeOut: range.seconds == nil)
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

        renderCues(tl, startFrame: 0, left: &L, right: &R, cancelled: cancelled)
        Self.silenceClips(tl, &L, &R, fs: fs)
        return AudioMaster.process([L, R], plan: a, hasProgram: hasProgram)
    }

    /// The same physical keyboard bank feeds provisional playback and export.
    /// Decode/resample once per selected pack and event edge, not once per mix.
    private func typingPCM(packID: String, release: Bool) -> [Int: [Float]] {
        let cacheKey = packID + (release ? ":up" : ":down")
        keyBankLock.lock()
        let ready = keyBank[cacheKey]
        keyBankLock.unlock()
        if let ready { return ready }
        guard let directory = TypingPackLoader.dir(for: packID) else { return [:] }
        let loaded = release ? TypingPackLoader.releaseBuffers(in: directory) : TypingPackLoader.buffers(in: directory)
        var result: [Int: [Float]] = [:]
        for (code, buffer) in loaded {
            guard let channel = buffer.floatChannelData?[0] else { continue }
            let raw = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let samples = AudioIO.resample(raw, from: buffer.format.sampleRate)
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            guard peak > 1e-4 else { continue }
            result[code] = samples.map { $0 / peak }
        }
        keyBankLock.lock()
        // Retain only the selected pack's two banks; switching packs cannot
        // grow the cache indefinitely.
        keyBank = keyBank.filter { $0.key.hasPrefix(packID + ":") }
        keyBank[cacheKey] = result
        keyBankLock.unlock()
        return result
    }

    private func renderCues(_ tl: Timeline, startFrame: Int64, left: inout [Float], right: inout [Float],
                            cancelled: (@Sendable () -> Bool)? = nil) {
        let a = tl.audio, fs = AudioIO.fs
        guard a.soundEffectsEnabled, let d = tl.derived, !d.cues.isEmpty else { return }
        let start = Double(startFrame) / fs
        let end = start + Double(left.count) / fs
        // Include an earlier transient whose tail overlaps this PCM window.
        // The recorded key/click packs contain short one-shot samples.
        var lo = 0, hi = d.cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if d.cues[mid].t < start - 2 { lo = mid + 1 } else { hi = mid }
        }
        var previousPress: Double?
        for cue in d.cues.dropFirst(lo) {
            if cancelled?() == true { return }
            if cue.t >= end { break }
            guard cue.t.isFinite else { continue }
            let samples: [Float]
            let gain: Float
            let pan: Float
            if cue.kind == .key {
                guard a.keySounds else { continue }
                let pcm = typingPCM(packID: a.typingPackId, release: cue.isKeyRelease)
                let key = Int(cue.keyCode), codes = Set(pcm.keys)
                let code = TypingPackLoader.packCode(for: key, definedIn: codes)
                    ?? TypingPackLoader.fallbackCode(for: key, definedIn: codes)
                if let code, let exact = pcm[code] { samples = exact }
                else if cue.isKeyRelease { continue }
                else { samples = bank.render(.key).samples }
                let gap = previousPress.map { cue.t - $0 } ?? 1
                let cadence: Float = gap < 0.05 ? 0.82 : gap < 0.15 ? 0.92 : 1
                let edge: Float = cue.isKeyRelease ? 0.45 : 1
                // Stable per-event gain variation; no preview/export RNG drift.
                let eventSeed = UInt64(bitPattern: Int64((cue.t * fs).rounded())) &* 6364136223846793005 &+ UInt64(cue.keyCode)
                let variation = 0.975 + Float((eventSeed >> 32) & 255) / 255 * 0.05
                gain = Float(pow(10, clamp(a.typingLevelDb + cue.gainDb, -60, 12) / 20)) * cadence * edge * variation
                if !cue.isKeyRelease { previousPress = cue.t }
                // Mild physical keyboard positioning; modifiers stay near their side.
                switch key {
                case 0, 1, 6, 7, 12, 13, 14, 55, 56, 58, 59: pan = -0.12
                case 30, 31, 33, 35, 36, 37, 40, 41, 42, 44, 47, 51, 54, 60, 61, 62: pan = 0.12
                default: pan = 0
                }
            } else {
                let rendered = bank.render(cue.kind, clickTone: a.clickTone)
                samples = rendered.samples
                gain = Float(pow(10, clamp(a.sfxGainDb + cue.gainDb + rendered.gainDb, -60, 12) / 20))
                pan = 0
            }
            let offset = Int64((cue.t * fs).rounded()) - startFrame
            let lower = max(0, Int(-offset)), upper = min(samples.count, left.count - Int(offset))
            guard lower < upper else { continue }
            let l = gain * (1 - max(pan, 0)), r = gain * (1 + min(pan, 0))
            for k in lower..<upper {
                let i = Int(offset) + k
                left[i] += samples[k] * l; right[i] += samples[k] * r
            }
        }
    }

    /// Fast, bounded raw program for any seek position, while the canonical
    /// enhanced mix is produced independently. Every sample is evaluated on
    /// the same output clock; no decode from the beginning of a long file.
    public func previewWindow(_ tl: Timeline, at time: Double, seconds: Double = 4,
                              cancelled: (@Sendable () -> Bool)? = nil) -> PreviewAudioWindow? {
        let fs = AudioIO.fs
        guard time.isFinite, seconds.isFinite, seconds > 0, tl.compositionDuration.isFinite else { return nil }
        let startFrame = Int64((max(time, 0) * fs).rounded())
        let total = Int64((max(tl.compositionDuration, 0) * fs).rounded(.up)) + 1
        let count = Int(min(Int64(clamp(seconds, 0.25, 6) * fs), max(total - startFrame, 0)))
        guard count > 0 else { return nil }
        let start = Double(startFrame) / fs
        let tm = tl.timeMap, a = tl.audio
        var left = [Float](repeating: 0, count: count), right = left

        func sample(_ samples: [Float], at position: Double) -> Float {
            guard position.isFinite, position >= 0, position < Double(samples.count) else { return 0 }
            let i = Int(position), next = min(i + 1, samples.count - 1)
            return samples[i] + (samples[next] - samples[i]) * Float(position - Double(i))
        }

        // Cut seams split read ranges: a one-hour source cut never requires
        // loading the skipped hour to play a four-second output window.
        var boundaries = [0, count]
        for cut in tm.cuts {
            let position = Int((tm.output(atSource: cut.end) * fs).rounded()) - Int(startFrame)
            if position > 0, position < count { boundaries.append(position) }
        }
        let block = Int(fs * 0.5)
        if count > block { boundaries += Array(stride(from: block, to: count, by: block)) }
        boundaries = Array(Set(boundaries)).sorted()

        func mixRecorded(url: URL?, provided: [Float]?, providedRight: [Float]?, offset: Double,
                         gainDb: Double, mono: Bool, muteRamps: Bool) {
            guard url != nil || provided != nil else { return }
            let gain = Float(pow(10, clamp(gainDb.isFinite ? gainDb : 0, -60, 24) / 20))
            for segment in 0..<(boundaries.count - 1) {
                if cancelled?() == true { return }
                let lo = boundaries[segment], hi = boundaries[segment + 1]
                let t0 = start + Double(lo) / fs
                let t1 = start + Double(hi - 1) / fs
                if t0 >= tm.outputDuration { continue }
                let s0 = tm.source(atOutput: t0) - offset
                let s1 = tm.source(atOutput: min(t1, tm.outputDuration)) - offset
                let sourceLo = max(0, min(s0, s1) - 0.005), sourceHi = max(s0, s1) + 0.005
                guard sourceHi > sourceLo, sourceHi - sourceLo <= 32 else { continue }
                let decoded: (left: [Float], right: [Float], origin: Double)
                if let provided { decoded = (provided, providedRight ?? provided, 0) }
                else if let url, let data = try? AudioIO.readStereoWindow(url, from: sourceLo, to: sourceHi) { decoded = data }
                else { continue }
                let step = 48
                var i = lo
                while i < hi {
                    let j = min(i + step, hi)
                    let o0 = start + Double(i) / fs
                    let o1 = start + Double(max(j - 1, i)) / fs
                    if o0 >= tm.outputDuration { break }
                    let first = tm.source(atOutput: o0) - offset
                    let last = tm.source(atOutput: min(o1, tm.outputDuration)) - offset
                    let speed = j > i + 1 ? (last - first) * fs / Double(j - i - 1) : 1
                    if !(muteRamps && speed > 1.2) {
                        for k in i..<j {
                            let u = Double(k - i) / Double(max(j - i - 1, 1))
                            let source = (first + (last - first) * u - decoded.origin) * fs
                            let l = sample(decoded.left, at: source)
                            let r = sample(decoded.right, at: source)
                            if mono {
                                let value = (l + r) * 0.5 * gain
                                left[k] += value; right[k] += value
                            } else {
                                left[k] += l * gain; right[k] += r * gain
                            }
                        }
                    }
                    i = j
                }
            }
        }
        if a.micMode != .off {
            mixRecorded(url: micURL, provided: mic, providedRight: nil, offset: micOffset,
                        gainDb: a.micGainDb + a.voiceBoostDb, mono: true, muteRamps: a.muteMicInRamps)
            for index in 0..<extraCount() {
                let source = extraSource(index)
                mixRecorded(url: source.url, provided: source.samples, providedRight: nil, offset: source.offset,
                            gainDb: a.micGainDb + a.voiceBoostDb, mono: true, muteRamps: a.muteMicInRamps)
            }
        }
        mixRecorded(url: systemURL, provided: sys, providedRight: sysRight, offset: sysOffset,
                    gainDb: a.systemGainDb, mono: false, muteRamps: true)

        // Imported voiceover is on the output clock. Read only its overlap.
        for lane in a.lanes where lane.role == .voiceover && !lane.mute {
            if cancelled?() == true { return nil }
            guard let path = lane.path else { continue }
            let trim = max(lane.trimStart ?? 0, 0)
            let lo = max(start, lane.placement)
            let hi = min(start + Double(count) / fs, lane.placement + (lane.trimDuration ?? tl.compositionDuration))
            guard hi > lo, let data = try? AudioIO.readStereoWindow(URL(fileURLWithPath: path),
                 from: lo - lane.placement + trim, to: hi - lane.placement + trim + 0.002) else { continue }
            let gain = Float(pow(10, clamp(lane.gainDb, -60, 24) / 20))
            for i in max(0, Int(((lo - start) * fs).rounded()))..<min(count, Int(((hi - start) * fs).rounded())) {
                let pos = (start + Double(i) / fs - lane.placement + trim - data.origin) * fs
                left[i] += sample(data.left, at: pos) * gain
                right[i] += sample(data.right, at: pos) * gain
            }
        }

        // The existing value-level music plan provides the same loop period,
        // trim, fade and duck semantics without allocating the entire output.
        let (beds, tracks) = musicBeds(tl)
        for bed in beds {
            guard let track = tracks[bed.id] else { continue }
            let plan = MusicBed.plan(bed, track: track, outputSamples: Int(total), fs: fs)
            guard plan.isRenderable else { continue }
            let period = max(plan.sourceSpan - plan.crossfade, 1)
            let lo = max(Int(startFrame), plan.start), hi = min(Int(startFrame) + count, plan.start + plan.count)
            guard hi > lo else { continue }
            for output in lo..<hi {
                let local = output - plan.start
                let phase = plan.loops ? local % period : local
                let source = plan.sourceStart + phase
                let prev = source + period
                let fade = plan.loops && local >= period && phase < plan.crossfade ? Float(phase) / Float(max(plan.crossfade, 1)) : 1
                let edge = min(plan.fadeIn > 0 ? Float(local) / Float(plan.fadeIn) : 1,
                               plan.fadeOut > 0 ? Float(plan.count - local) / Float(plan.fadeOut) : 1, 1)
                let g = plan.gain * max(edge, 0) * MusicBed.duckGain(tl.derived?.duck, atSample: output, fs: fs)
                let i = output - Int(startFrame)
                left[i] += (sample(track.left, at: Double(source)) * fade + sample(track.left, at: Double(prev)) * (1 - fade)) * g
                right[i] += (sample(track.right, at: Double(source)) * fade + sample(track.right, at: Double(prev)) * (1 - fade)) * g
            }
        }
        if cancelled?() == true { return nil }
        renderCues(tl, startFrame: startFrame, left: &left, right: &right, cancelled: cancelled)
        for clip in tl.clips {
            let lo = max(Int((clip.start * fs).rounded()) - Int(startFrame), 0)
            let hi = min(Int((clip.end * fs).rounded()) - Int(startFrame), count)
            if hi > lo { for i in lo..<hi { left[i] = 0; right[i] = 0 } }
        }
        // No independent loudness normalization per window: it would cause
        // obvious pumping at the rolling-window boundary. Only a safety limit.
        let ceiling = Float(pow(10, -1.0 / 20))
        let gain = Float(pow(10, clamp(a.outputGainDb, -60, 24) / 20))
        for i in 0..<count {
            let l = left[i] * gain, r = right[i] * gain
            let peak = max(abs(l), abs(r))
            let trim = peak > ceiling ? ceiling / peak : 1
            left[i] = l.isFinite ? l * trim : 0; right[i] = r.isFinite ? r * trim : 0
        }
        return PreviewAudioWindow(startFrame: startFrame,
                                  audio: MixedAudio(l: left, r: right, lufs: -120, truePeakDb: -1))
    }

    // MARK: Mix cache (exact, keyed by media identity + algorithm + settings + time map)

    private func mixSignature(_ tl: Timeline, n: Int) -> String? {
        guard cacheDir != nil else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256()
        hash.update(data: Data((ProcessedVoiceCache.mixRevision + "|\(n)|\(customDenoiser == nil ? "df3" : "custom")").utf8))
        if let d = try? encoder.encode(tl.audio) { hash.update(data: d) }
        if let d = try? encoder.encode(tl.timeMap) { hash.update(data: d) }
        for clip in tl.clips {
            hash.update(data: Data("\(clip.path)|\(clip.start)|\(clip.end)".utf8))
        }
        if let derived = tl.derived {
            for cue in derived.cues {
                let isKey: Int
                switch cue.kind { case .key: isKey = 1; default: isKey = 0 }
                hash.update(data: Data("\(cue.t)|\(cue.gainDb)|\(cue.keyCode)|\(isKey)|\(cue.isKeyRelease)|\(cue.kind)".utf8))
            }
            // The duck envelope is derived audio: a different envelope means a
            // different music bed, so it belongs in the identity.
            derived.duck.withUnsafeBytes { hash.update(bufferPointer: $0) }
        }
        for file in [micURL, systemURL] {
            if let file { hash.update(data: Data(fileIdentity(file).utf8)) }
        }
        for source in extraSources { hash.update(data: Data(fileIdentity(source.url).utf8)) }
        for extra in extraMicrophones {
            hash.update(data: Data("\(extra.offset)".utf8))
            extra.samples.withUnsafeBytes { hash.update(bufferPointer: $0) }
        }
        if let path = tl.audio.musicPath { hash.update(data: Data(path.utf8)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Path plus size plus modification date: two different recordings of the
    /// same length never share a cache, and a re-recorded file invalidates it.
    private func fileIdentity(_ url: URL) -> String {
        guard let s = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return url.path }
        return "\(url.path)|\(s.fileSize ?? 0)|\(s.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    private func mixCacheRead(_ tl: Timeline, n: Int) -> MixedAudio? {
        guard let signature = mixSignature(tl, n: n), let cacheDir,
              n == Int(tl.compositionDuration * AudioIO.fs) + 1 else { return nil }
        let url = cacheDir.appendingPathComponent("mix-\(signature).caf")
        guard let (l, r) = try? AudioIO.readStereo(url), l.count == n, r.count == n else { return nil }
        let ch = [l, r]
        return MixedAudio(l: l, r: r, lufs: Loudness.integrated(ch), truePeakDb: Loudness.truePeakDb(ch))
    }

    private func mixCacheWrite(_ tl: Timeline, n: Int, mix: MixedAudio) {
        guard let signature = mixSignature(tl, n: n), let cacheDir else { return }
        let url = cacheDir.appendingPathComponent("mix-\(signature).caf")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let temporary = cacheDir.appendingPathComponent("mix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try AudioIO.writeCAF(mix.l, mix.r, to: temporary)
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            // A cache that cannot be written must never fail a mix.
        }
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

    /// True once `load` has installed a non-empty mixed buffer. Transport
    /// reads this to decide whether audio can start locked to video now,
    /// or video must wait in a truthful preparing state.
    public var isLoaded: Bool { mixed.withLock { $0.audio != nil && !($0.audio!.l.isEmpty) } }

    /// Length of the loaded program in seconds.
    public var duration: Double { mixed.withLock { $0.buffer.map { Double($0.value.frameLength) / 48000 } ?? 0 } }

    /// Starts the engine early so a cold first click does not pay engine
    /// startup latency inside the transport gap. Safe to call repeatedly.
    public func warm() { if !engine.isRunning { try? engine.start() } }

    /// Plays the selected click at the current click level without touching
    /// the timeline playback node, so the preview never desyncs transport.
    public func previewClick(_ plan: AudioPlan) {
        guard plan.soundEffectsEnabled, plan.clickSounds else { return }
        let (samples, bankGain) = SFXBank().render(.click, clickTone: plan.clickTone)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        let amp = Float(pow(10, (plan.sfxGainDb + plan.clickGainDb + bankGain) / 20))
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

    private func buffer(from m: MixedAudio, start s: Int) -> AVAudioPCMBuffer? {
        let count = m.l.count - s
        guard count > 0, let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        b.frameLength = AVAudioFrameCount(count)
        m.l.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + s, count: count) }
        m.r.withUnsafeBufferPointer { b.floatChannelData![1].update(from: $0.baseAddress! + s, count: count) }
        return b
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
        } else if let tail = buffer(from: m, start: s) {
            b = tail
        } else { return max(h, HostClock.now() + 0.03) }
        if !engine.isRunning { do { try engine.start() } catch { return max(h, HostClock.now() + 0.03) } }
        node.scheduleBuffer(b, at: nil, options: .interrupts, completionHandler: nil)
        let latency = outputLatency
        let start = max(h - latency, HostClock.now() + 0.005)
        node.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: start)))
        return max(h, start + latency)
    }

    /// Replaces the program with an exact mix at the content position that is
    /// being heard right now, crossfading the head so the join has no step in
    /// time or level. The video clock is never touched, so playback stays
    /// continuous while the provisional window becomes the final program.
    @discardableResult public func upgrade(to m: MixedAudio, atContent t: Double, crossfade: Double = 0.03) -> Bool {
        let snapshot = mixed.withLock { $0 }
        guard let old = snapshot.audio else { load(m); return false }
        let s = min(max(Int(t * 48000), 0), min(old.l.count, m.l.count) - 1)
        guard s >= 0, m.l.count > s else { load(m); return false }
        guard let tail = buffer(from: m, start: s), let previous = buffer(from: old, start: s) else { load(m); return false }
        let count = min(tail.frameLength, previous.frameLength)
        let fade = min(Int(crossfade * 48000), Int(count))
        if fade > 0 {
            for ch in 0..<2 {
                guard let a = tail.floatChannelData?[ch], let b = previous.floatChannelData?[ch] else { continue }
                for i in 0..<fade {
                    let w = Float(i) / Float(fade)
                    a[i] = a[i] * w + b[i] * (1 - w)
                }
            }
        }
        tail.frameLength = count
        if !engine.isRunning { try? engine.start() }
        node.stop()
        node.scheduleBuffer(tail, at: nil, options: .interrupts)
        node.play(at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: HostClock.now() + 0.005)))
        mixed.withLock { $0 = (m, nil) }
        return true
    }

    public func stop() { node.stop() }
}