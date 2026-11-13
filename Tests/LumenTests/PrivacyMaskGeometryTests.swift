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

@Test func mosaicEdgesLandOnWholeCellsAndNeverShrink() {
    let cell = PrivacyMaskGeometry.cell(boxHeight: 18)
    #expect(abs(cell - 9.9) < 0.01, "cell follows the box height")
    #expect(PrivacyMaskGeometry.cell(boxHeight: 4) == 8, "a floor keeps a glyph unreadable")
    #expect(PrivacyMaskGeometry.cell(boxHeight: 400) == 24, "a cap keeps the mosaic a mosaic")
    for rect in [SIMD4<Float>(101, 57, 40, 12), SIMD4<Float>(0, 0, 8, 8), SIMD4<Float>(1900, 1070, 30, 20)] {
        let m = PrivacyMaskGeometry.mosaicRegion(rect, cell: cell)
        // Whole cells: a partial cell leaves an unmasked sliver as soon as the
        // camera zooms.
        #expect(abs(m.x / cell - (m.x / cell).rounded()) < 0.0001, "x \(m.x) is off the lattice")
        #expect(abs(m.y / cell - (m.y / cell).rounded()) < 0.0001, "y \(m.y) is off the lattice")
        #expect(abs(m.z / cell - (m.z / cell).rounded()) < 0.0001, "w \(m.z) is off the lattice")
        #expect(abs(m.w / cell - (m.w / cell).rounded()) < 0.0001, "h \(m.w) is off the lattice")
        #expect(m.x <= rect.x && m.y <= rect.y, "the treated rect grows outward")
        #expect(m.z >= rect.z && m.w >= rect.w, "the treated rect never shrinks")
    }
}

@Test func canvasRectStaysInsideTheSourceAndKeepsItsSize() throws {
    let style = Style()
    let geometry = Geometry(canvas: SIMD2(1280, 720), src: SIMD2(1920, 1080), style: style)
    // A mask that hangs off the frame is clamped to the visible pixels.
    let clipped = try #require(PrivacyMaskGeometry.canvasRect(SIMD4<Float>(-40, -30, 200, 100),
                                                             geometry: geometry, camera: SIMD2(960, 540), scale: 1))
    #expect(clipped.z > 0 && clipped.w > 0)
    #expect(clipped.x >= 0 && clipped.y >= 0)
    #expect(PrivacyMaskGeometry.canvasRect(SIMD4<Float>(-200, -200, 10, 10), geometry: geometry,
                                           camera: SIMD2(960, 540), scale: 1) == nil,
            "a rect fully outside the source has no canvas footprint")
    #expect(PrivacyMaskGeometry.canvasRect(SIMD4<Float>(0, 0, 0, 10), geometry: geometry,
                                           camera: SIMD2(960, 540), scale: 1) == nil)
}
