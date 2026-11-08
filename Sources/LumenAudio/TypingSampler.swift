import Foundation
import AVFoundation

/// Preview-time typing sampler: 16-voice AVAudioEngine pool.
/// Same key restarts its own voice. No random pitch/sample.
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
    }

    public func play(packCode: Int, gain: Float, at when: AVAudioTime? = nil) {
        guard let buf = buffers[packCode] else { return }
        let i: Int
        if let idx = voiceForKey[packCode] { i = idx }
        else { i = next; next = (next + 1) % voices.count; voiceForKey[packCode] = i }
        let v = voices[i]
        v.stop()
        v.volume = min(max(gain, 0), 1)
        v.scheduleBuffer(buf, at: when, options: [], completionHandler: nil)
        v.play()
    }

    public func start() { if !engine.isRunning { try? engine.start() } }
    public func stop() { engine.stop() }
}
