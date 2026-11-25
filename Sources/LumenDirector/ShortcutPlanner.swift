import Foundation
import LumenCore
import LumenProject

/// Chords are metadata about an action, not a transcription of keyboard input.
/// Ordinary typing and unknown/secure focused fields are excluded.
enum ShortcutPlanner {
    private static let keys: [UInt16: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
        11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2",
        20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"−", 28:"8",
        29:"0", 30:"]", 31:"O", 32:"U", 33:"[", 34:"I", 35:"P", 36:"↩",
        37:"L", 38:"J", 39:"'", 40:"K", 41:";", 42:"\\", 43:",", 44:"/",
        45:"N", 46:"M", 47:".", 48:"⇥", 49:"Space", 50:"`", 51:"⌫", 53:"⎋",
        76:"↩", 96:"F5", 97:"F6", 98:"F7", 99:"F3", 100:"F8", 101:"F9",
        103:"F11", 109:"F10", 111:"F12", 115:"↖", 116:"⇞", 117:"⌦", 118:"F4",
        119:"↘", 120:"F2", 121:"⇟", 122:"F1", 123:"←", 124:"→", 125:"↓", 126:"↑"
    ]

    static func plan(events: [InputEvent], ax: [AXFrame], tm: TimeMap) -> [ShortcutCue] {
        var cues: [ShortcutCue] = []
        var down = Set<UInt16>()
        for e in events.sorted(by: { $0.t < $1.t }) {
            if e.kind == .keyUp { down.remove(e.keyCode); continue }
            guard e.kind == .keyDown, down.insert(e.keyCode).inserted,
                  e.t.isFinite, e.t >= tm.trimStart, e.t < tm.trimEnd, !tm.isCut(e.t),
                  e.flags & 0x14 != 0, let key = keys[e.keyCode] else { continue }
            // AX indices are one-based. No verified context means no label.
            guard e.axFrameIndex > 0, Int(e.axFrameIndex) <= ax.count else { continue }
            let context = ax[Int(e.axFrameIndex) - 1]
            guard context.anchor?.resolved == true, !context.secure else { continue }
            var parts: [String] = []
            if e.flags & 0x04 != 0 { parts.append("⌃") }
            if e.flags & 0x08 != 0 { parts.append("⌥") }
            if e.flags & 0x02 != 0 { parts.append("⇧") }
            if e.flags & 0x10 != 0 { parts.append("⌘") }
            parts.append(key)
            let start = tm.output(atSource: e.t)
            let end = min(start + 4, tm.outputDuration)
            guard end > start else { continue }
            if let last = cues.last, start < last.end {
                cues[cues.count - 1].end = start
            }
            cues.append(ShortcutCue(start: start, end: end, label: parts.joined(separator: "  ")))
        }
        return cues.filter { $0.end > $0.start }
    }
}
