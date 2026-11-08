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

    public static func availablePacks() -> [URL] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/TypingPacks", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.filter { $0.pathExtension.isEmpty && FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// PS/2 scancode (Mechvibes) -> macOS virtual keycode (CGEvent).
    /// Unknown macOS keys fall back to generic.
    public static let macToPack: [Int: Int] = [
        0: 30,   // kVK_ANSI_A -> 30
        1: 48,   // S
        2: 46,   // D
        3: 32,   // F
        4: 18,   // H
        5: 35,   // G
        6: 33,   // Z
        7: 34,   // X
        8: 31,   // C
        9: 49,   // V
        11: 19,  // B
        12: 37,  // Q
        13: 20,  // W
        14: 26,  // E
        15: 24,  // R
        16: 227, // Y (227 is PS/2 Y)
        17: 21,  // T
        49: 57,  // Space
        36: 28,  // Return
        51: 14,  // Delete (Backspace)
        48: 15,  // Tab
        56: 42,  // Shift (left)
        60: 42,  // Shift (right)
        15: 57,  // Enter (numpad Enter -> Space fallback)
    ]
    public static let genericCode = 30
}
