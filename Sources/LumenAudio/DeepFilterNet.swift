import Foundation
import Darwin
import os

public enum DeepFilterNetError: Error {
    case unavailable, timedOut, failed(Int32), invalidOutput
}

public enum DeepFilterNet {
    public static var isAvailable: Bool {
        #if arch(arm64)
        return executable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        #else
        return false
        #endif
    }

    private static var executable: URL? {
        Bundle.module.url(forResource: "deep-filter", withExtension: nil, subdirectory: "DeepFilterNet")
    }

    public static func process(_ samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard isAvailable, let executable else { throw DeepFilterNetError.unavailable }
        let started = ContinuousClock.now
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("voice.wav")
        let output = directory.appendingPathComponent("output")
        // Pinned DF3: 480-sample STFT delay + two 480-sample lookahead frames.
        // Its CLI trims the delay but does not flush or process partial frames.
        let padding = 1440 + (480 - samples.count % 480) % 480
        try AudioIO.writeMonoWAV(samples, paddingSamples: padding, to: input)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--compensate-delay", "--output-dir", output.path, input.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let timeout = max(10, min(300, Double(samples.count) / AudioIO.fs * 0.75 + 5))
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            throw DeepFilterNetError.timedOut
        }
        guard process.terminationStatus == 0 else { throw DeepFilterNetError.failed(process.terminationStatus) }
        let file = output.appendingPathComponent("voice.wav")
        let (channels, rate) = try AudioIO.decode(file)
        guard rate == AudioIO.fs, channels.count == 1, let voice = channels.first,
              voice.count >= samples.count, voice.count - samples.count < 480,
              voice.allSatisfy(\.isFinite) else { throw DeepFilterNetError.invalidOutput }
        guard started.duration(to: .now) < .seconds(Double(samples.count) / AudioIO.fs) else {
            throw DeepFilterNetError.timedOut
        }
        return Array(voice.prefix(samples.count))
    }
}

struct TrainedVoiceDenoiser: Denoiser {
    let strength: Double
    let highQuality: Bool

    func process(_ x: [Float]) -> [Float] {
        let neural = RNNoiseDenoiser(strength: strength).analyze(x)
        guard highQuality, strength > 0 else {
            let quiet = neural.voiceProbability.filter { $0 < 0.2 }
            guard !quiet.isEmpty else { return neural.samples }
            let residual = RNNoiseDenoiser(strength: strength).analyze(neural.samples)
            var output = neural.samples
            for i in output.indices {
                let probability = neural.voiceProbability[i / neural.frameSize]
                let wet = min(max((0.2 - probability) / 0.2, 0), 1)
                output[i] += (residual.samples[i] - output[i]) * wet
            }
            return output
        }
        do {
            let enhanced = try DeepFilterNet.process(x)
            // Reuse RNNoise's speech decisions without processing the enhanced voice twice.
            let size = neural.frameSize
            let floor = Float(pow(10, -(12 + 6 * min(max(strength, 0), 1)) / 20))
            let attack = Float(exp(-1 / (0.005 * AudioIO.fs)))
            let release = Float(exp(-1 / (0.080 * AudioIO.fs)))
            var output = enhanced, gain: Float = 1
            let wet = Float(strength)
            for i in output.indices {
                let p = neural.voiceProbability.isEmpty ? 1 : neural.voiceProbability[i / size]
                let speech = min(max((p - 0.10) / 0.60, 0), 1)
                let target = floor + (1 - floor) * speech * speech * (3 - 2 * speech)
                gain = target + (target > gain ? attack : release) * (gain - target)
                output[i] = (enhanced[i] * wet + x[i] * (1 - wet)) * gain
            }
            return output
        } catch {
            Logger(subsystem: "com.lumen.studio", category: "audio").error("DeepFilterNet failed; using RNNoise: \(String(describing: error), privacy: .public)")
            return neural.samples
        }
    }
}
