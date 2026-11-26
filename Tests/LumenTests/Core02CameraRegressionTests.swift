import Foundation
import CoreGraphics
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

@Suite struct Core02CameraRegressionTests {
    private let source = SIMD2<Double>(1920, 1080)

    @Test func largerIsolatedOpticalMoveReceivesMoreRunway() {
        let small = CameraSolver.automaticRunway(logScale: log(1.25), center: SIMD2(0.5, 0.5), base: 0.3)
        let large = CameraSolver.automaticRunway(logScale: log(2), center: SIMD2(0.8, 0.7), base: 0.3)
        #expect(small >= 0.44)
        #expect(large > small + 0.15)
        #expect(large <= 0.85)
        #expect(CameraSolver.automaticRunway(logScale: log(2), center: SIMD2(0.5, 0.5), base: 1.0) == 1.0)
    }

    @Test func automaticActionGetsSlowerApproachWithoutChangingArrival() throws {
        let z = ZoomSegment(start: 3, end: 4.5, scale: 2,
                            focus: .fixed(x: 0.5, y: 0.5), origin: .auto)
        let tm = TimeMap(sourceDuration: 6)
        let cursor = CursorTrack(count: Int(6 * gridRate) + 1)
        let old = try #require(CameraSolver.solve(zoom: [z], tm: tm, cursor: cursor,
            p: CameraParams(), src: source, outDur: 6, loop: nil, follow: [:], cancelled: { false }))
        let new = try #require(CameraSolver.solve(zoom: [z], tm: tm, cursor: cursor,
            p: CameraParams(), src: source, outDur: 6, loop: nil,
            kinds: [z.id: .click], follow: [:], cancelled: { false }))
        let earlier = Int((2.5 * new.rate).rounded())
        let arrival = Int((2.98 * new.rate).rounded())
        #expect(new.lz[earlier] > old.lz[earlier] + 0.01)
        #expect(abs(Double(new.lz[arrival]) - log(2)) < 1e-4)
        #expect(new.vz.map { abs($0) }.max()! < old.vz.map { abs($0) }.max()!)
        #expect(new.lz.last == 0)
    }

    @Test func recordedPathActuallyMovesAfterArrival() throws {
        let z = ZoomSegment(start: 2, end: 5.5, scale: 2, focus: .follow, origin: .auto)
        let path: [(t: Double, c: SIMD2<Double>)] = [
            (2, SIMD2(0.35, 0.5)), (2.6, SIMD2(0.35, 0.5)),
            (3.2, SIMD2(0.55, 0.5)), (3.8, SIMD2(0.65, 0.5)),
            (5.5, SIMD2(0.65, 0.5))
        ]
        let tr = try #require(CameraSolver.solve(zoom: [z], tm: TimeMap(sourceDuration: 7),
            cursor: CursorTrack(count: Int(7 * gridRate) + 1), p: CameraParams(),
            src: source, outDur: 7, loop: nil, follow: [z.id: path], cancelled: { false }))
        func index(_ t: Double) -> Int { Int((t * tr.rate).rounded()) }
        #expect(Double(tr.nx[index(4.8)] - tr.nx[index(2.2)]) > 0.18)
        #expect(abs(Double(tr.lz[index(4.8)]) - log(2)) < 1e-4)
        #expect(tr.nx.allSatisfy { $0.isFinite })
        for k in 1..<tr.nx.count {
            #expect(abs(tr.nx[k] - tr.nx[k - 1]) < 0.02)
        }
    }

    @Test func liveElapsedTimeIsIndependentOfDisplayCallbackCadence() {
        var dense = LiveCamera(source: source)
        var sparse = dense
        _ = dense.step(to: 10); _ = sparse.step(to: 10)
        let click = InputEvent(t: 10, kind: .down, x: 640, y: 410)
        dense.ingest(click); sparse.ingest(click)
        for n in 1...29 { _ = dense.step(to: 10 + Double(n) / 60) }
        let a = dense.step(to: 10.5), b = sparse.step(to: 10.5)
        #expect(abs(a.cameraScale - b.cameraScale) < 0.001)
        #expect(abs(a.cameraCenter.x - b.cameraCenter.x) < 0.1)
        #expect(abs(a.cameraCenter.y - b.cameraCenter.y) < 0.1)
    }

    @Test func lateClickDoesNotRetroactivelyAnimateBeforeItsTimestamp() {
        var camera = LiveCamera(source: source)
        _ = camera.step(to: 10)
        camera.ingest(InputEvent(t: 10.5, kind: .down, x: 640, y: 410))
        #expect(abs(camera.step(to: 10.5).cameraScale - 1) < 0.001)
        #expect(camera.step(to: 10.7).cameraScale > 1.1)
    }

    @Test func lateTypingFocusCannotOverrideNewerClick() {
        var camera = LiveCamera(source: source)
        _ = camera.step(to: 10)
        let key = InputEvent(t: 10.1, kind: .keyDown, keyCode: 7)
        camera.ingest(key)
        camera.ingest(InputEvent(t: 10.3, kind: .down, x: 450, y: 400))
        var reference = camera
        var field = AXFrame(x: 1420, y: 620, w: 260, h: 50,
                           anchor: FocusAnchor(epoch: 1, sampledAt: 10.1, resolved: true))
        field.caret = AXFrame.Rect(x: 1440, y: 630, w: 2, h: 24)
        camera.ingest(key, focus: field)
        let a = camera.step(to: 10.9), b = reference.step(to: 10.9)
        #expect(abs(a.cameraScale - b.cameraScale) < 0.001)
        #expect(abs(a.cameraCenter.x - b.cameraCenter.x) < 0.1)
        #expect(abs(a.cameraCenter.y - b.cameraCenter.y) < 0.1)
    }

    @Test func fixedFocusUsesCropSpaceAndReleasesWithoutTeleport() throws {
        let z = ZoomSegment(start: 2, end: 4, scale: 2,
                            focus: .fixed(x: 900.0 / 1920, y: 500.0 / 1080), origin: .auto)
        let rect = SIMD4<Float>(200, 100, 1200, 800)
        let crop = DenseCropTrack(hz: 1, rects: [rect, rect])
        let tr = try #require(CameraSolver.solve(zoom: [z], tm: TimeMap(sourceDuration: 6),
            cursor: CursorTrack(count: Int(6 * gridRate) + 1), p: CameraParams(),
            src: source, outDur: 6, loop: nil, crop: crop, follow: [:], cancelled: { false }))
        let k = Int(3 * tr.rate)
        #expect(abs(Double(tr.nx[k]) - 700.0 / 1200) < 0.002)
        #expect(abs(Double(tr.ny[k]) - 0.5) < 0.002)
        for j in 1..<tr.nx.count {
            #expect(abs(tr.nx[j] - tr.nx[j - 1]) < 0.02)
            #expect(abs(tr.ny[j] - tr.ny[j - 1]) < 0.02)
        }
        #expect(tr.lz.last == 0)
        #expect(tr.nx.last == 0.5)
        #expect(tr.ny.last == 0.5)
    }

    @Test func navigationDoesNotResurrectReleasedZoom() {
        var camera = LiveCamera(source: source)
        camera.hold = 0.5
        _ = camera.step(to: 10)
        camera.ingest(InputEvent(t: 10, kind: .down, x: 640, y: 410))
        camera.ingest(InputEvent(t: 10.1, kind: .up, x: 640, y: 410))
        #expect(camera.step(to: 10.4).cameraScale > 1.1)
        #expect(camera.step(to: 13).cameraScale < 1.001)
        camera.ingest(InputEvent(t: 13.1, kind: .scroll, x: 1800, y: 800, scrollDelta: 3))
        camera.ingest(InputEvent(t: 13.2, kind: .down, x: 1800, y: 800, button: 1))
        #expect(camera.step(to: 13.6).cameraScale < 1.001)
    }
}
