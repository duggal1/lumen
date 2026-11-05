import Foundation
import Testing
import LumenProject
import LumenRender

@Test func privacyMaskProjectionFollowsZoomedSourceContent() throws {
    var style = Style()
    style.padding = 0.1
    let geometry = Geometry(canvas: SIMD2(1920, 1080), src: SIMD2(1920, 1080), style: style)
    let sourceRect = SIMD4<Float>(1400, 700, 240, 120)
    let cam = SIMD2<Double>(1460, 790)
    let a = try #require(PrivacyMaskGeometry.canvasRect(sourceRect, geometry: geometry,
                                                        camera: SIMD2(960, 540), scale: 1))
    let b = try #require(PrivacyMaskGeometry.canvasRect(sourceRect, geometry: geometry,
                                                        camera: cam, scale: 2.5))
    #expect(b.z > a.z * 2.4)
    #expect(b.w > a.w * 2.4)
    #expect(b.x != a.x)
}

@Test func blendMasksChoosePixelsOnlyOutsideSensitiveSourceRectangle() {
    let src = SIMD2<Float>(320, 180)
    for rect in [
        SIMD4<Float>(60, 40, 120, 40),
        SIMD4<Float>(0, 0, 160, 70),
        SIMD4<Float>(230, 130, 90, 50)
    ] {
        let point = PrivacyMaskGeometry.outsideSample(rect, sourceSize: src)
        #expect(point != nil)
        if let p = point {
            #expect(p.x < rect.x || p.x > rect.x + rect.z ||
                    p.y < rect.y || p.y > rect.y + rect.w)
        }
    }
    #expect(PrivacyMaskGeometry.outsideSample(SIMD4<Float>(0, 0, 320, 180),
                                               sourceSize: src) == nil)
}
