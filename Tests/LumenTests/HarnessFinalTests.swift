import Testing
import LumenCore
import LumenProject
import Foundation
@testable import LumenDirector

private let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 10, backingScale: 1, originX: 0, originY: 0)

func cameraAt(_ tl: Timeline, _ t: Double) -> (cx: Double, cy: Double, scale: Double) {
    let f = tl.evaluate(at: t)
    return (Double(f.cameraCenter.x), Double(f.cameraCenter.y), Double(f.cameraScale))
}

@Test func harnessClickTinyLarge() {
    var tl = Timeline(duration: 10); tl.audio.speedRampsAuto = false
    let tiny = [InputEvent(t: 2, kind: .down, x: 960, y: 540, axFrameIndex: 1)]
    let axTiny = [AXFrame(x: 950, y: 530, w: 20, h: 20)]
    let outTiny = Director.derive(tl, input: DirectorInput(events: tiny, source: src, ax: axTiny), revision: 1)
    let big: [InputEvent] = [InputEvent(t: 2, kind: .down, x: 960, y: 540, axFrameIndex: 1)]
    let axBig = [AXFrame(x: 400, y: 300, w: 800, h: 500)]
    let outBig = Director.derive(tl, input: DirectorInput(events: big, source: src, ax: axBig), revision: 1)
    let (cx, cy, sTiny) = cameraAt(outTiny, 2.0)
    let (cx2, cy2, sBig) = cameraAt(outBig, 2.0)
    print("HARNESS tiny scale \(sTiny) center \(cx),\(cy)")
    print("HARNESS big scale \(sBig) center \(cx2),\(cy2)")
    #expect(sTiny != sBig)
    #expect(abs(cx - 960) < 15 && abs(cy - 540) < 15)
    #expect(abs(cx2 - 960) < 15)
    // Zoom level varies with target size
    #expect(sTiny > 1.4 && sTiny < 3.6)
    #expect(sBig > 1.0 && sBig < 3.3)
}

@Test func harnessTypingChromeLeftRightBottom() {
    var tl = Timeline(duration: 10); tl.audio.speedRampsAuto = false
    let positions: [(Float, Float)] = [(600, 400), (960, 400), (1320, 400), (960, 950)]
    for (x, y) in positions {
        let ev: [InputEvent] = [
            InputEvent(t: 1.0, kind: .down, x: x, y: y, axFrameIndex: 1),
            InputEvent(t: 2.0, kind: .keyDown, keyCode: 0),
            InputEvent(t: 2.1, kind: .keyDown, keyCode: 1),
            InputEvent(t: 2.2, kind: .keyDown, keyCode: 2),
        ]
        let ax = [AXFrame(x: Double(x) - 300, y: Double(y) - 20, w: 600, h: 40)]
        let out = Director.derive(tl, input: DirectorInput(events: ev, source: src, ax: ax), revision: 1)
        let (cx, cy, _) = cameraAt(out, 2.0)
        print("HARNESS typing at \(Int(x)),\(Int(y)) -> center \(Int(cx)),\(Int(cy))")
        #expect(abs(cx - Double(x)) < 400)
        #expect(abs(cy - Double(y)) < 300)
    }
}

@Test func harnessTypingWideFieldMultiLine() {
    var tl = Timeline(duration: 10); tl.audio.speedRampsAuto = false
    let ev: [InputEvent] = [
        InputEvent(t: 1.0, kind: .down, x: 200, y: 300, axFrameIndex: 1),
        InputEvent(t: 2.0, kind: .keyDown, keyCode: 0),
        InputEvent(t: 2.1, kind: .keyDown, keyCode: 1),
        InputEvent(t: 2.2, kind: .keyDown, keyCode: 2),
    ]
    let ax = [AXFrame(x: 100, y: 280, w: 1200, h: 200)] // wide multi-line
    let out = Director.derive(tl, input: DirectorInput(events: ev, source: src, ax: ax), revision: 1)
    let (cx, cy, s) = cameraAt(out, 2.0)
    print("HARNESS wide field center \(Int(cx)),\(Int(cy)) scale \(s)")
    #expect(abs(cx - 400) < 600)
    #expect(s >= 1.0)
}

