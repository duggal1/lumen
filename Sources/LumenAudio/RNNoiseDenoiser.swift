import Foundation
import CRNNoise

public struct DenoisedVoice: Sendable {
    public let samples: [Float]
    public let voiceProbability: [Float]
    public let frameSize: Int
}

public struct RNNoiseDenoiser: Denoiser {
    public let strength: Double
    public init(strength: Double = 1) {
        self.strength = strength.isFinite ? min(max(strength, 0), 1) : 1
    }

    // The vendored engine lazily initializes shared FFT tables on its first frame.
    private static let initialized: Void = {
        guard let state = rnnoise_create(nil) else { return }
        defer { rnnoise_destroy(state) }
        var input = [Float](repeating: 0, count: Int(rnnoise_get_frame_size()))
        var output = input
        _ = rnnoise_process_frame(state, &output, &input)
    }()

    static let latencySamples = 480

    public func process(_ x: [Float]) -> [Float] { analyze(x).samples }

    public func analyze(_ x: [Float]) -> DenoisedVoice {
        let size = Int(rnnoise_get_frame_size())
        guard !x.isEmpty, strength > 0 else {
            return DenoisedVoice(samples: x, voiceProbability: [], frameSize: size)
        }
        _ = Self.initialized
        guard let state = rnnoise_create(nil) else {
            return DenoisedVoice(samples: x, voiceProbability: [], frameSize: size)
        }
        defer { rnnoise_destroy(state) }
        let frames = (x.count + size - 1) / size
        var result = [Float](repeating: 0, count: x.count)
        var probabilities = [Float](repeating: 0, count: frames)
        var input = [Float](repeating: 0, count: size), output = input
        // Flush one full extra frame to recover the actual final samples.
        for frame in 0...frames {
            for k in 0..<size {
                let i = frame * size + k
                input[k] = i < x.count && x[i].isFinite ? x[i] * 32768 : 0
            }
            let probability = rnnoise_process_frame(state, &output, &input)
            if frame < frames { probabilities[frame] = min(max(probability, 0), 1) }
            guard frame > 0 else { continue }
            let start = (frame - 1) * size
            for k in 0..<min(size, x.count - start) { result[start + k] = output[k] / 32768 }
        }
        let attack = Float(exp(-1 / (0.005 * AudioIO.fs)))
        let release = Float(exp(-1 / (0.080 * AudioIO.fs)))
        let wet = Float(strength)
        let floor = Float(pow(10, -18 * strength / 20))
        var gain: Float = 1
        for i in result.indices {
            let probability = probabilities[i / size]
            let speech = min(max((probability - 0.10) / 0.60, 0), 1)
            let target = floor + (1 - floor) * speech * speech * (3 - 2 * speech)
            let coefficient = target > gain ? attack : release
            gain = target + coefficient * (gain - target)
            let dry = x[i].isFinite ? x[i] : 0
            result[i] = (dry * (1 - wet) + result[i] * wet) * gain
        }
        return DenoisedVoice(samples: result, voiceProbability: probabilities, frameSize: size)
    }
}

public let defaultDenoiser: any Denoiser = RNNoiseDenoiser()
