import Testing
import Foundation
import LumenProject
import LumenCore

import LumenDirector

@Test func legacyWebcamLayoutDecodes() throws {
    let layout = try JSONDecoder().decode(WebcamLayout.self, from: Data("{}".utf8))
    #expect(layout.faceFill == 0.31)
    #expect(layout.faceZoom == 0.6)
}

@Test func shotArrivesAndFaceCropFollowsZoom() {
    let source = SourceInfo(width: 640, height: 360, fps: 60, duration: 4, backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 4)
    timeline.audio.speedRampsAuto = false
    timeline.camera.autoZoom = false
    timeline.webcam = WebcamLayout()
    timeline.zoom = [ZoomSegment(start: 0.5, end: 3, scale: 2, focus: .fixed(x: 0.5, y: 0.5), origin: .manual)]
    let face = [FaceSample(t: 0, cx: 0.5, cy: 0.5, h: 0.2), FaceSample(t: 1, cx: 0.6, cy: 0.5, h: 0.2)]
    let output = Director.derive(timeline, input: DirectorInput(events: [], source: source, face: face), revision: 1)
    #expect(abs(output.evaluate(at: 0.5).cameraScale - 1) < 0.001)
    #expect(abs(output.evaluate(at: 1.5).cameraScale - 2) < 0.001)
    #expect(output.evaluate(at: 2.5).webcamCrop.w < output.evaluate(at: 0).webcamCrop.w)
    #expect(output.derived?.face.count ?? 0 > 4 * 120)
}

@Test func liveCameraReactsToClick() {
    var camera = LiveCamera(source: SIMD2(640, 360))
    _ = camera.step(to: 10)
    camera.ingest(InputEvent(t: 10, kind: .down, x: 500, y: 180))
    let frame = camera.step(to: 10.2)
    #expect(frame.cameraScale > 1)
    #expect(frame.clickFX.count == 1)
    #expect(frame.cameraCenter.x >= 320 / frame.cameraScale)
    #expect(frame.cameraCenter.x <= 640 - 320 / frame.cameraScale)
}
