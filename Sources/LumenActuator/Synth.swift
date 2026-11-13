import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import os

/// How the actuator drives the machine.
public enum InputMode: String, Sendable, Codable, CaseIterable {
    /// Real CGEvents. Best fidelity, hover states work — but it takes over the
    /// user's mouse and keyboard. Run it on a dedicated display or a spare Mac.
    case physical
    /// Accessibility actions plus a synthesized cursor. No hijack, but no
    /// hover states and some controls will not respond.
    case virtual
}

/// Refuses to send events when the frontmost app is not one the human approved.
///
/// AGENT: checking only the declared target let a stray frontmost app receive
/// the whole script, so the gate is evaluated before every event batch.
public struct ActuationGate: Sendable {
    public let allowed: Set<String>

    public init(allowed: Set<String>) {
        self.allowed = allowed
    }

    public func assertFrontmost() throws {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard allowed.contains(id) else {
            throw ActuatorError.failed(
                "Frontmost app \(id.isEmpty ? "(unknown)" : id) is not on the allow-list; run halted.")
        }
    }
}

/// Builds mouse and keyboard events.
///
/// Lumen records the event stream and rebuilds the cursor from it, so the
/// actuator must emit DENSE events: mouse moves at 120 Hz along an eased
/// path, not one jump. Every event it posts carries a tag, so the runner can
/// tell "this was us" from "a human moved the mouse".
public final class InputSynthesizer: @unchecked Sendable {
    public let mode: InputMode
    /// Marks our own events so a human takeover is detectable.
    public let tag: Int64
    private let source: CGEventSource?
    /// AGENT: every event batch re-checks that the frontmost app is still approved.
    public var gate: ActuationGate?
    // AGENT: track synthesized pointer positions so the watchdog can distinguish its own motion.
    private let posted = OSAllocatedUnfairLock<CGPoint?>(initialState: nil)
    public var lastPosted: CGPoint? { posted.withLock { $0 } }
    public var checkpoint: (@Sendable () throws -> Void)?