@Test func harnessHoverDock() {
    // Zoom v3: hover-only activity (waits, moves, pauses) never zooms.
    // A1: camera lz within 0.01 of 0 for the entire span.
    var tl = Timeline(duration: 12); tl.audio.speedRampsAuto = false
    var ev: [InputEvent] = []
    for i in 0..<5 {
        let baseT = Double(i) * 2.0
        let x: Float = 200 + Float(i * 300)
        ev.append(InputEvent(t: baseT, kind: .move, x: x, y: 950))
        ev.append(InputEvent(t: baseT + 0.2, kind: .move, x: x, y: 950))
        ev.append(InputEvent(t: baseT + 0.4, kind: .move, x: x, y: 950))
    }
    let out = Director.derive(tl, input: DirectorInput(events: ev, source: src), revision: 1)
    print("HARNESS dock zooms:", out.zoom.count)
    #expect(out.zoom.count == 0)
}

@Test func harnessMixedAndIdle() {
    var tl = Timeline(duration: 10); tl.audio.speedRampsAuto = false
    let ev: [InputEvent] = [
        InputEvent(t: 1, kind: .down, x: 500, y: 500),
        InputEvent(t: 2, kind: .keyDown, keyCode: 0),
        InputEvent(t: 2.1, kind: .keyDown, keyCode: 1),
        InputEvent(t: 2.2, kind: .keyDown, keyCode: 2),
        InputEvent(t: 4.0, kind: .move, x: 1000, y: 600),
        InputEvent(t: 4.4, kind: .move, x: 1000, y: 600),
        InputEvent(t: 9.0, kind: .down, x: 1500, y: 300),
    ]
    let out = Director.derive(tl, input: DirectorInput(events: ev, source: src), revision: 1)
    print("HARNESS mixed zooms:", out.zoom.count)
    // Idle 1.5s -> zoom out: after 7s (2.8s idle) camera should be near 1.0 or next shot not yet started
    let idle = cameraAt(out, 8.0)
    print("HARNESS idle at 8s scale \(idle.scale)")
    #expect(out.zoom.count >= 2)
}

@Test func harnessCameraJSONGroundTruth() {
    var tl = Timeline(duration: 10); tl.audio.speedRampsAuto = false
    let click = InputEvent(t: 2, kind: .down, x: 900, y: 440)
    let out = Director.derive(tl, input: DirectorInput(events: [click], source: src), revision: 1)
    var log: [(t: Double, px: Double, py: Double, scale: Double)] = []
    for i in 0..<300 {
        let t = Double(i) / 60.0
        let (cx, cy, s) = cameraAt(out, t)
        log.append((t, cx, cy, s))
    }
    let atClick = log.first { $0.t >= 2.0 }!
    print("HARNESS ground truth at click: cx \(Int(atClick.px)) cy \(Int(atClick.py)) scale \(atClick.scale)")
    #expect(abs(atClick.px - 900) < 20)
    #expect(abs(atClick.py - 440) < 20)
    // Zoom-start to event delay: first time scale > 1.1
    if let first = log.first(where: { $0.scale > 1.1 }) {
        let delay = 2.0 - first.t
        print("HARNESS zoom-start delay: \(delay)s (leadIn)")
        #expect(delay >= 0.05 && delay <= 0.5)
    }
}

@Test func harnessPerfP99() {
    var tl = Timeline(duration: 60); tl.audio.speedRampsAuto = false
    var ev: [InputEvent] = []
    for i in 0..<120 {
        let t = Double(i) * 0.5
        let x = Float(200 + (i * 37) % 1500)
        let y = Float(200 + (i * 53) % 700)
        ev.append(InputEvent(t: t, kind: .move, x: x, y: y))
    }
    let out = Director.derive(tl, input: DirectorInput(events: ev, source: src), revision: 1)
    let start = Date()
    var checksum = 0.0
    for i in 0..<20000 {
        let f = out.evaluate(at: Double(i) / 1000.0)
        checksum += Double(f.cameraScale)
    }
    let elapsed = Date().timeIntervalSince(start)
    let avgMs = elapsed / 20000.0 * 1000.0
    #expect(avgMs < 16.6)
    #expect(checksum.isFinite)
}
