import Foundation
import Testing
import LumenProject
import LumenRender

/// One knob: the background blur is a continuous radius in canvas pixels, and
/// it ships at zero. The mip level behind the zoom follows it.
@Test func backdropBlurIsContinuousAndShipsSharp() throws {
    let style = Style()
    #expect(style.wallpaperBlur == 0, "a wallpaper ships sharp")
    #expect(BackdropBlur.mipLevel(enabled: false, cameraScale: 4) == 0)
    #expect(BackdropBlur.mipLevel(enabled: true, cameraScale: 1) == 0)
    #expect(BackdropBlur.mipLevel(enabled: true, cameraScale: 1.8) > 0)
    #expect(BackdropBlur.mipLevel(enabled: true, cameraScale: 4) <= 3.5)
    #expect(BackdropBlur.mipLevel(enabled: true, cameraScale: .infinity) == 0)

    var active = style
    active.wallpaperBlur = 24
    let restored = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(active))
    #expect(restored.wallpaperBlur == 24)
}

@Test func backdropBlurStrengthIsMonotonicAsZoomIncreases() {
    let scales: [Float] = [1, 1.05, 1.15, 1.5, 2, 3, 6]
    let levels = scales.map { BackdropBlur.mipLevel(enabled: true, cameraScale: $0) }
    #expect(zip(levels, levels.dropFirst()).allSatisfy { pair in pair.0 <= pair.1 })
}
