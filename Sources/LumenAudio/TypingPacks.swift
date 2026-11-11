import Foundation
import AVFoundation
import Accelerate

// Mechvibes pack loader: config.json + audio. Decodes and slices every key
// into its own AVAudioPCMBuffer at load. No decoding at playback time.
// Supports key_define_type "single" (slice from one file) and "multi"
// (one file per keycode), tolerant of null/missing keys.

public struct KeyPack: Decodable {
    public let key_define_type: String?
    public let sound: String?
    public let defines: [String: Define?]

    public enum Define: Decodable {
        case slice(startMs: Double, durMs: Double)
        case file(String)

        public init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let a = try? c.decode([Double].self), a.count == 2 {
                self = .slice(startMs: a[0], durMs: a[1])
            } else {
                self = .file(try c.decode(String.self))
            }
        }
    }
}

public func sliceBuffer(_ file: AVAudioFile, startMs: Double, durMs: Double) throws -> AVAudioPCMBuffer? {
    let sr = file.processingFormat.sampleRate
    let start = AVAudioFramePosition(startMs / 1000 * sr)
    let frames = AVAudioFrameCount(durMs / 1000 * sr)
    guard frames > 0 else { return nil }
    guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
    file.framePosition = start
    try file.read(into: out, frameCount: frames)
    return out
}

public enum TypingPackLoader {
    public static func buffers(in packDir: URL) -> [Int: AVAudioPCMBuffer] {
        let cfgURL = packDir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: cfgURL),
              let pack = try? JSONDecoder().decode(KeyPack.self, from: data) else { return [:] }
        var out: [Int: AVAudioPCMBuffer] = [:]
        let type = pack.key_define_type ?? "single"
        if type == "multi" {
            for (codeStr, def) in pack.defines {
                guard let code = Int(codeStr), case .file(let name) = def else { continue }
                let url = packDir.appendingPathComponent(name)
                guard let f = try? AVAudioFile(forReading: url),
                      let buf = try? AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                      (try? f.read(into: buf, frameCount: AVAudioFrameCount(f.length))) != nil else { continue }
                out[code] = buf
            }
        } else {
            guard let sound = pack.sound else { return [:] }
            let url = packDir.appendingPathComponent(sound)
            guard let f = try? AVAudioFile(forReading: url) else { return [:] }
            for (codeStr, def) in pack.defines {
                guard let code = Int(codeStr), case .slice(let s, let d) = def else { continue }
                if let buf = try? sliceBuffer(f, startMs: s, durMs: d) { out[code] = buf }
            }
        }
        return out
    }

    /// Where typing packs live.
    /// The packaged app keeps them in `Contents/Resources/Audio/typing`; a source
    /// checkout keeps them in `App/public/assets/typing`. The current working
    /// directory is never used: inside the app it is `/`.
    public static var root: URL? {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return [Bundle.main.resourceURL?.appendingPathComponent("Audio/typing"),
                checkout.appendingPathComponent("App/public/assets/typing")]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func dir(for id: String) -> URL? {
        guard let root else { return nil }
        let requested = root.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: requested.appendingPathComponent("config.json").path) { return requested }
        let fallback = root.appendingPathComponent("mechvibes-default", isDirectory: true)
        return FileManager.default.fileExists(atPath: fallback.appendingPathComponent("config.json").path) ? fallback : nil
    }

    public static func availablePacks() -> [URL] {
        guard let root,
              let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// macOS virtual keycodes (CGEvent `keyboardEventKeycode`) → uiohook / PS/2
    /// set-1 scancodes, which is the numbering Mechvibes packs define.
    /// J/K/L are 38/36/37 in uiohook (Carbon keys: J = 38, K = 40, L = 37).
    public static let macToUiohook: [Int: Int] = [
        // Letters
        0: 30, 1: 31, 2: 32, 3: 33, 4: 35, 5: 34, 6: 44, 7: 45, 8: 46, 9: 47,
        11: 48, 12: 16, 13: 17, 14: 18, 15: 19, 16: 21, 17: 20, 31: 24, 32: 22,
        34: 23, 35: 25, 37: 37, 38: 38, 40: 36, 45: 49, 46: 50,
        // Number row
        18: 2, 19: 3, 20: 4, 21: 5, 22: 7, 23: 6, 25: 10, 26: 8, 28: 9, 29: 11,
        // Punctuation
        24: 13, 27: 12, 30: 27, 33: 26, 39: 40, 41: 39, 42: 43, 43: 51, 44: 53,
        47: 52, 50: 41,
        // Controls
        36: 28, 48: 15, 49: 57, 51: 14, 53: 1, 56: 42, 57: 58, 58: 56, 60: 42,
        61: 56, 117: 29, 123: 80, 124: 79, 125: 81, 126: 82,
    ]

    /// Codes the shipped `mechvibes-default` pack defines (config.json `defines`):
    /// 14 backspace, 15 tab, 28 return, 30 A, 36 K, 42 shift, 57 space.
    public static let defaultPackCodes: Set<Int> = [14, 15, 28, 30, 36, 42, 57]

    /// macOS keycode → pack code, limited to the codes the pack actually defines.
    /// Keys the pack does not define are absent on purpose: the mixer falls back
    /// to the pack's first sample instead of a code that may not exist.
    public static let macToPack: [Int: Int] = macToUiohook.filter { defaultPackCodes.contains($0.value) }

    /// Pack code for a macOS keycode, but only when the loaded pack defines it.
    /// `nil` means "this pack has no sample for this key" — never a silent key.
    public static func packCode(for macKeyCode: Int, definedIn codes: Set<Int>) -> Int? {
        guard let code = macToUiohook[macKeyCode], codes.contains(code) else { return nil }
        return code
    }
}
