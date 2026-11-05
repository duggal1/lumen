import Foundation
import Testing
import LumenProject
import LumenDirector
import LumenRender

@Test func manualMasksStayIndependentAcrossAutoZoomAndOutputTime() {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 5,
                         backingScale: 2, originX: 0, originY: 0)
    var timeline = Timeline(duration: 5)
    timeline.audio.speedRampsAuto = false
    timeline.overlays.privacy.autoDetect = false
    timeline.overlays.masks = [
        Mask(start: 1, end: 5, mode: .solid,
             keys: [MaskKey(t: 1, x: 1200, y: 650, w: 200, h: 80)], padding: 0),
        Mask(start: 1, end: 5, mode: .blend,
             keys: [MaskKey(t: 1, x: 500, y: 260, w: 180, h: 70)], padding: 0),
    ]
    timeline.zoom = [ZoomSegment(start: 1, end: 4, scale: 2.5,
                                  focus: .fixed(x: 0.7, y: 0.7), origin: .manual)]
    timeline.camera.autoZoom = false
    let derived = Director.derive(timeline, input: DirectorInput(events: [], source: src), revision: 1)
    #expect(derived.evaluate(at: 0.5).emphasis.masks.isEmpty)
    let active = derived.evaluate(at: 2.5)
    #expect(active.emphasis.masks.count == 2)
    #expect(active.emphasis.masks.map(\.mode) == [.solid, .blend])
    #expect(active.emphasis.masks[0].rect == SIMD4<Float>(1200, 650, 200, 80))
    #expect(active.emphasis.masks[1].rect == SIMD4<Float>(500, 260, 180, 70))
    let canvas = Geometry(canvas: SIMD2(1920, 1080), src: SIMD2<Double>(1920, 1080),
                          style: derived.style)
    let transformed = PrivacyMaskGeometry.canvasRect(
        active.emphasis.masks[0].rect, geometry: canvas,
        camera: SIMD2(Double(active.cameraCenter.x), Double(active.cameraCenter.y)),
        scale: Double(active.cameraScale))
    #expect(transformed != nil)
    #expect(transformed!.z > 200)
}
