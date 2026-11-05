import Foundation
import Testing
import Metal
import LumenProject
@testable import LumenRender
@testable import LumenDirector

@Test func personMatteFileReadsAndInterpolatesTimestampedFrames() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lmask")
    defer { try? FileManager.default.removeItem(at: url) }
    var bytes = Data([0x4c, 0x55, 0x4d, 0x41, 0x53, 0x4b, 0x31, 0])
    func append<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
    }
    append(UInt32(2)); append(UInt32(2))
    for (time, pixels) in [(1.0, [UInt8](repeating: 255, count: 4)),
                           (1.1, [UInt8](repeating: 0, count: 4))] {
        append(time.bitPattern)
        bytes.append(contentsOf: pixels)
    }
    try bytes.write(to: url)
    let info = PersonMaskInfo(file: url.lastPathComponent, width: 2, height: 2, fps: 10, frames: 2)
    let reader = try #require(PersonMatteSequence(url: url, info: info))
    let (a, b, fraction) = try #require(reader.indices(at: 1.05))
    #expect(a == 0)
    #expect(b == 1)
    #expect(abs(fraction - 0.5) < 0.001)
    #expect(reader.indices(at: 9.0) == nil)
    if let device = MTLCreateSystemDefaultDevice() {
        let sample = try #require(reader.sample(at: 1.05, slot: 0, device: device))
        #expect(sample.previous.width == 2)
        #expect(sample.next.height == 2)
    }
}

@Test func webcamAvoidsBottomRightCursorAndLayoutUsesMovedCorner() {
    let source = SIMD2<Double>(1920, 1080)
    var tl = Timeline(duration: 5)
    tl.webcam = WebcamLayout()
    tl.layoutSettings.cameraOverlay.snapDwell = 0.35
    tl.layoutSettings.cameraOverlay.size = 0.22
    let tm = tl.timeMap
    let count = Int(5 * gridRate) + 2
    var cursor = CursorTrack(count: count)
    cursor.x = [Float](repeating: 1770, count: count)
    cursor.y = [Float](repeating: 920, count: count)
    var camera = CameraTrack(count: count)
    camera.nx = [Float](repeating: 0.5, count: count)
    camera.ny = [Float](repeating: 0.5, count: count)
    let placement = WebcamPlacement.solve(tl, tm: tm, cam: camera, cursor: cursor,
                                         src: source, vad: [], outDur: 5)
    #expect(placement.corner(at: 3) == .bottomLeft)
    let layout = LayoutSolver.solve(tl, spans: [], fallback: .cameraOverlay,
                                    src: source, webcamAspect: 16.0 / 9.0,
                                    placement: placement, outDur: 5)
    #expect(layout.sample(at: 3).cameraRect.x < 0.5)
}

@Test func oldWebcamProjectsDecodeWithoutNewStudioKeys() throws {
    let layout = try JSONDecoder().decode(WebcamLayout.self, from: Data("{}".utf8))
    #expect(layout.backdrop == .original)
    #expect(layout.enhancement == .natural)
    #expect(layout.detailAmount == 0.5)
    var withStudio = layout
    withStudio.backdrop = .transparent
    withStudio.enhancement = .crisp
    let roundTrip = try JSONDecoder().decode(WebcamLayout.self, from: JSONEncoder().encode(withStudio))
    #expect(roundTrip.backdrop == .transparent)
    #expect(roundTrip.enhancement == .crisp)
}
