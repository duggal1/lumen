import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

private func placementFixture(clicks: [ClickFX], avoidance: Bool = true) -> (PlacementTrack, LayoutTrack) {
    let duration = 4.0
    let src = SIMD2<Double>(1920, 1080)
    var tl = Timeline(duration: duration)
    tl.webcam = WebcamLayout()
    tl.layoutSettings.cameraOverlay.corner = .bottomRight
    tl.layoutSettings.cameraOverlay.size = 0.22
    tl.layoutSettings.cameraOverlay.avoidCursor = avoidance
    tl.layoutSettings.cameraOverlay.snapDwell = 1.0
    let count = Int(duration * gridRate) + 2
    var cursor = CursorTrack(count: count)
    cursor.x = [Float](repeating: 100, count: count)
    cursor.y = [Float](repeating: 100, count: count)
    let camera = CameraTrack(count: count)
    let placement = WebcamPlacement.solve(tl, tm: tl.timeMap, cam: camera, cursor: cursor,
                                         src: src, vad: [], outDur: duration, clicks: clicks)
    let layouts = LayoutSolver.solve(tl, spans: [], fallback: .cameraOverlay,
                                      src: src, webcamAspect: 16.0 / 9,
                                      placement: placement, outDur: duration)
    return (placement, layouts)
}

@Test func predictiveWebcamAvoidanceMovesBeforeQuickBottomRightClick() {
    let event = ClickFX(t: 1.5, x: 1800, y: 950)
    let (placement, layout) = placementFixture(clicks: [event])
    let (baseline, _) = placementFixture(clicks: [])
    #expect(baseline.corner(at: 1.0) == .bottomRight)
    #expect(placement.corner(at: 1.0) == .bottomLeft)
    #expect(layout.sample(at: 1.45).cameraRect.x < 0.4)
}

@Test func webcamPredictionIgnoresUnobstructedClick() {
    let event = ClickFX(t: 1.5, x: 950, y: 450)
    let (placement, _) = placementFixture(clicks: [event])
    #expect(placement.corner(at: 1.0) == .bottomRight)
}

@Test func webcamPredictionRespectsAvoidCursorDisabled() {
    let event = ClickFX(t: 1.5, x: 1800, y: 950)
    let (placement, _) = placementFixture(clicks: [event], avoidance: false)
    #expect(placement.corner(at: 1.0) == .bottomRight)
}
