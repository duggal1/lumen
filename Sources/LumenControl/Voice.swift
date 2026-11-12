import Foundation
import Security
import LumenCore

/// A text-to-speech provider. The ElevenLabs implementation keeps the key in
/// the Keychain, caches by hash and always discloses that it made a network
/// call. Offline-first: an agent can always bring its own audio instead.
public protocol VoiceProvider: Sendable {
    /// Generates speech. Returns the audio bytes and a human description of
    /// what was sent over the network.
    func generate(text: String, voice: String, model: String) async throws -> (data: Data, disclosure: String)
}

public enum VoiceError: Error, Sendable {
    case noKey
    case failed(String)

    public var message: String {
        switch self {
        case .noKey:
            return "No voice-over provider key is stored. Store one in the Keychain (service: com.lumen.studio, account: elevenlabs) or import an audio file with audio_import."
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
        let key = hash(text + voiceID + modelID)
        if let cacheDirectory {
            let cached = cacheDirectory.appendingPathComponent("voice-" + key + ".mp3")
            if let data = try? Data(contentsOf: cached) {
                return (data, "Read cached narration for voice \(voiceID) (no network call).")
            }
        }
        // The current ElevenLabs text-to-speech endpoint. The output format
        // is explicit so the cached file always matches what we asked for.
        var request = URLRequest(url: URL(string: endpoint + "/" + voiceID + "?output_format=mp3_44100_128")!)
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
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoiceError.failed("HTTP \(http.statusCode): \(body.prefix(200))")
        }
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let cached = cacheDirectory.appendingPathComponent("voice-" + key + ".mp3")
            try? data.write(to: cached)
        }
        return (data, "Sent \(text.count) characters to ElevenLabs (voice \(voiceID), model \(modelID)).")
    }

    private func hash(_ text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { h ^= UInt64(byte); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
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
