import Testing
import LumenCore
import LumenDirector

@Test func cropSamplingHandlesNonfiniteTimeWithoutTrapping() {
    let track = ViewportCropTrack(hz: 480, rects: [SIMD4(0, 0, 1920, 1080), SIMD4(100, 100, 800, 600)])
    #expect(track.rect(at: .nan) == track.rect(at: 0))
    #expect(track.rect(at: .greatestFiniteMagnitude) == track.rect(at: 1))
}
@Test func cameraCropHandlesCorruptCoordinatesAndFeather() {
    let crop = PxRect(x: 10, y: 20, w: 1200, h: 800)
    let view = CropSpace.visible(crop: crop, aspect: 9.0 / 16, u: .nan, v: .infinity, logZ: .nan)
    #expect(view.isValid)
    #expect(view.x >= crop.x && view.y >= crop.y && view.maxX <= crop.maxX && view.maxY <= crop.maxY)
    #expect(CropSpace.cursorVisibility(x: 20, y: 30, crop: crop, feather: 0) == 1)
    #expect(CropSpace.cursorVisibility(x: .nan, y: 30, crop: crop) == 0)
}
