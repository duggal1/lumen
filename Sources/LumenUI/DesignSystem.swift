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
    init(scrim scr: Double, dark: Double) {
        self.init(nsColor: NSColor(name: nil) { ap in
            NSColor(white: 0, alpha: ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : scr)
        })
    }
}

/// Lumen design tokens. Surfaces separate by one luminance step; no hex outside this file.
enum Tok {
    // surfaces
    static let bg = Color(light: 0xF4F4F4, dark: 0x0A0A0A)
    static let surface = Color(light: 0xFFFFFF, dark: 0x171717)
    static let well = Color(light: 0xEDEDED, dark: 0x0F0F0F)
    static let control = Color(light: 0xEBEBEB, dark: 0x1F1F1F)
    static let controlHover = Color(light: 0xE3E3E3, dark: 0x262626)
    static let controlPressed = Color(light: 0xDADADA, dark: 0x2E2E2E)
    static let field = Color(light: 0xEAEAEA, dark: 0x101010)
    static let fieldHover = Color(light: 0xE3E3E3, dark: 0x151515)
    static let island = Color(hex: 0x000000)
    // text
    static let text = Color(light: 0x0A0A0A, dark: 0xFAFAFA)
    static let text2 = Color(light: 0x666666, dark: 0xA3A3A3)
    static let textAction = Color(light: 0x2E2E2E, dark: 0xE5E5E5)
    // accent: signal orange, the only brand colour
    static let accent = Color(light: 0xF05A00, dark: 0xFF6A00)
    static let accentHover = Color(light: 0xE25400, dark: 0xFF8533)
    static let accentPressed = Color(light: 0xD65000, dark: 0xE55C00)
    static let accentText = Color(light: 0xBF3F00, dark: 0xFF8A3D)
    static let accentSoft = Color(light: 0xFFEDD5, dark: 0xFF6A00, darkAlpha: 0.17)
    static let accentFill = Color(light: 0xFFEDD5, dark: 0xFF6A00, darkAlpha: 0.50)
    static let onAccent = Color(hex: 0x0A0A0A)     // near-black: white on orange fails contrast
    // status, diff
    static let statusOK = Color(light: 0x16A34A, dark: 0x4ADE80)
    static let statusBad = Color(light: 0xE11D48, dark: 0xFB7185)   // rose, never red
    static let diffStrong = Color(light: 0xFDBA74, dark: 0xC2410C)
    static let diffSoft = Color(light: 0xFFEDD5, dark: 0x7C2D12)
    static let diffInk = Color(light: 0x0A0A0A, dark: 0xFFFFFF)
    // alpha washes, scrims (translucent backdrops only)
    static let wash = Color(washLight: 0.05, washDark: 0.07)
    static let washStrong = Color(washLight: 0.09, washDark: 0.12)
    static let modalScrim = Color(scrim: 0.28, dark: 0.55)
    static let scrim = Color(hex: 0x000000).opacity(0.18)
}

enum Ramp {   // rest, dust, quiet, body, tip
    static let orange: [Color] = [
        Color(light: 0xE9E9E9, dark: 0x171717), Color(light: 0xFFEDD5, dark: 0x431407),
        Color(light: 0xFDBA74, dark: 0x7C2D12), Color(light: 0xF05A00, dark: 0xFF6A00),
        Color(light: 0x9A3412, dark: 0xFFA14D)]
    /// Recording activity. Zero activity is a gap, never a colour.
    static let heat: [Color] = [
        Color(light: 0xFFEDD5, dark: 0x7C2D12), Color(light: 0xFDBA74, dark: 0xC2410C),
        Color(light: 0xF05A00, dark: 0xFF6A00), Color(light: 0xBF3F00, dark: 0xFFA14D)]
    static let o = orange
}

/// One UI face, two weights. Tracking belongs at the call site so text stays selectable.
enum AppType {
    static let caption = Font.system(size: 12, weight: .regular)
    static let body = Font.system(size: 13, weight: .regular)
    static let label = Font.system(size: 13, weight: .medium)
    static let reading = Font.system(size: 15, weight: .regular)
    static let title = Font.system(size: 15, weight: .medium)
    static let metric = Font.system(size: 28, weight: .medium).monospacedDigit()
    static let mono = Font.system(size: 12, design: .monospaced)
    static let mono13 = Font.system(size: 13, design: .monospaced)
    static let page = Font.system(size: 28, design: .serif).italic()
    static let onboarding = Font.system(size: 40, design: .serif).italic()
}

/// 4 pt grid. Anything else needs a written reason.
enum Space {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let s5: CGFloat = 20, s6: CGFloat = 24, s8: CGFloat = 32, s12: CGFloat = 48, s16: CGFloat = 64
}

enum Radius {
    static let card: CGFloat = 16, nested: CGFloat = 12, field: CGFloat = 8
    static let chip: CGFloat = 6, menu: CGFloat = 12, menuRow: CGFloat = 8
}

enum Layout {
    static let pagePad: CGFloat = 32, sectionGap: CGFloat = 32, cardPad: CGFloat = 20
    static let pageBar: CGFloat = 52, sidebar: CGFloat = 220, inspector: CGFloat = 280
    static let timeline: CGFloat = 184, wide: CGFloat = 880, settings: CGFloat = 640
    static let listPane: CGFloat = 320, windowW: CGFloat = 1120, windowH: CGFloat = 720
    static let minW: CGFloat = 960, minH: CGFloat = 600
}

/// Whole device pixels at 1x, 2x and 3x. A half-pixel edge is a bug.
enum Pixel {
    static func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
    static func snapEven(_ v: CGFloat) -> CGFloat { (v / 2).rounded() * 2 }
    static func cell(_ v: CGFloat) -> CGFloat { max(1, v.rounded()) }
}

enum Motion {
    static let hoverIn = Animation.easeOut(duration: 0.10)
    static let hoverOut = Animation.easeOut(duration: 0.22)
    static let route = Animation.easeOut(duration: 0.18)
    static let slide = Animation.smooth(duration: 0.30)
    static let menuOpen = Animation.smooth(duration: 0.20)
    static let menuClose = Animation.easeOut(duration: 0.12)
    static let menuHighlight = Animation.smooth(duration: 0.18)
    static let toggle = Animation.snappy(duration: 0.22)
    static let settle = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.28)
}

extension View {
    func card(padding: CGFloat = Layout.cardPad) -> some View {
        self.padding(padding).background(RoundedRectangle(cornerRadius: Radius.card).fill(Tok.surface))
    }
}
