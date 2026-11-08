import SwiftUI

/// Timeline ink. One hue per data role, all dark-mode 500/400 so strips stay
/// saturated on `well`. The waveform keeps signal orange; every other lane
/// reads by hue, not by brightness alone.
enum StripInk {
    // Audio: signal orange, unchanged.
    static let hot       = Color(light: 0xEA580C, dark: 0xF97316)  // orange-600 / 500: played audio, waveform body
    static let hotDeep   = Color(light: 0xC2410C, dark: 0xFFA14D)  // orange-700 / tip: waveform tips, ramp hit

    // Zoom regions: signal orange (one hue for chrome-accurate lanes).
    static let zoom      = Color(light: 0xEA580C, dark: 0xF97316)  // orange-600 / 500
    static let zoomDeep  = Color(light: 0xC2410C, dark: 0xFFA14D)  // orange-700 / tip: caps, focus

    // Clicks: also signal orange (one hue); triggered clicks read deeper.
    static let click     = Color(light: 0xED7D09, dark: 0xFB923C)  // orange-500 / 400
    static let clickDeep = Color(light: 0xC2410C, dark: 0xFFA14D)  // orange-700 / tip: triggered click

    // Clips: cobalt blue. Imported media: green.
    static let clip      = Color(light: 0x2563EB, dark: 0x3B82F6)  // blue-600 / 500
    static let clipDeep  = Color(light: 0x1D4ED8, dark: 0x60A5FA)  // blue-700 / 400: selected cap
    static let importInk = Color(light: 0x16A34A, dark: 0x22C55E)  // green-600 / 500
    static let importDeep = Color(light: 0x15803D, dark: 0x4ADE80) // green-700 / 400: selected cap

    // Idle / neutral marks.
    static let cell      = Color(light: 0x737373, dark: 0x737373)  // neutral-500: idle click, typing, unplayed audio
    static let cellHover = Color(light: 0x404040, dark: 0xA3A3A3)  // neutral-700 / 400
}
