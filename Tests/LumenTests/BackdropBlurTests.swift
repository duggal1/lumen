import Foundation
import Testing
import LumenProject
import LumenRender

@Test func zoomBackdropBlurIsOffByDefaultAndSourceSafe() throws {
    let style = Style()
    #expect(style.zoomBackgroundBlur == false)
    #expect(BackdropBlur.mipLevel(enabled: false, cameraScale: 4) == 0)
    #expect(BackdropBlur.mipLevel(enabled: true, cameraScale: 1) == 0)
    #expect(BackdropBlur.mipLevel(enabled: true, cameraScale: 1.8) > 0)
    #expect(BackdropBlur.mipLevel(enabled: true, cameraScale: 4) <= 3.5)
    #expect(BackdropBlur.mipLevel(enabled: true, cameraScale: .infinity) == 0)

    var active = style
    active.zoomBackgroundBlur = true
    let restored = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(active))
    #expect(restored.zoomBackgroundBlur == true)
}

@Test func backdropBlurStrengthIsMonotonicAsZoomIncreases() {
    let scales: [Float] = [1, 1.05, 1.15, 1.5, 2, 3, 6]
    let levels = scales.map { BackdropBlur.mipLevel(enabled: true, cameraScale: $0) }
    #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 <= $1 })
}
