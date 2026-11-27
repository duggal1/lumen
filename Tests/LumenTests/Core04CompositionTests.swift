import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

@Suite struct Core04CompositionTests {
    @Test func everyLayoutIsFiniteAndInsideCanvas() {
        let insets = [EdgeInsetsN(all: 0.025), EdgeInsetsN(all: 0.9),
                      EdgeInsetsN(top: .nan, right: -4, bottom: .infinity, left: 1)]
        for aspect in [16.0 / 9, 1, 9.0 / 16, 4, 0.25, .nan, 0] {
            for inset in insets {
                for kind in LayoutKind.allCases {
                    var settings = LayoutSettings()
                    settings.size = .nan
                    let result = LayoutResolver.target(kind, settings, corner: .bottomRight,
                        aspect: aspect, srcAspect: .nan, insets: inset, webcamAspect: .infinity)
                    for rect in [result.screenRect, result.cameraRect] {
                        #expect(rect.x.isFinite && rect.y.isFinite && rect.z.isFinite && rect.w.isFinite)
                        #expect(rect.x >= -0.00001 && rect.y >= -0.00001)
                        #expect(rect.z > 0 && rect.w > 0)
                        #expect(rect.x + rect.z <= 1.00001 && rect.y + rect.w <= 1.00001)
                    }
                }
            }
        }
    }

    @Test func partialCameraAndCursorTracksNeverIndexOutOfBounds() {
        let duration = 2.0
        var tl = Timeline(duration: duration)
        tl.webcam = WebcamLayout()
        var camera = CameraTrack(count: 3)
        camera.ny = []
        var cursor = CursorTrack(count: 3)
        cursor.opacity = []
        let result = WebcamPlacement.solve(tl, tm: tl.timeMap, cam: camera, cursor: cursor,
            src: SIMD2<Double>(1920, 1080), vad: [], outDur: duration)
        #expect(result.corner(at: 1) == tl.layoutSettings.cameraOverlay.corner)
    }

    @Test func explicitCutoutCornerIsNotOverwrittenByOverlayAvoidance() {
        var tl = Timeline(duration: 1)
        tl.webcam = WebcamLayout()
        tl.layoutSettings.cameraCutout.corner = .topLeft
        let placement = PlacementTrack(rate: 60, corner: [3, 3], visible: [0, 0])
        let track = LayoutSolver.solve(tl, spans: [], fallback: .cameraCutout,
            src: SIMD2<Double>(1920, 1080), webcamAspect: 16.0 / 9,
            placement: placement, outDur: 1)
        let sample = track.sample(at: 0)
        #expect(sample.cameraRect.x < 0.05)
        #expect(sample.cameraOpacity == 1)
    }
}
