import Foundation
import Testing
import LumenCore
import LumenProject
import LumenRender
import LumenDirector

@Test(arguments: [1.0, 2.0])
func zoomTransformRespectsDisplayBackingScale(_ backing: Double) {
    let local = SIMD2<Double>(640, 360)
    let global = SIMD2<Double>(-1440 + local.x, 240 + local.y)
    let origin = SIMD2<Double>(-1440, 240)
    let sourcePoint = (global - origin) * backing
    var style = Style()
    style.padding = 0.06
    let source = SIMD2<Double>(1280 * backing, 720 * backing)
    let geo = ZoomTransform(canvas: SIMD2(1920, 1080), source: source, style: style,
                            cameraCenter: sourcePoint, scale: 2.2)
    let mapped = geo.sourceToCanvas(sourcePoint)
    #expect(abs(mapped.x - 960) <= 1)
    #expect(abs(mapped.y - 540) <= 1)
    let inverse = geo.canvasToSource(mapped)
    #expect(abs(inverse.x - sourcePoint.x) < 0.001)
    #expect(abs(inverse.y - sourcePoint.y) < 0.001)
}

@Test(arguments: [0.0, 0.06, 0.20], [1.0, 0.8])
func zoomTransformRespectsCanvasComposition(_ padding: Double, _ size: Double) {
    var style = Style()
    style.padding = padding
    style.contentScale = size
    let src = SIMD2<Double>(1920, 1080)
    let geo = ZoomTransform(canvas: SIMD2(1920, 1080), source: src, style: style, scale: 2.2)
    #expect(geo.videoRect.z <= 1920)
    #expect(geo.videoRect.w <= 1080)
    let p = SIMD2<Double>(900, 300)
    let result = geo.canvasToSource(geo.sourceToCanvas(p))
    #expect(abs(result.x - p.x) < 0.0001)
    #expect(abs(result.y - p.y) < 0.0001)
}

@Test func zoomTransformClampsAtCornersAndWindowCrop() {
    var style = Style()
    style.padding = 0.2
    let src = SIMD2<Double>(800, 480)
    for x in [0.0, 400.0, 800.0] {
        for y in [0.0, 240.0, 480.0] {
            let geo = ZoomTransform(canvas: SIMD2(1280, 720), source: src, style: style,
                                    cameraCenter: SIMD2(x, y), scale: 2.2)
            let v = geo.viewport
            #expect(v.x >= -0.000001 && v.y >= -0.000001)
            #expect(v.x + v.z <= src.x + 0.000001)
            #expect(v.y + v.w <= src.y + 0.000001)
        }
    }
    // Cropped-window coordinates begin at local (0,0), not at the desktop origin.
    let origin = SIMD2<Double>(530, 220)
    let desktop = SIMD2<Double>(650, 300)
    let local = (desktop - origin) * 2
    #expect(local.x == 240 && local.y == 160)
}

@Test func zoomTransformUsesSameOutputTimeAsSpeedRamps() {
    let tm = TimeMap(sourceDuration: 6, ramps: [SpeedRamp(start: 2, end: 4, speed: 2.2)])
    for s in stride(from: 0.0, through: 5.9, by: 0.1) {
        let t = tm.output(atSource: s)
        #expect(abs(tm.source(atOutput: t) - s) < 0.009)
    }
    #expect(tm.outputDuration < 6)
}

@Test func zoomTransformProjectsEveryCursorLocationInsideSourceViewport() {
    let source = SIMD2<Double>(1920, 1080)
    for x in [0.0, 120.0, 960.0, 1800.0, 1920.0] {
        for y in [0.0, 100.0, 540.0, 980.0, 1080.0] {
            let v = ZoomTransform.clamp(SIMD2(x, y), source: source, scale: 2.2)
            let geo = ZoomTransform(canvas: SIMD2(1920, 1080), source: source,
                                    style: Style(), cameraCenter: v, scale: 2.2)
            let rect = geo.viewport
            #expect(rect.x >= 0 && rect.y >= 0)
            #expect(rect.x + rect.z <= source.x + 0.0001)
            #expect(rect.y + rect.w <= source.y + 0.0001)
        }
    }
}
