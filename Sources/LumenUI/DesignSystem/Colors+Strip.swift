import SwiftUI

/// Timeline ink. Signal orange only (DESIGN.md §1.3): every lane reads from
/// the Ramp, never a second hue and never a hex literal outside DesignSystem.
enum StripInk {
    // Audio: body [3], tip [4].
    static var hot: Color { Ramp.orange[3] }
    static var hotDeep: Color { Ramp.orange[4] }

    // Zoom: quiet [2], selected [3].
    static var zoom: Color { Ramp.orange[2] }
    static var zoomDeep: Color { Ramp.orange[3] }

    // Clicks: tip [4].
    static var click: Color { Ramp.orange[4] }
    static var clickDeep: Color { Ramp.orange[4] }

    // Clips: quiet [2], selected [3]; imported: dust [1], selected [2].
    static var clip: Color { Ramp.orange[2] }
    static var clipDeep: Color { Ramp.orange[3] }
    static var importInk: Color { Ramp.orange[1] }
    static var importDeep: Color { Ramp.orange[2] }

    // Idle / neutral marks: pressed surface, hover dust.
    static var cell: Color { Tok.controlPressed }
    static var cellHover: Color { Ramp.orange[1] }
}

/// Music identity. The whole music lane is one hue — violet — so it never
/// reads as a second recording accent. Mood sleeves in the picker each carry
/// their own muted hue at equal weight; none of them is the signal orange.
enum MusicInk {
    static var lane: Color { Tok.selection }
    static var laneDeep: Color { Color(light: 0x6D28D9, dark: 0x8B5CF6) }
    static var laneHover: Color { Color(light: 0x8B5CF6, dark: 0xA78BFA) }
    static func mood(_ category: String) -> Color {
        switch category.lowercased() {
        case "calm":       return Color(light: 0x2F9E8F, dark: 0x4FD1C5)
        case "upbeat":     return Color(light: 0xC98A00, dark: 0xF5C518)
        case "epic":       return Color(light: 0x7C3AED, dark: 0xA78BFA)
        case "futuristic": return Color(light: 0x2F6FE0, dark: 0x60A5FA)
        case "tension":    return Color(light: 0xD6455A, dark: 0xFB7185)
        default:           return Tok.control
        }
    }
}
