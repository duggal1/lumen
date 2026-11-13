import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

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

    public init(mode: InputMode = .physical, tag: Int64 = Int64.random(in: 1_000_000...9_000_000)) {
        self.mode = mode
        self.tag = tag
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    // MARK: Mouse

    /// Moves the cursor along a minimum-jerk path. Absolute deadlines, so the
    /// path never drifts with the frame rate.
    public func moveCursor(to target: CGPoint, ms: Int) async throws {
        let hz = 120.0
        let n = max(Int(Double(ms) / 1000 * hz), 2)
        let start = Self.currentMouseLocation()
        let clock = ContinuousClock()
        let t0 = clock.now
        for i in 1...n {
            try gate?.assertFrontmost()
            let u = Double(i) / Double(n)
            let s = u * u * u * (10 + u * (-15 + 6 * u))   // minimum jerk
            let p = CGPoint(x: start.x + (target.x - start.x) * s,
                            y: start.y + (target.y - start.y) * s)
            postMouse(type: .mouseMoved, at: p, button: .left, clickState: 0)
            try await clock.sleep(until: t0.advanced(by: .seconds(Double(i) / hz)))
        }
    }

    /// A click: down, a short hold, up.
    ///
    /// AGENT: `Thread.sleep` blocked the whole runner actor, so nothing else
    /// could observe the run or cancel it during the hold.
    public func click(at point: CGPoint, holdMs: Int = 60) async throws {
        try gate?.assertFrontmost()
        postMouse(type: .leftMouseDown, at: point, button: .left, clickState: 1)
        try await Task.sleep(for: .milliseconds(max(holdMs, 0)))
        postMouse(type: .leftMouseUp, at: point, button: .left, clickState: 1)
    }

    public func scroll(at point: CGPoint, dy: Double) throws {
        try gate?.assertFrontmost()
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(dy), wheel2: 0, wheel3: 0) else { return }
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
        let t0 = clock.now
        var index = 0
        for character in text {
            try gate?.assertFrontmost()
            let key = Self.virtualKey(for: character)
            let delay = perChar * Self.jitter(for: index)
            try await clock.sleep(until: t0.advanced(by: .seconds(perChar * Double(index))))
            if let key {
                postKey(code: key.code, down: true, unicode: String(character), shift: key.shift)
                postKey(code: key.code, down: false, unicode: String(character), shift: key.shift)
            } else {
                postUnicode(String(character), down: true)
                postUnicode(String(character), down: false)
            }
            index += 1
            _ = delay
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
        if let code = Self.namedKey(name) {
            postKey(code: code, down: true, unicode: nil, shift: flags.contains(.maskShift), flags: flags)
            postKey(code: code, down: false, unicode: nil, shift: flags.contains(.maskShift), flags: flags)
        }
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
    static func virtualKey(for character: Character) -> Key? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7A:  // a-z
            return Key(code: CGKeyCode(ascii - 0x61), shift: false)
        case 0x41...0x5A:  // A-Z
            return Key(code: CGKeyCode(ascii - 0x41), shift: true)
        case 0x31...0x39:  // 1-9
            return Key(code: CGKeyCode(ascii - 0x31 + 17), shift: false)
        case 0x30:         // 0
            return Key(code: 29, shift: false)
        case 0x20: return Key(code: 49, shift: false)   // space
        case 0x2D: return Key(code: 27, shift: false)   // -
        case 0x3D: return Key(code: 24, shift: false)   // =
        case 0x5B: return Key(code: 33, shift: false)   // [
        case 0x5D: return Key(code: 30, shift: false)   // ]
        case 0x3B: return Key(code: 38, shift: false)   // ;
        case 0x27: return Key(code: 39, shift: false)   // '
        case 0x2C: return Key(code: 43, shift: false)   // ,
        case 0x2E: return Key(code: 47, shift: false)   // .
        case 0x2F: return Key(code: 44, shift: false)   // /
        case 0x5C: return Key(code: 42, shift: false)   // backslash
        case 0x60: return Key(code: 50, shift: false)   // `
        case 0x21: return Key(code: 24, shift: true)    // !
        case 0x3F: return Key(code: 27, shift: true)    // ?
        default: return nil
        }
    }

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

    /// Human-like jitter between keystrokes: 60...140 ms.
    static func jitter(for index: Int) -> Double {
        let pattern: [Double] = [1.0, 0.82, 1.18, 0.94, 1.26, 0.88, 1.08, 0.96]
        return pattern[index % pattern.count]
    }
}