    public init(mode: InputMode = .physical, tag: Int64 = Int64.random(in: 1_000_000...9_000_000)) {
        self.mode = mode
        self.tag = tag
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    // MARK: Mouse

    /// Moves the cursor along a minimum-jerk path. Absolute deadlines, so the
    /// path never drifts with the frame rate.
    public func moveCursor(to target: CGPoint, ms: Int, dragging: Bool = false) async throws {
        let hz = 120.0
        let n = max(Int(Double(ms) / 1000 * hz), 2)
        let start = Self.currentMouseLocation()
        let clock = ContinuousClock()
        let t0 = clock.now
        for i in 1...n {
            try checkpoint?()
            try gate?.assertFrontmost()
            let u = Double(i) / Double(n)
            let s = u * u * u * (10 + u * (-15 + 6 * u))   // minimum jerk
            let p = CGPoint(x: start.x + (target.x - start.x) * s,
                            y: start.y + (target.y - start.y) * s)
            // AGENT: dragging must send dragged events so the target sees the held button.
            postMouse(type: dragging ? .leftMouseDragged : .mouseMoved, at: p, button: .left, clickState: dragging ? 1 : 0)
            try await clock.sleep(until: t0.advanced(by: .seconds(Double(i) / hz)))
        }
    }

    /// A click: down, a short hold, up.
    ///
    /// AGENT: `Thread.sleep` blocked the whole runner actor, so nothing else
    /// could observe the run or cancel it during the hold.
    public func click(at point: CGPoint, button: String? = nil, count: Int = 1,
                      holdMs: Int = 60) async throws {
        try gate?.assertFrontmost()
        // AGENT: only left clicks existed, so context menus and selections were unreachable.
        let right = button?.lowercased() == "right"
        let cgButton: CGMouseButton = right ? .right : .left
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let clicks = max(count, 1)
        for i in 1...clicks {
            postMouse(type: down, at: point, button: cgButton, clickState: Int64(i))
            // AGENT: cancellation during a hold must release the mouse button.
            do { try await Task.sleep(for: .milliseconds(max(holdMs, 0))) }
            catch { postMouse(type: up, at: point, button: cgButton, clickState: Int64(i)); throw error }
            postMouse(type: up, at: point, button: cgButton, clickState: Int64(i))
            if i < clicks { try await Task.sleep(for: .milliseconds(60)) }
        }
    }

    /// Presses, moves and releases: selection, sliders, drag and drop.
    ///
    /// AGENT: a script could not drag anything, which rules out most editors.
    public func drag(from start: CGPoint, to end: CGPoint, ms: Int) async throws {
        try gate?.assertFrontmost()
        try await moveCursor(to: start, ms: max(ms / 3, 50))
        postMouse(type: .leftMouseDown, at: start, button: .left, clickState: 1)
        // AGENT: release at the last posted position if a drag is interrupted.
        do { try await moveCursor(to: end, ms: max(ms, 50), dragging: true) }
        catch { postMouse(type: .leftMouseUp, at: lastPosted ?? start, button: .left, clickState: 1); throw error }
        postMouse(type: .leftMouseUp, at: end, button: .left, clickState: 1)
    }

    public func scroll(at point: CGPoint, dy: Double) throws {
        try checkpoint?()
        try gate?.assertFrontmost()
        // AGENT: place the wheel event over the requested target before scrolling.
        postMouse(type: .mouseMoved, at: point, button: .left, clickState: 0)
        // AGENT: dy is in lines, but it was posted as 3 pixels of wheel travel,
        // which is invisible. Line units match what a trackpad sends.
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                                  wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        event.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    /// Types text with real virtual key codes (so Lumen's typing bursts and
    /// key sounds work) and the unicode string as a fallback for characters
    /// the layout cannot produce.
    public func type(_ text: String, cps: Double) async throws {
        let perChar = 1.0 / max(cps, 1)
        let clock = ContinuousClock()
        var next = clock.now
        var index = 0
        for character in text {
            try checkpoint?()
            try gate?.assertFrontmost()
            let key = Self.virtualKey(for: character)
            // AGENT: jitter was computed and thrown away, so every keystroke
            // landed on a perfectly even grid. It now shapes the interval.
            next = next.advanced(by: .seconds(perChar * Self.jitter(for: index)))
            try await clock.sleep(until: next)
            try checkpoint?()
            try gate?.assertFrontmost()
            if let key {
                postKey(code: key.code, down: true, unicode: String(character), shift: key.shift)
                postKey(code: key.code, down: false, unicode: String(character), shift: key.shift)
            } else {
                postUnicode(String(character), down: true)
                postUnicode(String(character), down: false)
            }
            index += 1
        }
    }

    /// Pastes text in one shot, then restores the clipboard.
    ///
    /// AGENT: key-by-key typing is slow and drops characters when the target
    /// app is busy; long strings now go through the clipboard instead.
    public func paste(_ text: String) async throws {
        try gate?.assertFrontmost()
        let board = NSPasteboard.general
        // AGENT: the human's clipboard is theirs; put it back afterwards.
        let saved = board.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
        board.clearContents()
        board.setString(text, forType: .string)
        postKey(code: 9, down: true, unicode: nil, shift: false, flags: .maskCommand)
        postKey(code: 9, down: false, unicode: nil, shift: false, flags: .maskCommand)
        try await Task.sleep(for: .milliseconds(120))
        board.clearContents()
        if let saved, !saved.isEmpty {
            let items = saved.map { copy -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in copy { item.setData(data, forType: type) }
                return item
            }
            board.writeObjects(items)
        }
    }

    /// Presses a named key with optional modifiers.
    public func press(key name: String, modifiers: [String]) throws {
        try gate?.assertFrontmost()
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            default: break
            }
        }
        // AGENT: unknown keys must fail visibly and single-character shortcuts need ANSI key codes.
        let code = Self.namedKey(name) ?? (name.count == 1 ? name.first.flatMap { Self.virtualKey(for: $0)?.code } : nil)
        guard let code else { throw ActuatorError.failed("Unknown key ‘\(name)’. Use a character or a supported named key.") }
        postKey(code: code, down: true, unicode: nil, shift: flags.contains(.maskShift), flags: flags)
        postKey(code: code, down: false, unicode: nil, shift: flags.contains(.maskShift), flags: flags)
    }

    /// The kill switch: Escape always works, even mid-run.
    public func emergencyStop() {
        postKey(code: 53, down: true, unicode: nil, shift: false)
        postKey(code: 53, down: false, unicode: nil, shift: false)
    }

    // MARK: Posting

