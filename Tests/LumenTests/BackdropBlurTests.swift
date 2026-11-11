import Foundation
import Testing
import LumenProject
import LumenRender

/// One knob: the wallpaper blur is a continuous radius in canvas pixels and it
/// ships at zero. There is no zoom-driven mip selection any more: the radius
/// is the whole contract, it is continuous, and it round-trips.
@Test func wallpaperBlurIsContinuousAndShipsSharp() throws {
    let style = Style()
    #expect(style.wallpaperBlur == 0, "a wallpaper ships sharp")

    var active = style
    active.wallpaperBlur = 24
    let restored = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(active))
    #expect(restored.wallpaperBlur == 24)
}

/// The radius is a continuous value, not a step or a toggle: any radius in
/// range survives a save/load cycle unchanged, and neighbouring radii stay
/// distinct.
@Test func wallpaperBlurKeepsEveryRadiusExactly() throws {
    for radius in [0.0, 0.5, 1, 7.25, 30, 59.5, 60] {
        var style = Style()
        style.wallpaperBlur = radius
        let data = try JSONEncoder().encode(style)
        let restored = try JSONDecoder().decode(Style.self, from: data)
        #expect(restored.wallpaperBlur == radius, "radius=\(radius)")
    }
}
