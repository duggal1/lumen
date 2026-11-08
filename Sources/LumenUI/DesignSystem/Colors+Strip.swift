import SwiftUI

/// Timeline ink. Same roles as `Ramp.orange` (body, tip), pushed to Tailwind orange 600/700
/// in light and 500 / bright tip in dark so strips read saturated, never washed.
enum StripInk {
    static let hot       = Color(light: 0xEA580C, dark: 0xF97316)  // orange-600 / orange-500: auto zoom, triggered click, played audio, selected clip
    static let hotDeep   = Color(light: 0xC2410C, dark: 0xFFA14D)  // orange-700 / tip: manual zoom, caps, waveform tips
    static let cell      = Color(light: 0x737373, dark: 0x737373)  // neutral-500: idle clip, idle click, typing, unplayed audio
    static let cellHover = Color(light: 0x404040, dark: 0xA3A3A3)  // neutral-700 / neutral-400
}