    private func postMouse(type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int64) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        posted.withLock { $0 = point }
        event.post(tap: .cghidEventTap)
    }

    private func postKey(code: CGKeyCode, down: Bool, unicode: String?, shift: Bool, flags: CGEventFlags = []) {
        var eventFlags = flags
        if shift { eventFlags.insert(.maskShift) }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        event.flags = eventFlags
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        if let unicode, !unicode.isEmpty {
            var utf16 = Array(unicode.utf16)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        }
        event.post(tap: .cghidEventTap)
    }

    private func postUnicode(_ text: String, down: Bool) {
        var utf16 = Array(text.utf16)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return }
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        event.post(tap: .cghidEventTap)
    }

    public static func currentMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: Key mapping

    struct Key { let code: CGKeyCode, shift: Bool }

    /// ANSI virtual key codes for the characters an agent types.
    ///
    /// AGENT: letters were mapped to `ascii - 0x61`, which is not the ANSI
    /// layout (a=0 but s=1, d=2, c=8 …), so typing produced gibberish.
    static func virtualKey(for character: Character) -> Key? {
        guard let ascii = character.asciiValue else { return nil }
        let lower = ascii >= 0x41 && ascii <= 0x5A ? ascii + 0x20 : ascii
        if let code = letterCodes[lower] {
            return Key(code: code, shift: ascii != lower)
        }
        switch ascii {
        // AGENT: ANSI digit key codes are not consecutive.
        case 0x31...0x39:
            return Key(code: [18, 19, 20, 21, 23, 22, 26, 28, 25][Int(ascii - 0x31)], shift: false)
        case 0x30:         // 0
            return Key(code: 29, shift: false)
        case 0x20: return Key(code: 49, shift: false)   // space
        case 0x2D: return Key(code: 27, shift: false)   // -
        case 0x3D: return Key(code: 24, shift: false)   // =
        case 0x5B: return Key(code: 33, shift: false)   // [
        case 0x5D: return Key(code: 30, shift: false)   // ]
        case 0x3B: return Key(code: 41, shift: false)   // ;
        case 0x27: return Key(code: 39, shift: false)   // '
        case 0x2C: return Key(code: 43, shift: false)   // ,
        case 0x2E: return Key(code: 47, shift: false)   // .
        case 0x2F: return Key(code: 44, shift: false)   // /
        case 0x5C: return Key(code: 42, shift: false)   // backslash
        case 0x60: return Key(code: 50, shift: false)   // `
        // AGENT: shifted symbols were missing, so `@`, `:`, `_` and friends
        // fell back to a bare unicode event the layout often swallows.
        case 0x21: return Key(code: 18, shift: true)    // !
        case 0x40: return Key(code: 19, shift: true)    // @
        case 0x23: return Key(code: 20, shift: true)    // #
        case 0x24: return Key(code: 21, shift: true)    // $
        case 0x25: return Key(code: 23, shift: true)    // %
        case 0x5E: return Key(code: 22, shift: true)    // ^
        case 0x26: return Key(code: 26, shift: true)    // &
        case 0x2A: return Key(code: 28, shift: true)    // *
        case 0x28: return Key(code: 25, shift: true)    // (
        case 0x29: return Key(code: 29, shift: true)    // )
        case 0x5F: return Key(code: 27, shift: true)    // _
        case 0x2B: return Key(code: 24, shift: true)    // +
        case 0x7B: return Key(code: 33, shift: true)    // {
        case 0x7D: return Key(code: 30, shift: true)    // }
        case 0x7C: return Key(code: 42, shift: true)    // |
        case 0x3A: return Key(code: 41, shift: true)    // :
        case 0x22: return Key(code: 39, shift: true)    // "
        case 0x3C: return Key(code: 43, shift: true)    // <
        case 0x3E: return Key(code: 47, shift: true)    // >
        case 0x3F: return Key(code: 44, shift: true)    // ?
        case 0x7E: return Key(code: 50, shift: true)    // ~
        default: return nil
        }
    }

    /// Lowercase ASCII letter to ANSI key code, the real Apple layout.
    static let letterCodes: [UInt8: CGKeyCode] = [
        0x61: 0, 0x73: 1, 0x64: 2, 0x66: 3, 0x68: 4, 0x67: 5, 0x7A: 6, 0x78: 7,
        0x63: 8, 0x76: 9, 0x62: 11, 0x71: 12, 0x77: 13, 0x65: 14, 0x72: 15,
        0x79: 16, 0x74: 17, 0x6F: 31, 0x75: 32, 0x69: 34, 0x70: 35, 0x6C: 37,
        0x6A: 38, 0x6B: 40, 0x6E: 45, 0x6D: 46,
    ]

    static func namedKey(_ name: String) -> CGKeyCode? {
        switch name.lowercased() {
        case "return", "enter": return 36
        case "tab": return 48
        case "space": return 49
        case "delete", "backspace": return 51
        case "escape", "esc": return 53
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        default: return nil
        }
    }

    /// Human-like jitter between keystrokes, as a multiplier of the base
    /// interval. A fixed pattern, not `random`, so a run is reproducible.
    static func jitter(for index: Int) -> Double {
        let pattern: [Double] = [1.0, 0.82, 1.18, 0.94, 1.26, 0.88, 1.08, 0.96]
        return pattern[index % pattern.count]
    }
}
