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

    public static var root: URL? {
        guard let directory = BundledAudioAssets.root?.appendingPathComponent("typing", isDirectory: true),
              FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return directory
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

    /// macOS virtual keycodes mapped to PS/2 set-1 codes used by Mechvibes.
    /// Packs may define a subset; the mixer uses the first available key for others.
    public static let macToPack: [Int: Int] = [
        0:30, 1:31, 2:32, 3:33, 4:35, 5:34, 6:44, 7:45, 8:46, 9:47, 11:48, 12:16, 13:17, 14:18, 15:19,
        16:21, 17:20, 31:24, 32:22, 34:23, 35:25, 37:38, 38:36, 40:37, 45:49, 46:50,
        18:2, 19:3, 20:4, 21:5, 23:6, 22:7, 26:8, 28:9, 25:10, 29:11,
        27:12, 24:13, 33:26, 30:27, 41:39, 39:40, 50:41, 42:43, 43:51, 47:52, 44:53,
        36:28, 48:15, 49:57, 51:14, 53:1, 56:42, 60:54, 57:58, 59:29, 62:29, 58:56, 61:56,
    ]
}
