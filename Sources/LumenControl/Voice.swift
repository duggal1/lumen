import Foundation
import Security
import CryptoKit
@preconcurrency import AVFoundation
import LumenCore

/// A text-to-speech provider. The ElevenLabs implementation keeps the key in
/// the Keychain, caches by hash and always discloses that it made a network
/// call. Offline-first: an agent can always bring its own audio instead.
public protocol VoiceProvider: Sendable {
    /// Generates speech. Returns the audio bytes and a human description of
    /// what was sent over the network.
    func generate(text: String, voice: String, model: String) async throws -> (data: Data, disclosure: String)
}

public enum VoiceError: LocalizedError, Sendable {
    case noKey
    case failed(String)

    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .noKey:
            return "No voice-over provider key is stored. Store one in the Keychain (service: com.lumen.studio, account: elevenlabs) or import an audio file with audio_edit_v2."
        case .failed(let m):
            return "The voice provider failed: \(m)"
        }
    }
}

/// Keychain access. Keys are never written to disk or to the audit log.
public enum Keychain {
    public static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public static func write(_ value: String, service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }
}

/// ElevenLabs text-to-speech.
public struct ElevenLabsProvider: VoiceProvider {
    public static let defaultModel = "eleven_multilingual_v2"
    public static let defaultVoice = "21m00Tcm4TlvDq8ikWAM"   // Rachel
    public static let keychainService = "com.lumen.studio"
    public static let keychainAccount = "elevenlabs"

    public let apiKey: String?
    public let endpoint: String
    public let cacheDirectory: URL?

    public init(apiKey: String? = nil, endpoint: String = "https://api.elevenlabs.io/v1/text-to-speech",
                cacheDirectory: URL? = nil) {
        self.apiKey = apiKey ?? Keychain.read(service: Self.keychainService, account: Self.keychainAccount)
        self.endpoint = endpoint
        self.cacheDirectory = cacheDirectory
    }

    public func generate(text: String, voice: String, model: String) async throws -> (data: Data, disclosure: String) {
        guard let apiKey, !apiKey.isEmpty else { throw VoiceError.noKey }
        let voiceID = voice.isEmpty ? Self.defaultVoice : voice
        let modelID = model.isEmpty ? Self.defaultModel : model
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 40_000 else { throw VoiceError.failed("Narration must contain 1–40,000 UTF-8 bytes.") }
        guard voiceID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              modelID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw VoiceError.failed("Invalid voice or model identifier.") }
        let key = SHA256.hash(data: try JSONEncoder().encode([text, voiceID, modelID])).map { String(format: "%02x", $0) }.joined()
        if let cacheDirectory {
            let cached = cacheDirectory.appendingPathComponent("voice-" + key + ".mp3")
            if let data = try? Data(contentsOf: cached), !data.isEmpty {
                return (data, "Read cached narration for voice \(voiceID) (no network call).")
            }
        }
        // The current ElevenLabs text-to-speech endpoint. The output format
        // is explicit so the cached file always matches what we asked for.
        guard let url = URL(string: endpoint + "/" + voiceID + "?output_format=mp3_44100_128"), url.scheme == "https" else { throw VoiceError.failed("Invalid HTTPS provider endpoint.") }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": modelID,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.75],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VoiceError.failed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Check the key, quota and voice.")
        }
        guard !data.isEmpty, data.count <= 64 * 1024 * 1024,
              http.mimeType?.hasPrefix("audio/") == true else { throw VoiceError.failed("Provider returned invalid audio.") }
        try Task.checkCancellation()
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let cached = cacheDirectory.appendingPathComponent("voice-" + key + ".mp3")
            try? data.write(to: cached, options: .atomic)
        }
        return (data, "Sent \(text.count) characters to ElevenLabs (voice \(voiceID), model \(modelID)).")
    }

}

/// The provider the tools use.
public struct DefaultVoiceProvider: VoiceProvider {
    let inner: ElevenLabsProvider
    public init(cacheDirectory: URL?) {
        inner = ElevenLabsProvider(cacheDirectory: cacheDirectory)
    }
    public func generate(text: String, voice: String, model: String) async throws -> (data: Data, disclosure: String) {
        try await inner.generate(text: text, voice: voice, model: model)
    }
}

/// Generated narration is project-owned media, never a disposable derived cache.
public enum NarrationAsset {
    public static func generate(in project: URL, text: String, voice: String = "", model: String = "",
                                provider: any VoiceProvider) async throws -> (url: URL, duration: Double, disclosure: String) {
        let result = try await provider.generate(text: text, voice: voice, model: model)
        try Task.checkCancellation()
        let directory = project.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("narration-" + UUID().uuidString + ".mp3")
        do {
            try result.data.write(to: url, options: .atomic)
            let audio = try AVAudioFile(forReading: url)
            let sampleRate = audio.processingFormat.sampleRate
            guard sampleRate.isFinite, sampleRate > 0, audio.length > 0,
                  let probe = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                               frameCapacity: AVAudioFrameCount(min(audio.length, 4096))) else {
                throw VoiceError.failed("Generated audio cannot be decoded.")
            }
            try audio.read(into: probe)
            guard probe.frameLength > 0 else { throw VoiceError.failed("Generated audio cannot be decoded.") }
            let duration = Double(audio.length) / sampleRate
            try Task.checkCancellation()
            return (url, duration, result.disclosure)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
