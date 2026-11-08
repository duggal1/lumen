import Testing
@testable import LumenProject
@testable import LumenDirector

/// Zoom-crop oracle: the clicked AX control + 8% context must stay inside the
/// camera viewport at the click time (screenshot at 0:25 cut text on the right).
@Test func zoomNeverCropsAxControlWithContext() throws {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 12, backingScale: 2, originX: 0, originY: 0)
    var tl = Timeline(duration: 12)
    tl.camera.autoZoom = true
    tl.camera.minScale = 1.1
    tl.camera.maxScale = 3.5
    tl.audio.speedRampsAuto = false
    let ax = AXFrame(x: 1400, y: 400, w: 300, h: 80, isPasswordField: false) // right-edge control
    let events = [InputEvent(t: 2.0, kind: .down, x: 1550, y: 440, button: 0, axFrameIndex: 1)]
    tl = try Director.derive(tl, input: DirectorInput(events: events, source: src, ax: [ax]), revision: 1)
    let f = tl.evaluate(at: 2.0)
    let vw = 1920.0 / Double(f.cameraScale), vh = 1080.0 / Double(f.cameraScale)
    let marginX = 1920.0 * 0.08, marginY = 1080.0 * 0.08
    let needX0 = 1400 - marginX, needX1 = 1700 + marginX
    let needY0 = 400 - marginY, needY1 = 480 + marginY
    let camX = Double(f.cameraCenter.x), camY = Double(f.cameraCenter.y)
    #expect(camX - vw / 2 <= needX0 + 1, "left crop: cam \(camX-vw/2) need \(needX0)")
    #expect(camX + vw / 2 >= needX1 - 1, "right crop: cam \(camX+vw/2) need \(needX1)")
    #expect(camY - vh / 2 <= needY0 + 1, "top crop")
    #expect(camY + vh / 2 >= needY1 - 1, "bottom crop")
    // Lead: zoom starts before the click.
    let zooms = tl.zoom.filter { $0.origin == .auto }
    #expect(zooms.contains { $0.start <= 2.0 }, "lead begin <= click \(zooms.map(\.start))")
}
