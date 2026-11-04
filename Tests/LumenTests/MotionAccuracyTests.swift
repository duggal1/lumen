import Testing
import LumenCore
import LumenProject
import LumenDirector

private func motionTimeline(_ events: [InputEvent]) -> Timeline {
    let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 8, backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 8)
    timeline.audio.speedRampsAuto = false
    return Director.derive(timeline, input: DirectorInput(events: events, source: source), revision: 1)
}

@Test func automaticZoomAnticipatesClickAndArrivesOnTime() {
    let timeline = motionTimeline([InputEvent(t: 2, kind: .down, x: 700, y: 400)])
    #expect(timeline.zoom.count == 1)
    #expect(timeline.zoom[0].start < 2)
    #expect(timeline.zoom[0].start >= 1.7)
    #expect(abs(timeline.evaluate(at: 1.5).cameraScale - 1) < 0.001)
    #expect(timeline.evaluate(at: 2.1).cameraScale > 1.6)
}

@Test func unanchoredActivityDoesNotZoom() {
    let timeline = motionTimeline([InputEvent(t: 2, kind: .scroll, x: 700, y: 400), InputEvent(t: 3, kind: .keyDown)])
    #expect(timeline.zoom.isEmpty)
}

@Test func distinctTargetsDoNotMergeIntoEmptySpace() {
    let timeline = motionTimeline([InputEvent(t: 2, kind: .down, x: 500, y: 400), InputEvent(t: 3, kind: .down, x: 1000, y: 400)])
    #expect(timeline.zoom.count == 2)
}
