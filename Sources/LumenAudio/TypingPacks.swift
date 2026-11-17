import Foundation
import AVFoundation
import Accelerate

// Mechvibes pack loader. Two config generations are understood:
//  * v2 (current upstream): definition_method "single", audio_file, definitions keyed by
//    W3C KeyboardEvent.code names, each with `timing = [[downStart, downEnd], [upStart, upEnd]]`.
//  * v1 (legacy bundled packs): key_define_type "single"/"multi", sound, defines keyed by
//    uiohook/PS-2 scancode with [startMs, durMs] slices or one file per key.
// Every key is decoded into its own buffer at load; nothing is decoded at playback time.
// The canonical sample key is the macOS virtual keycode, so every key — including Command,
// Shift, Option and Control — resolves to its OWN recorded sample with an exact lookup.

public struct KeyPack: Decodable {
    public let id: String?
    public let name: String?
    public let author: String?
    public let attribution: String?
    // v1
    public let key_define_type: String?
    public let sound: String?
    public let defines: [String: Define?]
    // v2
    public let definition_method: String?
    public let audio_file: String?
    public let definitions: [String: KeyDefinition?]

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

    /// One key in a v2 Mechvibes config. `timing[0]` is the key-DOWN window and
    /// `timing[1]` is the key-UP window. keyDown is synchronised to the down onset.
    public struct KeyDefinition: Decodable {
        public let timing: [[Double]]

        /// Exact slice of the source recording that belongs to keyDown.
        public var downSlice: (start: Double, duration: Double)? {
            guard let t = timing.first, t.count == 2, t[1] > t[0] else { return nil }
            return (t[0], t[1] - t[0])
        }
    }

    public var isV2: Bool { definitions.isEmpty == false && (audio_file != nil || definition_method != nil) }

    private enum CodingKeys: String, CodingKey {
        case id, name, author, attribution
        case key_define_type, sound, defines
        case definition_method, audio_file, definitions
    }

    /// v1 and v2 configs share no required keys, so both dictionaries default empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        attribution = try c.decodeIfPresent(String.self, forKey: .attribution)
        key_define_type = try c.decodeIfPresent(String.self, forKey: .key_define_type)
        sound = try c.decodeIfPresent(String.self, forKey: .sound)
        defines = try c.decodeIfPresent([String: Define?].self, forKey: .defines) ?? [:]
        definition_method = try c.decodeIfPresent(String.self, forKey: .definition_method)
        audio_file = try c.decodeIfPresent(String.self, forKey: .audio_file)
        definitions = try c.decodeIfPresent([String: KeyDefinition?].self, forKey: .definitions) ?? [:]
    }
}

public func sliceBuffer(_ file: AVAudioFile, startMs: Double, durMs: Double) throws -> AVAudioPCMBuffer? {
    let sr = file.processingFormat.sampleRate
    guard sr.isFinite, sr > 0 else { return nil }
    let start = AVAudioFramePosition(max(0, startMs / 1000 * sr))
    let available = max(0, file.length - start)
    let requested = AVAudioFrameCount(max(0, durMs / 1000 * sr))
    let frames = min(requested, AVAudioFrameCount(available))
    guard frames > 0 else { return nil }
    guard let out = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
    file.framePosition = start
    try file.read(into: out, frameCount: frames)
    return out.frameLength > 0 ? out : nil
}

public enum TypingPackLoader {
    /// The single deterministic default. A missing requested pack resolves to this id,
    /// never to a random or filesystem-order-dependent choice.
    public static let defaultPackID = "mechvibes-default"

    /// Resolve a requested pack id deterministically. If it is not present on disk the
    /// one bundled default is returned; repeated calls with the same input are identical.
    public static func resolvedPackID(for requested: String) -> String {
        if let dir = dir(for: requested), dir.lastPathComponent == requested { return requested }
        return dir(for: defaultPackID) != nil ? defaultPackID : requested
    }

