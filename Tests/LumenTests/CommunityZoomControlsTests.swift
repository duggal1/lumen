import Foundation
import Testing
import LumenProject
import LumenDirector
import LumenRender

@Test func cameraFocusOffsetMovesIntendedClickWithinSafeViewport() {
    let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 5,
                            backingScale: 2, originX: -1920, originY: 0)
    var tl = Timeline(duration: 5)
    tl.camera.autoZoom = false
    tl.audio.speedRampsAuto = false
    tl.zoom = [ZoomSegment(start: 0.5, end: 4.5, scale: 2.2,
                           focus: .fixed(x: 0.5, y: 0.5), origin: .manual)]
    let normal = Director.derive(tl, input: DirectorInput(events: [], source: source), revision: 1)
    tl.camera.centerOffsetX = 0.12
    tl.camera.centerOffsetY = -0.08
    let adjusted = Director.derive(tl, input: DirectorInput(events: [], source: source), revision: 2)

    let a = normal.evaluate(at: 2.0)
    let b = adjusted.evaluate(at: 2.0)
    #expect(b.cameraCenter.x < a.cameraCenter.x - 50)
    #expect(b.cameraCenter.y > a.cameraCenter.y + 25)
    let geometry = ZoomTransform(canvas: SIMD2(1920, 1080),
                                 source: SIMD2<Double>(1920, 1080),
                                 style: tl.style,
                                 cameraCenter: SIMD2<Double>(Double(b.cameraCenter.x), Double(b.cameraCenter.y)),
                                 scale: Double(b.cameraScale))
    let v = geometry.viewport
    #expect(v.x >= 0 && v.y >= 0)
    #expect(v.x + v.z <= 1920.01 && v.y + v.w <= 1080.01)
}

@Test func independentPaddingRoundTripsAndMapsExactly() throws {
    var style = Style()
    style.paddingInsets = EdgeInsetsN(top: 0.03, right: 0.17, bottom: 0.1, left: 0.05)
    let geometry = ZoomTransform(canvas: SIMD2(1920, 1080),
                                 source: SIMD2<Double>(1440, 900), style: style)
    let rect = geometry.videoRect
    #expect(rect.x >= 0.05 * 1920 - 1)
    #expect(rect.y >= 0.03 * 1920 - 1)
    #expect(rect.x + rect.z <= 1920 * (1 - 0.17) + 1)
    #expect(rect.y + rect.w <= 1080 - 1920 * 0.1 + 1)
    let rebuilt = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(style))
    #expect(rebuilt.paddingInsets == style.paddingInsets)
}
