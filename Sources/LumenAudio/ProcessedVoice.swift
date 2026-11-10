import Foundation
import AVFoundation
import CryptoKit
import Accelerate
import LumenCore
import LumenProject

public enum CleanVoiceError: Error { case missingMicrophone }

struct ProcessedVoiceCache {
    static let revision = "trained-voice-v3-rnnoise-df056"

    static func key(samples: [Float], plan: AudioPlan, keyTimes: [Double]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256()
        hash.update(data: Data(revision.utf8))
        samples.withUnsafeBytes { hash.update(bufferPointer: $0) }
        keyTimes.withUnsafeBytes { hash.update(bufferPointer: $0) }
        hash.update(data: try encoder.encode(plan))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ url: URL, count: Int, rate: Double) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == rate,
              file.length == count,
              let decoded = try? AudioIO.decode(url), let samples = decoded.channels.first,
              samples.count == count, samples.allSatisfy(\.isFinite) else { return nil }
        return samples
    }

    static func write(_ samples: [Float], rate: Double, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try AudioIO.writeMonoWAV(samples, sampleRate: rate, to: temporary)
        try Data(contentsOf: temporary).write(to: url, options: .atomic)
    }

    static func render(_ samples: [Float], plan: AudioPlan, keyTimes: [Double],
                       denoiser: (any Denoiser)? = nil) -> [Float] {
        let strength = plan.noiseReductionStrength.isFinite ? clamp(plan.noiseReductionStrength, 0, 1) : 1
        var voice = samples.map { $0.isFinite ? $0 : 0 }
        if plan.micClean, strength > 0 {
            let engine = denoiser ?? TrainedVoiceDenoiser(strength: strength, highQuality: plan.studioMode == .optimized)
            voice = engine.process(voice)
        }
        let regions = VAD.regions(voice)
        voice = LateReverb.process(voice, amount: plan.dereverb,
                                  rt60: RoomEstimate.rt60(voice, vad: regions))
        if plan.declick, !keyTimes.isEmpty {
            voice = Declick.process(voice, keyTimes: keyTimes, vad: regions, depthDb: plan.declickDepthDb)
        }
        voice = VoiceStudio.finish(voice, vad: regions, plan: plan, denoiser: nil)
        let loudness = Loudness.integrated([voice])
        if loudness > -69 {
            voice = vDSP.multiply(Float(pow(10, clamp(-16 - loudness, -24, 24) / 20)), voice)
        }
        var channels = [voice]
        Limiter.apply(&channels, ceiling: Float(pow(10, -1.5 / 20)))
        let peak = Loudness.truePeakDb(channels)
        if peak > -1 {
            channels[0] = vDSP.multiply(Float(pow(10, (-1.05 - peak) / 20)), channels[0])
        }
        return channels[0]
    }
}

/// Source-file time, mono 16 kHz Float32 WAV. Add the recorded mic offset to word timestamps.
/// Passing the current audio settings includes unsaved editor changes in the cache key.
public func cleanVoiceURL(for project: ProjectBundle, settings: AudioPlan? = nil) async throws -> URL {
    let job = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        let file = try project.load()
        guard file.meta.mic != nil else { throw CleanVoiceError.missingMicrophone }
        let samples = try AudioIO.readMono(project.micURL)
        guard !samples.isEmpty else { throw CleanVoiceError.missingMicrophone }
        var plan = settings ?? file.timeline.audio
        // Muting playback does not remove the voice source used for transcription.
        if plan.micMode == .off { plan.micMode = .standard }
        plan.micClean = true
        if plan.noiseReductionStrength <= 0 { plan.noiseReductionStrength = 1 }
        let keyTimes = plan.declick ? ((try? project.events(origin: file.meta.mic?.startHostSeconds ?? 0)) ?? [])
            .filter { $0.kind == .keyDown }.map(\.t) : []
        let key = try ProcessedVoiceCache.key(samples: samples, plan: plan, keyTimes: keyTimes)
        let voiceURL = project.cacheURL.appendingPathComponent("voice-\(key)-48000.wav")
        let captionURL = project.cacheURL.appendingPathComponent("voice-\(key)-16000.wav")
        let count = Int((Double(samples.count) / 3).rounded())
        if ProcessedVoiceCache.read(captionURL, count: count, rate: 16_000) != nil { return captionURL }
        try Task.checkCancellation()
        let voice: [Float]
        if let cached = ProcessedVoiceCache.read(voiceURL, count: samples.count, rate: AudioIO.fs) {
            voice = cached
        } else {
            voice = ProcessedVoiceCache.render(samples, plan: plan, keyTimes: keyTimes)
            try Task.checkCancellation()
            try ProcessedVoiceCache.write(voice, rate: AudioIO.fs, to: voiceURL)
        }
        let transcription = try AudioIO.resampleMono(voice, from: AudioIO.fs, to: 16_000)
        try Task.checkCancellation()
        try ProcessedVoiceCache.write(transcription, rate: 16_000, to: captionURL)
        return captionURL
    }
    return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
}
