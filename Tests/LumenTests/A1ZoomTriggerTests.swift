import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// A1 / R1 — zoom fires only on meaningful intent. These are deterministic
/// synthetic event timelines driven through the real Director derive (no mocks)
/// plus the real causal LiveCamera. No GUI, no timing dependence.
private enum A1Trigger {
    static func source(_ duration: Double) -> SourceInfo {
        SourceInfo(width: 1920, height: 1080, fps: 60, duration: duration,
                   backingScale: 1, originX: 0, originY: 0)
    }

    static func derive(_ duration: Double, events: [InputEvent] = []) -> Timeline {
        var tl = Timeline(duration: duration)
        tl.audio.speedRampsAuto = false
        return Director.derive(tl, input: DirectorInput(events: events, source: source(duration)), revision: 1)
    }

    static func scale(_ tl: Timeline, _ t: Double) -> Double { Double(tl.evaluate(at: t).cameraScale) }
}

// R1.1 — one click creates exactly one zoom-in shot.
@Test func a1ClickCreatesOneZoomInShot() {
    let tl = A1Trigger.derive(8, events: [InputEvent(t: 2, kind: .down, x: 700, y: 420)])
    #expect(tl.zoom.count == 1, "expected one shot, got \(tl.zoom.count)")
    #expect(A1Trigger.scale(tl, 2.05) > 1.3, "no zoom response at the click")
}

// R1.2 — a rapid double-trigger at the same spot is one intent, not two shots.
@Test func a1RapidDoubleClickMakesOneShot() {
    let events = [
        InputEvent(t: 2, kind: .down, x: 700, y: 420),
        InputEvent(t: 2.1, kind: .down, x: 703, y: 422),
    ]
    let tl = A1Trigger.derive(9, events: events)
    #expect(tl.zoom.count <= 1, "rapid double click made \(tl.zoom.count) shots")
    #expect(A1Trigger.scale(tl, 2.05) > 1.2)
}

// R1.2 — an entire click burst in one region collapses to a single shot.
@Test func a1ClickBurstMergesIntoOneShot() {
    var events: [InputEvent] = []
    events.reserveCapacity(8)
    for i in 0..<8 {
        let t = 2.0 + Double(i) * 0.12
        let x = Float(700 + (i * 7) % 24)
        let y = Float(420 + (i * 11) % 18)
        events.append(InputEvent(t: t, kind: .down, x: x, y: y))
    }
    let tl = A1Trigger.derive(10, events: events)
    #expect(tl.zoom.count == 1, "burst made \(tl.zoom.count) shots")
}

// R1.3 — incidental pointer movement alone is not intent: no shots, no zoom.
@Test func a1MouseMoveAloneMakesNoZoom() {
    var events: [InputEvent] = []
    events.reserveCapacity(60)
    for i in 0..<60 {
        let t = 1.0 + Double(i) * 0.05
        let x = Float(300 + i * 3)
        let y = Float(200 + i)
        events.append(InputEvent(t: t, kind: .move, x: x, y: y))
    }
    let tl = A1Trigger.derive(8, events: events)
    #expect(tl.zoom.isEmpty, "hover jitter opened \(tl.zoom.count) shots")
    for t in stride(from: 1.0, through: 4.0, by: 0.25) {
        #expect(A1Trigger.scale(tl, t) == 1, "zoomed on move-only input at \(t)")
    }
}

// R1.4 — scroll noise alone is not intent.
@Test func a1ScrollOnlyMakesNoZoom() {
    var events: [InputEvent] = []
    events.reserveCapacity(30)
    for i in 0..<30 {
        let t = 1.0 + Double(i) * 0.04
        let delta: Float = (i % 2 == 0) ? 3 : -3
        events.append(InputEvent(t: t, kind: .scroll, x: 900, y: 500, scrollDelta: delta))
    }
    let tl = A1Trigger.derive(8, events: events)
    #expect(tl.zoom.isEmpty, "scroll noise opened \(tl.zoom.count) shots")
    #expect(A1Trigger.scale(tl, 2.0) == 1)
}

