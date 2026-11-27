import Foundation
import AVFoundation
import LumenCore
import LumenProject

/// Preview-time typing sampler: 16-voice AVAudioEngine pool.
///
/// Two sources are supported. `load(packDir:)` keeps the legacy Mechvibes pack
/// path for old projects and tests. `loadCC0Library()` switches to the new
/// recorded one-shots and adds per-key round-robin variation, pitch/gain jitter
/// and separate key-up takes. Playback is sample-accurate when a host time is
/// supplied by the capture clock.
public final class TypingSampler {
    private let engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var voiceForKey: [Int: Int] = [:]
    private var next = 0

    // CC0 library state
    private var cc0Down: [KeyClass: [AVAudioPCMBuffer]] = [:]
    private var cc0Up: [KeyClass: [AVAudioPCMBuffer]] = [:]
    private var recordedLibrary = KeySoundLibrary()
    private var router = KeyVariationRouter()
    private var usingCC0 = false

    private static let sampleRate = AudioIO.fs

    public init() {
        voices = (0..<16).map { _ in
            let n = AVAudioPlayerNode()
            engine.attach(n)
            return n
        }
        for v in voices { engine.connect(v, to: engine.mainMixerNode, format: nil) }
        engine.prepare()
    }

    // MARK: legacy pack (kept for old projects and compatibility tests)

    public func load(packDir: URL) {
        buffers = TypingPackLoader.buffers(in: packDir)
        voiceForKey.removeAll()
        next = 0
        usingCC0 = false
    }

    /// Deterministic sample selection: exact key first, otherwise one stable fallback
    /// derived from the keycode. Identical input always yields the identical buffer.
    public func resolvedBuffer(for code: Int) -> AVAudioPCMBuffer? {
        if let exact = buffers[code] { return exact }
        guard !buffers.isEmpty else { return nil }
        let codes = buffers.keys.sorted()
        return buffers[codes[Int(bitPattern: UInt(bitPattern: code)) % codes.count]]
    }

    public func play(packCode: Int, gain: Float, at when: AVAudioTime? = nil) {
        guard let buf = resolvedBuffer(for: packCode) else { return }
        let i: Int
        if let idx = voiceForKey[packCode] { i = idx }
        else { i = next; next = (next + 1) % voices.count; voiceForKey[packCode] = i }
        let v = voices[i]
        v.stop()
        v.volume = min(max(gain, 0), 1)
        v.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
        v.play()
    }

    /// Schedule a keyDown sample at an explicit host-clock time. The caller supplies the
    /// capture clock's host time for the keyDown event; no latency is added here.
    public func play(keyCode: Int, gain: Float, hostTime: UInt64) {
        play(packCode: keyCode, gain: gain, at: AVAudioTime(hostTime: hostTime))
    }

    // MARK: CC0 recorded library with variation

    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        result.frameLength = AVAudioFrameCount(samples.count)
        if let channel = result.floatChannelData {
            for (i, value) in samples.enumerated() { channel[0][i] = value }
        }
        return result
    }

    /// Load the prepared CC0 library. Missing files degrade to silence; no
    /// oscillator or procedural sound is ever generated.
    public func loadCC0Library(_ library: KeySoundLibrary = KeySoundLibraryCache.shared) {
        for keyClass in KeyClass.allCases where keyClass != .click {
            cc0Down[keyClass] = library.takes(keyClass, .down).compactMap { buffer($0.samples) }
            cc0Up[keyClass] = library.takes(keyClass, .up).compactMap { buffer($0.samples) }
        }
        recordedLibrary = library
        router = KeyVariationRouter()
        usingCC0 = true
    }

    /// Play a recorded take with round-robin + bounded pitch/gain variation.
    public func playVaried(keyCode: Int, phase: KeyPhase, gain: Float = 1,
                           hostTime: UInt64? = nil) {
        guard usingCC0 else { return }
        let keyClass = KeyClass.forCode(keyCode)
        let takes = phase == .down ? cc0Down[keyClass] ?? [] : cc0Up[keyClass] ?? []
        guard let variation = router.next(keyClass, phase: phase, key: keyCode, variantCount: takes.count),
              takes.indices.contains(variation.variant) else { return }
        schedule(takes[variation.variant], gain: gain, variation: variation, hostTime: hostTime)
    }

    public func playClick(tone: ClickSound = .fresh, gain: Float = 1, hostTime: UInt64? = nil) {
        guard usingCC0, let take = recordedLibrary.clickTake(tone),
              let pcm = buffer(take.samples) else { return }
        schedule(pcm, gain: gain,
                 variation: KeyVariation(variant: 0, pitchCents: 0, gainDb: 0),
                 hostTime: hostTime)
    }

    private func schedule(_ source: AVAudioPCMBuffer, gain: Float, variation: KeyVariation,
                          hostTime: UInt64?) {
        var chosen = source
        if abs(variation.pitchCents) > 0.5 {
            guard let channel = source.floatChannelData else { return }
            let pcm = Array(UnsafeBufferPointer(start: channel[0], count: Int(source.frameLength)))
            let shifted = pitchShift(pcm, cents: variation.pitchCents)
            guard let converted = buffer(shifted) else { return }
            chosen = converted
        }
        let i = next; next = (next + 1) % voices.count
        let v = voices[i]
        let jitter = Float(pow(10, variation.gainDb / 20))
        v.stop()
        v.volume = min(max(gain * jitter, 0), 1)
        let when = hostTime.map { AVAudioTime(hostTime: $0) }
        v.scheduleBuffer(chosen, at: when, options: [], completionHandler: nil)
        v.play()
    }

    public func start() { if !engine.isRunning { try? engine.start() } }
    public func stop() { engine.stop() }
}