    public static func buffers(in packDir: URL) -> [Int: AVAudioPCMBuffer] {
        let cfgURL = packDir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: cfgURL),
              let pack = try? JSONDecoder().decode(KeyPack.self, from: data) else { return [:] }
        if pack.isV2 { return v2Buffers(pack, in: packDir) }
        return v1Buffers(pack, in: packDir)
    }

    private static func v2Buffers(_ pack: KeyPack, in packDir: URL) -> [Int: AVAudioPCMBuffer] {
        guard let name = pack.audio_file else { return [:] }
        guard let f = try? AVAudioFile(forReading: packDir.appendingPathComponent(name)) else { return [:] }
        var out: [Int: AVAudioPCMBuffer] = [:]
        for (keyName, value) in pack.definitions {
            guard let def = value, let slice = def.downSlice, let mac = mechvibesToMac[keyName] else { continue }
            if let buf = try? sliceBuffer(f, startMs: slice.start, durMs: slice.duration) { out[mac] = buf }
        }
        // Fn (mac 63) has no W3C code upstream. Give it a real recorded modifier sound
        // rather than silence or an arbitrary fallback sample.
        if let command = out[55] { out[63] = command }
        return out
    }

    private static func v1Buffers(_ pack: KeyPack, in packDir: URL) -> [Int: AVAudioPCMBuffer] {
        var out: [Int: AVAudioPCMBuffer] = [:]
        // Canonical keys are macOS keycodes; v1 defines uiohook codes. Invert the legacy
        // table deterministically (lowest mac code wins) so exact lookup still works.
        let uiohookToMac = macToUiohook.keys.sorted().reduce(into: [Int: Int]()) { result, mac in
            guard let code = macToUiohook[mac] else { return }
            if result[code] == nil { result[code] = mac }
        }
        let type = pack.key_define_type ?? "single"
        if type == "multi" {
            for (codeStr, def) in pack.defines {
                guard let code = Int(codeStr), case .file(let name) = def else { continue }
                let url = packDir.appendingPathComponent(name)
                guard let f = try? AVAudioFile(forReading: url),
                      let buf = try? AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                      (try? f.read(into: buf, frameCount: AVAudioFrameCount(f.length))) != nil else { continue }
                out[uiohookToMac[code] ?? code] = buf
            }
        } else {
            guard let sound = pack.sound else { return [:] }
            let url = packDir.appendingPathComponent(sound)
            guard let f = try? AVAudioFile(forReading: url) else { return [:] }
            for (codeStr, def) in pack.defines {
                guard let code = Int(codeStr), case .slice(let s, let d) = def else { continue }
                if let buf = try? sliceBuffer(f, startMs: s, durMs: d) { out[uiohookToMac[code] ?? code] = buf }
            }
        }
        return out
    }

    /// Where typing packs live. The packaged app keeps them in `Contents/Resources/Audio/typing`;
    /// a source checkout keeps them in `App/public/assets/typing`. The current working
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
        let fallback = root.appendingPathComponent(defaultPackID, isDirectory: true)
        return FileManager.default.fileExists(atPath: fallback.appendingPathComponent("config.json").path) ? fallback : nil
    }

    public static func availablePacks() -> [URL] {
        guard let root,
              let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// macOS virtual keycode -> W3C `KeyboardEvent.code` used by current Mechvibes packs.
    /// Covers letters, digits, punctuation, navigation, function keys, keypad AND every
    /// modifier: Command (MetaLeft/Right), Shift, Option (AltLeft/Right) and Control.
    public static let macToMechvibes: [Int: String] = [
        // Letters
        0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH", 5: "KeyG", 6: "KeyZ",
        7: "KeyX", 8: "KeyC", 9: "KeyV", 11: "KeyB", 12: "KeyQ", 13: "KeyW", 14: "KeyE",
        15: "KeyR", 16: "KeyY", 17: "KeyT", 31: "KeyO", 32: "KeyU", 34: "KeyI", 35: "KeyP",
        37: "KeyL", 38: "KeyJ", 40: "KeyK", 45: "KeyN", 46: "KeyM",
        // Number row and punctuation
        18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 22: "Digit6", 23: "Digit5",
        24: "Equal", 25: "Digit9", 26: "Digit7", 27: "Minus", 28: "Digit8", 29: "Digit0",
        30: "BracketRight", 33: "BracketLeft", 39: "Quote", 41: "Semicolon", 42: "Backslash",
        43: "Comma", 44: "Slash", 47: "Period", 50: "Backquote",
        // Whitespace, editing, escape
        36: "Enter", 48: "Tab", 49: "Space", 51: "Backspace", 53: "Escape",
        // Modifiers — each has its own recorded sample in the bundled pack.
        54: "MetaRight", 55: "MetaLeft", 56: "ShiftLeft", 57: "CapsLock", 58: "AltLeft",
        59: "ControlLeft", 60: "ShiftRight", 61: "AltRight", 62: "ControlRight",
        // Navigation
        115: "Home", 116: "PageUp", 117: "Delete", 119: "End", 121: "PageDown",
        123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
        // Function row
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 102: "F10",
        103: "F11", 104: "F12", 120: "F2", 122: "F1",
        // Keypad
        65: "NumpadDecimal", 67: "NumpadMultiply", 69: "NumpadAdd", 71: "NumLock",
        75: "NumpadDivide", 76: "NumpadEnter", 78: "NumpadSubtract",
        82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4",
        87: "Numpad5", 88: "Numpad6", 89: "Numpad7", 90: "Numpad8", 91: "Numpad9",
    ]

    public static let mechvibesToMac: [String: Int] = {
        var out: [String: Int] = [:]
        for (mac, name) in macToMechvibes.sorted(by: { $0.key < $1.key }) { out[name] = mac }
        return out
    }()

    /// Legacy scancode table kept for old project data and `macToPack` compatibility.
    /// New code uses `packCode(for:definedIn:)`, whose canonical code is the mac keycode.
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

    /// Codes the original bundled `mechvibes-default` pack defined (kept for legacy tests).
    public static let defaultPackCodes: Set<Int> = [14, 15, 28, 30, 36, 42, 57]

    public static let macToPack: [Int: Int] = macToUiohook.filter { defaultPackCodes.contains($0.value) }

    /// Canonical pack code for a macOS keycode. When the pack defines the key the code is
    /// the keycode itself, giving every key — modifiers included — its own exact sample.
    /// `nil` means the pack has no sample; callers use one deterministic fallback, never silence.
    public static func packCode(for macKeyCode: Int, definedIn codes: Set<Int>) -> Int? {
        guard codes.contains(macKeyCode) else { return nil }
        return macKeyCode
    }
}