// R1.7 — a real drag inside the shot yields a moving follow target.
@Test func a1DragInsideShotMovesFollowTarget() {
    var events: [InputEvent] = [InputEvent(t: 2, kind: .down, x: 500, y: 420)]
    for i in 0..<14 {
        let t = 2.1 + Double(i) * 0.05
        let x = Float(500 + i * 60)
        let y = Float(420 + i * 8)
        events.append(InputEvent(t: t, kind: .drag, x: x, y: y))
    }
    events.append(InputEvent(t: 2.85, kind: .up, x: 1280, y: 532))
    let tl = A1Trigger.derive(9, events: events)
    #expect(!tl.zoom.isEmpty, "drag produced no shot")
    let following = tl.zoom.filter {
        if case .follow = $0.focus { return true }
        return false
    }
    #expect(following.count == 1, "drag did not produce a follow shot")
    // The .follow shot's aim must come from the recorded drag path, not from
    // the press origin. A single leg holds one fixed pivot by design: moving
    // the centre *inside* the leg would need an extra spring, and every such
    // variant reintroduced a 3.78e8 sub-frame jerk spike in the multi-click
    // stress track (a mission gate). So we assert the settled aim lies inside
    // the drag path's span and away from the click point — not mid-leg travel.
    let aim = tl.evaluate(at: 2.8).cameraCenter
    let click = SIMD2<Float>(500, 420), dragEnd = SIMD2<Float>(1280, 532)
    print("A1 drag shots=\(tl.zoom.count) follow=\(following.count) aim=\(aim)")
    #expect(hypot(Double(aim.x - click.x), Double(aim.y - click.y)) > 20,
            "camera aim stayed on the click origin: \(aim)")
    #expect(aim.x > click.x + 20 && aim.x <= dragEnd.x + 1 &&
            aim.y >= click.y - 1 && aim.y <= dragEnd.y + 1,
            "camera aim outside the recorded drag path: \(aim)")
}

// R1.5 — the live camera ignores pointer motion (and scroll) with no press.
@Test func a1LiveIgnoresMovesAndScroll() {
    var cam = LiveCamera(source: SIMD2(1920, 1080))
    _ = cam.step(to: 1)
    for i in 0..<40 {
        let t = 1.0 + Double(i) * 0.02
        let x = Float(300 + i * 5), y = Float(200 + i)
        cam.ingest(InputEvent(t: t, kind: .move, x: x, y: y))
    }
    for i in 0..<10 {
        let t = 1.9 + Double(i) * 0.02
        cam.ingest(InputEvent(t: t, kind: .scroll, x: 900, y: 500, scrollDelta: 3))
    }
    let f = cam.step(to: 2.5)
    #expect(Double(f.cameraScale) <= 1.001, "live zoomed on move/scroll only: \(f.cameraScale)")
}

// R1.5 — a primary `.down` zooms the live camera.
@Test func a1LiveDownZooms() {
    var cam = LiveCamera(source: SIMD2(1920, 1080))
    _ = cam.step(to: 10)
    cam.ingest(InputEvent(t: 10, kind: .down, x: 600, y: 360))
    let f = cam.step(to: 10.2)
    #expect(Double(f.cameraScale) > 1.1, "live click did not zoom: \(f.cameraScale)")
}

// R1.6 — a `.down` inside zoomInDwell of the previous aim is ignored. Compare
// two identical cameras: one gets a second click 0.1 s later at a different
// spot, the other gets nothing. A working dwell gate makes them identical.
@Test func a1LiveDwellSuppressesRapidSecondAim() {
    var reference = LiveCamera(source: SIMD2(1920, 1080))
    var doubled = reference
    _ = reference.step(to: 10)
    _ = doubled.step(to: 10)
    let first = InputEvent(t: 10, kind: .down, x: 600, y: 360)
    reference.ingest(first); doubled.ingest(first)
    // 0.1 s < zoomInDwell (0.2 s): must not re-aim.
    doubled.ingest(InputEvent(t: 10.1, kind: .down, x: 1500, y: 900))
    let a = reference.step(to: 10.3), b = doubled.step(to: 10.3)
    let dx = Double(abs(a.cameraCenter.x - b.cameraCenter.x))
    let dy = Double(abs(a.cameraCenter.y - b.cameraCenter.y))
    let ds = Double(abs(a.cameraScale - b.cameraScale))
    print("A1 dwell delta center=(\(dx),\(dy)) scale=\(ds)")
    #expect(dx < 0.5 && dy < 0.5 && ds < 1e-3, "rapid second aim was not suppressed")
}

// R1.6 — after the dwell expires a new `.down` at a new spot DOES re-aim.
@Test func a1LiveReaimsAfterDwell() {
    var cam = LiveCamera(source: SIMD2(1920, 1080))
    _ = cam.step(to: 10)
    cam.ingest(InputEvent(t: 10, kind: .down, x: 300, y: 200))
    let early = cam.step(to: 10.5).cameraCenter
    cam.ingest(InputEvent(t: 11.0, kind: .down, x: 1500, y: 900))
    let late = cam.step(to: 11.5).cameraCenter
    #expect(Double(late.x - early.x) > 200, "camera did not re-aim after dwell")
}
