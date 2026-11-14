import Foundation
import Testing
import LumenCore
import LumenProject
import LumenDirector
import LumenRender

@Test func clickFocusIgnoresLargePopupAXFrameCenter() {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 6, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 6)
    tl.audio.speedRampsAuto = false
    let click = InputEvent(t: 2, kind: .down, x: 800, y: 300, axFrameIndex: 1)
    let popup = AXFrame(x: 200, y: 100, w: 400, h: 200)
    tl = Director.derive(tl, input: DirectorInput(events: [click], source: src, ax: [popup]), revision: 1)
    #expect(tl.zoom.count == 1)
    if case .fixed(let x, let y) = tl.zoom[0].focus {
        #expect(abs(x - 800.0 / 1920) < 0.001)
        #expect(abs(y - 300.0 / 1080) < 0.001)
    } else {
        Issue.record("Expected popup auto zoom to anchor on the click")
    }
}

@Test func oversizedPopupDoesNotForceCursorFollow() {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 6, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 6)
    tl.audio.speedRampsAuto = false
    let click = InputEvent(t: 2, kind: .down, x: 850, y: 300, axFrameIndex: 1)
    let popup = AXFrame(x: 0, y: 0, w: 960, h: 540)
    tl = Director.derive(tl, input: DirectorInput(events: [click], source: src, ax: [popup]), revision: 1)
    #expect(tl.zoom.count == 1)
    if case .fixed(let x, let y) = tl.zoom[0].focus {
        #expect(abs(x - 850.0 / 1920) < 0.001)
        #expect(abs(y - 300.0 / 1080) < 0.001)
    } else {
        Issue.record("Oversized popup should not switch fixed click focus to follow")
    }
}

@Test func twentyFourClicksStayInsideZoomViewport() {
    let source = SIMD2<Double>(1920, 1080)
    let positions: [SIMD2<Double>] = [
        SIMD2(0,0), SIMD2(1920,0), SIMD2(0,1080), SIMD2(1920,1080),
        SIMD2(960,540), SIMD2(50,20), SIMD2(1870,20), SIMD2(50,1060),
        SIMD2(1870,1060), SIMD2(960,25), SIMD2(960,1055), SIMD2(20,540),
        SIMD2(1900,540), SIMD2(250,100), SIMD2(500,200), SIMD2(750,300),
        SIMD2(1000,400), SIMD2(1250,500), SIMD2(1500,600), SIMD2(1750,700),
        SIMD2(350,800), SIMD2(600,950), SIMD2(900,700), SIMD2(1300,900)
    ]
    for point in positions {
        let geo = ZoomTransform(canvas: SIMD2(1920,1080), source: source, style: Style(),
                                cameraCenter: point, scale: 2.2)
        let v = geo.viewport
        #expect(point.x >= v.x - 0.0001)
        #expect(point.x <= v.x + v.z + 0.0001)
        #expect(point.y >= v.y - 0.0001)
        #expect(point.y <= v.y + v.w + 0.0001)
    }
}

@Test func autoZoomReachesNinetyFivePercentNearClick() {
    let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 6, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 6)
    tl.audio.speedRampsAuto = false
    tl = Director.derive(tl, input: DirectorInput(events: [InputEvent(t: 2, kind: .down, x: 960, y: 540)], source: source), revision: 1)
    #expect(tl.zoom.count == 1)
    let target = tl.zoom[0].scale
    // The planner anticipates; scale is full at the interaction, not 600 ms later.
    #expect(tl.evaluate(at: 2.05).cameraScale >= Float(1 + (target - 1) * 0.95))
}

@Test func cachedRecordingZoomMatchesFreshDeterministicDirectorPlan() {
    let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 8,
                            backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 8)
    timeline.audio.speedRampsAuto = false
    let events = [
        InputEvent(t: 2, kind: .down, x: 500, y: 350),
        InputEvent(t: 5, kind: .down, x: 1400, y: 650),
    ]
    let cached = Director.planRecordingZoom(events: events, ax: [],
                                            source: source, timeline: timeline)
    #expect(!cached.isEmpty)
    #expect(cached == Director.planRecordingZoom(events: events, ax: [],
                                                  source: source, timeline: timeline))
    timeline.zoom = cached
    let fresh = Director.derive(timeline,
                                input: DirectorInput(events: events, source: source), revision: 1)
    #expect(fresh.zoom == cached)
}

private func visualDemoInput(tiny: Bool = false, scroll: Bool = false) -> DirectorInput {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 12, backingScale: 1, originX: 0, originY: 0)
    let rect = tiny ? CGRect(x: 1400, y: 600, width: 16, height: 16)
                    : CGRect(x: 1100, y: 500, width: 500, height: 280)
    let points = (0..<6).map { i in
        ActivityPoint(t: 6 + Double(i) * 0.1, x: rect.midX, y: rect.midY,
                      region: rect, coverage: tiny ? 0.001 : 0.025)
    }
    var events = [InputEvent(t: 1, kind: .move, x: 100, y: 100)]
    if scroll { events.append(InputEvent(t: 6.2, kind: .scroll, x: 100, y: 100)) }
    return DirectorInput(events: events, source: src, activity: points)
}

@Test func autonomousVisualZoomWorksWithMouseEventsButNoClick() {
    var tl = Timeline(duration: 12)
    tl.audio.speedRampsAuto = false
    let out = Director.derive(tl, input: visualDemoInput(), revision: 1)
    #expect(out.zoom.count == 1)
    #expect(out.zoom.first?.start == 6)
    #expect(out.zoom.first?.scale ?? 0 <= 1.6)
    #expect(out.evaluate(at: 6.7).cameraScale > 1.3)
    #expect(out.evaluate(at: 6.7).cameraCenter.x > 1100)
}

@Test func autonomousVisualZoomIgnoresSpinnersAndScrolling() {
    var tl = Timeline(duration: 12)
    tl.audio.speedRampsAuto = false
    #expect(Director.derive(tl, input: visualDemoInput(tiny: true), revision: 1).zoom.isEmpty)
    #expect(Director.derive(tl, input: visualDemoInput(scroll: true), revision: 2).zoom.isEmpty)
}

@Test func autonomousVisualZoomPreservesManualShotsAndOffSetting() {
    var tl = Timeline(duration: 12)
    tl.audio.speedRampsAuto = false
    let manual = ZoomSegment(start: 5, end: 9, scale: 1.4, focus: .fixed(x: 0.5, y: 0.5), origin: .manual)
    tl.zoom = [manual]
    let out = Director.derive(tl, input: visualDemoInput(), revision: 1)
    #expect(out.zoom.map(\.id) == [manual.id])
    tl.zoom = []; tl.camera.autoZoom = false
    #expect(Director.derive(tl, input: visualDemoInput(), revision: 2).zoom.isEmpty)
}

@Test func autonomousVisualActivityPreventsIdleSpeedRampAcrossResult() {
    let input = visualDemoInput()
    let out = Director.derive(Timeline(duration: 12), input: input, revision: 1)
    #expect(!out.timeMap.ramps.contains { $0.start < 6.25 && $0.end > 6.25 })
}
