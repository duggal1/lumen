import SwiftUI

/// Dieother: the pixel-instrument palette the timeline already draws with,
/// reused as the right side's dieother theme language. Right-side chrome reads
/// from here, never a hex outside DesignSystem.
enum Dieother {
    /// Interface accent; timeline colors remain independent.
    static let accent = Tok.accent
    static let accentHover = Tok.accentHover
    static let accentText = Tok.accentText
    static let accentSoft = Tok.accentSoft

    /// The light blue supporting accent.
    static let voice = Color(light: 0x0067D5, dark: 0x46A4FF)
    static let voiceDeep = Color(light: 0x0057B8, dark: 0x1688FF)

    // Mood sleeves in the music picker, dieother hues from the instrument
    // palette where a closest match exists.
    static let yellow = Color(light: 0x0067D5, dark: 0xA7DFFF)
    static let violet = Color(light: 0x0067D5, dark: 0xA7DFFF)
    static let blue = Color(light: 0x0067D5, dark: 0x1688FF)
    static let pink = Color(light: 0x0067D5, dark: 0xA7DFFF)

    static func mood(_ category: String) -> Color {
        switch category.lowercased() {
        case "calm": return voice
        case "epic": return violet
        case "futuristic": return blue
        case "tension": return pink
        case "upbeat": return yellow
        default: return voiceDeep
        }
    }
}
