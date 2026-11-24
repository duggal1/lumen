import Foundation
import LumenCore

/// Where the Cmd-key pill sits inside the exported frame. `bottomMiddle` is the
/// default: it stays clear of the typing-focus crop and the caption rail.
public enum ShortcutPillPosition: String, Codable, CaseIterable, Sendable {
    case topMiddle
    case bottomMiddle
}

/// Project-level setting for the shortcut pill. Missing keys decode to defaults
/// so older projects are unchanged.
public struct ShortcutOverlayPlan: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var position: ShortcutPillPosition = .bottomMiddle
    /// Seconds a shortcut stays on screen after its key-down.
    public var holdSeconds: Double = 1.1
    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, position, holdSeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? enabled
        position = (try? c.decodeIfPresent(ShortcutPillPosition.self, forKey: .position)) ?? position
        holdSeconds = (try? c.decodeIfPresent(Double.self, forKey: .holdSeconds)) ?? holdSeconds
    }
}

/// One resolved shortcut, in OUTPUT timeline seconds. `start` is the key-down
/// timestamp and `end` is when its fade-out completes; a replacement shortens
/// `end` of the outgoing pill without moving its `start`.
public struct ShortcutDisplay: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var keyCode: UInt16
    public init(start: Double, end: Double, text: String, keyCode: UInt16) {
        self.start = start; self.end = end; self.text = text; self.keyCode = keyCode
    }
}

/// Turns recorded key events into displayable shortcut pills.
///
/// `InputEvent.flags` carries the high 16 bits of `NSEvent.ModifierFlags`, so
/// Command is 0x0010, Shift 0x0002, Option 0x0008 and Control 0x0004. The
/// detector only fires on a key-down with Command held; modifier-only
/// `flagsChanged` events are deliberately ignored (they would render "⌘" alone).
public enum ShortcutDetector {
    public static let commandFlag: UInt16 = 0x0010
    public static let shiftFlag: UInt16 = 0x0002
    public static let optionFlag: UInt16 = 0x0008
    public static let controlFlag: UInt16 = 0x0004

    /// Pure function: identical events and settings always yield identical pills.
    /// At most `maxStack` pills overlap; a new shortcut replaces the oldest live
    /// one, which is what fast consecutive ⌘K, ⌘B feels like.
    public static func displays(in events: [InputEvent], plan: ShortcutOverlayPlan,
                                maxStack: Int = 2) -> [ShortcutDisplay] {
        guard plan.enabled, plan.holdSeconds > 0 else { return [] }
        let ordered = events.filter { $0.kind == .keyDown && $0.flags & commandFlag != 0 }
            .sorted { $0.t < $1.t }
        var out: [ShortcutDisplay] = []
        for event in ordered {
            // Replacement: every pill still on screen ends exactly at the new
            // key-down. The outgoing pose therefore fades out from that frame
            // while the incoming pill springs in, with no pile-up and no
            // stale pill lingering behind a newer shortcut.
            for index in out.indices where out[index].end > event.t {
                out[index].end = event.t
            }
            out.append(ShortcutDisplay(start: event.t, end: event.t + plan.holdSeconds,
                                       text: modifierPrefix(event.flags) + glyphString(for: event.keyCode),
                                       keyCode: event.keyCode))
        }
        // Retain enough history for the renderer's crossfade; older entries are
        // already fully faded because their `end` was cut above.
        let retain = max(1, maxStack) + 1
        if out.count > retain { out.removeFirst(out.count - retain) }
        return out
    }

    /// The order macOS uses in menus: ⌃⌥⇧⌘. Command is added by `displays`.
    public static func modifierPrefix(_ flags: UInt16) -> String {
        var s = ""
        if flags & controlFlag != 0 { s += "⌃" }
        if flags & optionFlag != 0 { s += "⌥" }
        if flags & shiftFlag != 0 { s += "⇧" }
        return s + (flags & commandFlag != 0 ? "⌘" : "")
    }

    /// Crisp, single-glyph labels for every key a shortcut can use.
    public static func glyphString(for code: UInt16) -> String {
        if let letter = letter(for: code) { return letter }
        switch Int(code) {
        // macOS virtual keycodes for the number row are not in numeric order.
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 33: return "["
        case 36, 76: return "↩"
        case 39: return "\""
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "⎋"
        case 115: return "↖"
        case 116: return "⇞"
        case 117: return "⌦"
        case 119: return "↘"
        case 121: return "⇟"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let functions: [UInt16: Int] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6,
                                            98: 7, 100: 8, 101: 9, 102: 10, 103: 11, 104: 12]
            if let f = functions[code] { return "F\(f)" }
            return "?"
        }
    }

    /// macOS virtual keycode -> uppercase letter. Kept as a table (not a
    /// character conversion) because keycodes are hardware positions.
    public static func letter(for code: UInt16) -> String? {
        let table: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
            9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        ]
        return table[code]
    }
}
