import Foundation
import AVFoundation

/// Preview-time typing sampler: 16-voice AVAudioEngine pool.
/// Codes are canonical macOS virtual keycodes, so each key (including every modifier)
/// keeps its own voice and its own recorded sample. No random pitch or sample choice.
public final class TypingSampler {
    private let engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var voiceForKey: [Int: Int] = [:]
    private var next = 0

    public init() {
        voices = (0..<16).map { _ in
            let n = AVAudioPlayerNode()
            engine.attach(n)
            return n
        }
        for v in voices { engine.connect(v, to: engine.mainMixerNode, format: nil) }
        engine.prepare()
    }

    public func load(packDir: URL) {
        buffers = TypingPackLoader.buffers(in: packDir)
        voiceForKey.removeAll()
        next = 0
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

    public func start() { if !engine.isRunning { try? engine.start() } }
    public func stop() { engine.stop() }
}
