import SwiftUI

/// Dieother: the pixel-instrument palette the timeline already draws with,
/// reused as the right side's dieother theme language. Right-side chrome reads
/// from here, never a hex outside DesignSystem.
enum Dieother {
    /// Signal orange, the dieother accent — the same token the timeline uses.
    static let accent = Tok.accent
    static let accentHover = Tok.accentHover
    static let accentText = Tok.accentText
    static let accentSoft = Tok.accentSoft

    /// The voice/cyan cell of the timeline voice tape (TimelineDitherRenderer
    /// hues[4]).
    static let voice = Color(light: 0x00A0BA, dark: 0x00B0C9)
    static let voiceDeep = Color(light: 0x007A94, dark: 0x006A8A)

    // Mood sleeves in the music picker, dieother hues from the instrument
    // palette where a closest match exists.
    static let yellow = Color(light: 0xF5C518, dark: 0xFFD54C)
    static let violet = Color(light: 0x8848E1, dark: 0xAC70FF)
    static let blue = Color(light: 0x3D9EFF, dark: 0x5BBAFF)
    static let pink = Color(light: 0xFF5BB3, dark: 0xFF7DAC)

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
