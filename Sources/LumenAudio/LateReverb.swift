import Foundation

public enum LateReverb {
    public static func process(_ samples: [Float], amount: Double, rt60: Double = 0.5) -> [Float] {
        let strength = amount.isFinite ? min(max(amount, 0), 1) : 0
        let size = 1024, hop = 256, bins = size / 2 + 1
        guard strength > 0, samples.count > size * 2 else { return samples }
        let fft = Radix2FFT(n: size)
        let window = (0..<size).map { Float(sin(.pi * Double($0) / Double(size))) }
        let padded = [Float](repeating: 0, count: size) + samples + [Float](repeating: 0, count: size)
        var output = [Float](repeating: 0, count: padded.count)
        var normalization = output
        var real = [Float](repeating: 0, count: size), imaginary = real
        var previousPower = [Float](repeating: 0, count: bins)
        var tail = previousPower
        var gain = [Float](repeating: 1, count: bins)
        let decay = Float(pow(10, -6 * Double(hop) / AudioIO.fs / max(rt60, 0.15)))
        for start in stride(from: 0, through: padded.count - size, by: hop) {
            for i in 0..<size { real[i] = padded[start + i] * window[i]; imaginary[i] = 0 }
            fft.transform(&real, &imaginary)
            for k in 0..<bins {
                let power = real[k] * real[k] + imaginary[k] * imaginary[k]
                tail[k] = max(tail[k] * decay, previousPower[k] * decay)
                // Only suppress decaying bins. Fresh attacks and sustained speech pass unchanged.
                let decaying = power < previousPower[k] * 0.98
                let target: Float = decaying
                    ? sqrt(max(0.16, 1 - Float(strength) * 0.75 * tail[k] / max(power, 1e-12))) : 1
                gain[k] += (target - gain[k]) * (target > gain[k] ? 0.8 : 0.25)
                previousPower[k] = power
                real[k] *= gain[k]; imaginary[k] *= gain[k]
                if k > 0 && k < size / 2 { real[size - k] = real[k]; imaginary[size - k] = -imaginary[k] }
            }
            fft.transform(&imaginary, &real)
            for i in 0..<size {
                output[start + i] += real[i] / Float(size) * window[i]
                normalization[start + i] += window[i] * window[i]
            }
        }
        return samples.indices.map { i in
            let position = i + size
            return output[position] / max(normalization[position], 1e-8)
        }
    }
}
