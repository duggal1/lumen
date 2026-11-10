import Testing
import LumenProject
import LumenDirector

@Test func zoomEasingChangesCameraArrivalTime() {
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 5, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 5)
    tl.camera.autoZoom = false
    tl.audio.speedRampsAuto = false
    tl.zoom = [ZoomSegment(start: 1, end: 4, scale: 2, focus: .fixed(x: 0.5, y: 0.5), easing: .snappy, origin: .manual)]
    let input = DirectorInput(events: [], source: src)
    let fast = Director.derive(tl, input: input, revision: 1)
    tl.zoom[0].easing = .cinematic
    let slow = Director.derive(tl, input: input, revision: 2)
    // Compare while the move is still running: the easing decides how fast
    // the camera arrives, so the difference shows mid-flight.
    #expect(fast.evaluate(at: 1.2).cameraScale > slow.evaluate(at: 1.2).cameraScale + 0.1)
}
