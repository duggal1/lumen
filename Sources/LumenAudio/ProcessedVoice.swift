import Foundation
import AVFoundation
import CryptoKit
import LumenCore
import LumenProject

public enum CleanVoiceError: Error { case missingMicrophone }

struct ProcessedVoiceCache {
    /// Bump whenever the processing semantics change: every persisted voice
    /// and mix cache below is keyed by it, so an algorithm change can never
    /// be served a result produced by the old one.
    static let revision = "voice-v13-cancellable-df3"
    /// Full-program mix cache. Keyed by revision + exact settings + time map.
    static let mixRevision = "mix-v1"

    private struct Settings: Encodable {
        let noiseStrength: Double
        let engine: String
        let declickDepth: Double
        let dereverb: Double

        init(_ plan: AudioPlan, hasKeys: Bool) {
            noiseStrength = plan.micClean ? (plan.noiseReductionStrength.isFinite ? clamp(plan.noiseReductionStrength, 0, 1) : 1) : 0
            engine = noiseStrength > 0 && DeepFilterNet.isAvailable ? "df3" : "off"
            declickDepth = plan.declick && hasKeys ? plan.declickDepthDb : 0
            dereverb = plan.dereverb.isFinite ? clamp(plan.dereverb, 0, 1) : 0
        }
    }

    /// The sample count is part of the identity: a 3 s read-ahead render and a
    /// full-program render of the same file must never share a cache slot.
    static func key(samples: [Float], plan: AudioPlan, keyTimes: [Double]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256()
        hash.update(data: Data(revision.utf8))
        withUnsafeBytes(of: samples.count) { hash.update(bufferPointer: $0) }
        samples.withUnsafeBytes { hash.update(bufferPointer: $0) }
        keyTimes.withUnsafeBytes { hash.update(bufferPointer: $0) }
        hash.update(data: try encoder.encode(Settings(plan, hasKeys: !keyTimes.isEmpty)))
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

    /// Apply noise reduction, then the separately configured keyboard declick.
    /// `cancelled` is polled between DSP chunks so an obsolete job (a seek, a
    /// newer edit, a closed editor) stops consuming CPU instead of running to
    /// the end of a 30-minute file. A cancelled render returns empty: the
    /// caller must treat that as "no result", never as silence.
    @discardableResult
    static func render(_ samples: [Float], plan: AudioPlan, keyTimes: [Double],
                       denoiser: (any Denoiser)? = nil,
                       cancelled: (@Sendable () -> Bool)? = nil) -> [Float] {
        let stopped: () -> Bool = { cancelled?() == true }
        let strength = plan.noiseReductionStrength.isFinite ? clamp(plan.noiseReductionStrength, 0, 1) : 1
        var voice = samples.map { $0.isFinite ? $0 : 0 }
        guard !stopped() else { return [] }

        if plan.micClean, strength > 0 {
            let engine = denoiser ?? TrainedVoiceDenoiser(strength: strength)
            let processed = engine.process(voice)
            // The neural engine is one subprocess call and cannot be interrupted
            // mid-run; the cancellation check keeps a cancelled job from paying
            // for any further stage (declick, dereverb) on top of it.
            if stopped() { return [] }
            voice = processed
        }

        if plan.declick, !keyTimes.isEmpty {
            voice = Declick.process(voice, keyTimes: keyTimes, vad: VAD.regions(voice), depthDb: plan.declickDepthDb)
            if stopped() { return [] }
        }
        let echo = plan.dereverb.isFinite ? clamp(plan.dereverb, 0, 1) : 0
        if echo > 0, voice.count > 16_384 {
            var wpe = WPE()
            wpe.taps = 4
            wpe.iterations = 1
            wpe.maxHz = 4_000
            let reduced = wpe.process(voice)
            if reduced.count == voice.count {
                let amount = Float(echo * 0.3)
                // Chunked so a long file can be abandoned between chunks.
                let chunk = 1 << 16
                var out = voice
                var i = 0
                while i < voice.count {
                    if stopped() { return [] }
                    let end = min(i + chunk, voice.count)
                    for k in i..<end {
                        out[k] = reduced[k].isFinite ? voice[k] + (reduced[k] - voice[k]) * amount : voice[k]
                    }
                    i = end
                }
                voice = out
            }
        }
        return stopped() ? [] : voice
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
        let origin = file.meta.clock.originHostSeconds
        let offset = (file.meta.mic?.startHostSeconds ?? origin) - origin
        let keyTimes = plan.declick ? ((try? project.events(origin: origin)) ?? [])
            .filter { $0.kind == .keyDown }.map { $0.t - offset }.filter { $0 >= 0 } : []
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
            let rendered = ProcessedVoiceCache.render(samples, plan: plan, keyTimes: keyTimes)
            try Task.checkCancellation()
            guard !rendered.isEmpty else { throw CancellationError() }
            try ProcessedVoiceCache.write(rendered, rate: AudioIO.fs, to: voiceURL)
            voice = rendered
        }
        let transcription = try AudioIO.resampleMono(voice, from: AudioIO.fs, to: 16_000)
        try Task.checkCancellation()
        try ProcessedVoiceCache.write(transcription, rate: 16_000, to: captionURL)
        return captionURL
    }
    return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
}