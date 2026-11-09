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
