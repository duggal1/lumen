import Foundation
import Darwin
import os

public enum DeepFilterNetError: Error {
    case unavailable, timedOut, failed(Int32), invalidOutput
}

public enum DeepFilterNet {
    public static var isAvailable: Bool {
        #if arch(arm64)
        return executable != nil
        #else
        return false
        #endif
    }

    /// env override → app bundle → SwiftPM resource → source checkout.
    static var executable: URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["LUMEN_DEEPFILTER"] {
            candidates.append(URL(fileURLWithPath: path))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("DeepFilterNet/deep-filter"))
            candidates.append(resources.appendingPathComponent("deep-filter"))
        }
        if let module = Bundle.module.url(forResource: "deep-filter", withExtension: nil, subdirectory: "DeepFilterNet") {
            candidates.append(module)
        }
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(checkout.appendingPathComponent("Vendor/deepfilternet/deep-filter"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    public static func process(_ samples: [Float]) throws -> [Float] {
        try process(samples, strength: 1)
    }

    /// `strength` 0…1 maps to an attenuation limit of 14…40 dB.
    public static func process(_ samples: [Float], strength: Double) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard isAvailable, let executable else { throw DeepFilterNetError.unavailable }
        let s = min(max(strength.isFinite ? strength : 1, 0), 1)
        let atten = 14 + 26 * s

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("voice.wav")
        let output = directory.appendingPathComponent("output")
        // Pinned DF3: 480-sample STFT delay + two 480-sample lookahead frames.
        // Its CLI trims the delay but does not flush or process partial frames.
        let padding = 1440 + (480 - samples.count % 480) % 480
        try AudioIO.writeMonoWAV(samples, paddingSamples: padding, to: input)

        let tuned = ["--compensate-delay", "--atten-lim-db", String(Int(atten.rounded())),
                     "--output-dir", output.path, input.path]
        let compatible = ["--compensate-delay", "--output-dir", output.path, input.path]

        let timeout = max(10, min(600, Double(samples.count) / AudioIO.fs * 0.75 + 5))
        var status = try run(executable, tuned, timeout: timeout)
        if status != 0 {
            try? FileManager.default.removeItem(at: output)
            status = try run(executable, compatible, timeout: timeout)
        }
        guard status == 0 else { throw DeepFilterNetError.failed(status) }

        let (channels, rate) = try AudioIO.decode(output.appendingPathComponent("voice.wav"))
        guard rate == AudioIO.fs, channels.count == 1, let voice = channels.first,
              voice.count >= samples.count, voice.count - samples.count < 480,
              voice.allSatisfy(\.isFinite) else { throw DeepFilterNetError.invalidOutput }
        return Array(voice.prefix(samples.count))
    }

    private static func run(_ executable: URL, _ arguments: [String], timeout: Double) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 2)
            }
            throw DeepFilterNetError.timedOut
        }
        return process.terminationStatus
    }
}

/// One DeepFilterNet3 pass, with bounded spectral suppression on failure.
struct TrainedVoiceDenoiser: Denoiser {
    let strength: Double

    init(strength: Double) { self.strength = strength }

    func process(_ x: [Float]) -> [Float] {
        guard DeepFilterNet.isAvailable else {
            Logger(subsystem: "com.lumen.studio", category: "audio")
                .error("DeepFilterNet unavailable; using spectral noise reduction")
            return SpectralGate(strength: strength).process(x)
        }
        do { return try DeepFilterNet.process(x, strength: strength) }
        catch {
            Logger(subsystem: "com.lumen.studio", category: "audio")
                .error("DeepFilterNet failed; using spectral noise reduction: \(String(describing: error), privacy: .public)")
            return SpectralGate(strength: strength).process(x)
        }
    }
}

public let defaultDenoiser: any Denoiser = TrainedVoiceDenoiser(strength: 1)
