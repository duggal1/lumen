import SwiftUI
import AppKit

extension Color {
    /// Dynamic sRGB token (never Display P3: it shifts the accent).
    init(light: UInt32, dark: UInt32, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, h = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255,
                           alpha: isDark ? darkAlpha : 1)
        })
    }
    init(hex: UInt32) { self.init(light: hex, dark: hex) }
    init(washLight: Double, washDark: Double) {
        self.init(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: washDark) : NSColor(white: 0, alpha: washLight)
        })
    }
}

/// Lumen design tokens. Surfaces separate by one luminance step.
enum Tok {
    static let bg = Color(light: 0xF4F4F4, dark: 0x0A0A0A)
    static let surface = Color(light: 0xFFFFFF, dark: 0x171717)
    static let well = Color(light: 0xEDEDED, dark: 0x0F0F0F)
    static let control = Color(light: 0xEBEBEB, dark: 0x1F1F1F)
    static let controlHover = Color(light: 0xE3E3E3, dark: 0x262626)
    static let controlPressed = Color(light: 0xDADADA, dark: 0x2E2E2E)
    static let text = Color(light: 0x0A0A0A, dark: 0xFAFAFA)
    static let text2 = Color(light: 0x666666, dark: 0xA3A3A3)
    static let accent = Color(light: 0xF05A00, dark: 0xFF6A00)
    static let accentHover = Color(light: 0xE25400, dark: 0xFF8533)
    static let accentPressed = Color(light: 0xD65000, dark: 0xE55C00)
    static let accentText = Color(light: 0xBF3F00, dark: 0xFF8A3D)
    static let accentSoft = Color(light: 0xFFEDD5, dark: 0xFF6A00, darkAlpha: 0.17)
    static let onAccent = Color(hex: 0x0A0A0A)
    static let statusOK = Color(light: 0x16A34A, dark: 0x4ADE80)
    static let statusBad = Color(light: 0xE11D48, dark: 0xFB7185)
    static let wash = Color(washLight: 0.05, washDark: 0.07)
    static let washStrong = Color(washLight: 0.09, washDark: 0.12)
}

enum Ramp {   // rest, dust, quiet, body, tip
    static let o: [Color] = [Color(light: 0xE9E9E9, dark: 0x171717), Color(light: 0xFFEDD5, dark: 0x431407), Color(light: 0xFDBA74, dark: 0x7C2D12),
                             Tok.accent, Color(light: 0x9A3412, dark: 0xFFA14D)]
}

enum AppType {
    static let caption = Font.system(size: 12)
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 13, weight: .medium)
    static let title = Font.system(size: 15, weight: .medium)
    static let metric = Font.system(size: 28, weight: .medium).monospacedDigit()
    static let page = Font.system(size: 28, design: .serif).italic()
}

extension View {
    func card() -> some View { padding(20).background(RoundedRectangle(cornerRadius: 16).fill(Tok.surface)) }
}
