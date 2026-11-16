import Foundation
import LumenCore

/// Bounded Wiener suppression when the trained denoiser is unavailable.
/// Offline, mono 48 kHz; overlap-add preserves sample count and timing.
public struct SpectralGate: Denoiser {
    private let strength: Double
    public init(strength: Double = 1) {
        self.strength = strength.isFinite ? clamp(strength, 0, 1) : 0
    }

    public func process(_ x: [Float]) -> [Float] {
        let size = 1024, hop = 256, bins = size / 2 + 1
        guard strength > 0, x.count >= size * 2 else { return x }
        let fft = Radix2FFT(n: size)
        let window = (0..<size).map { Float(sin(.pi * Double($0) / Double(size))) }
        var real = [Float](repeating: 0, count: size), imaginary = real
        var profile = [[Float]](repeating: [], count: bins)
        let frames = min((x.count - size) / hop + 1, 256)
        for frame in 0..<frames {
            let start = frame * (x.count - size) / max(frames - 1, 1)
            for i in 0..<size { real[i] = x[start + i] * window[i]; imaginary[i] = 0 }
            fft.transform(&real, &imaginary)
            for k in 0..<bins { profile[k].append(real[k] * real[k] + imaginary[k] * imaginary[k]) }
        }
        // A purely relative Wiener estimate converges on any stationary sound:
        // its noise profile becomes the signal and it gates sustained speech,
        // notes and hums regardless of how loud they are. Cap the estimate at a
        // small absolute floor so a strong stationary component is treated as
        // signal, while bins that are quieter than the floor are still gated.
        let gatePower = Float(size * size) * 1e-7
        let noise = profile.map { values -> Float in
            let sorted = values.sorted()
            return min(max(sorted[sorted.count / 5], 1e-12), gatePower)
        }
        let padded = [Float](repeating: 0, count: size) + x + [Float](repeating: 0, count: size)
        var output = [Float](repeating: 0, count: padded.count), normalization = output
        var gain = [Float](repeating: 1, count: bins), priorPower = [Float](repeating: 0, count: bins)
        var target = gain
        let floor = Float(pow(10, -18 * strength / 20))
        for start in stride(from: 0, through: padded.count - size, by: hop) {
            for i in 0..<size { real[i] = padded[start + i] * window[i]; imaginary[i] = 0 }
            fft.transform(&real, &imaginary)
            for k in 0..<bins {
                let power = real[k] * real[k] + imaginary[k] * imaginary[k]
                let posterior = power / noise[k]
                let prior = 0.96 * priorPower[k] / noise[k] + 0.04 * max(posterior - 1, 0)
                let wiener = prior / (1 + prior)
                target[k] = max(floor, 1 - Float(strength) * (1 - wiener))
                priorPower[k] = power * gain[k] * gain[k]
            }
            for k in 0..<bins {
                let smooth = (target[max(k - 1, 0)] + 2 * target[k] + target[min(k + 1, bins - 1)]) / 4
                gain[k] += (smooth - gain[k]) * (smooth > gain[k] ? 0.6 : 0.15)
                real[k] *= gain[k]; imaginary[k] *= gain[k]
                if k > 0 && k < size / 2 { real[size - k] = real[k]; imaginary[size - k] = -imaginary[k] }
            }
            fft.transform(&imaginary, &real)
            for i in 0..<size {
                output[start + i] += real[i] / Float(size) * window[i]
                normalization[start + i] += window[i] * window[i]
            }
        }
        return x.indices.map { output[$0 + size] / max(normalization[$0 + size], 1e-8) }
    }
}
