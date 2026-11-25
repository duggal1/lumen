import Foundation
import Testing
import LumenCore
import LumenProject
import LumenDirector
import LumenAudio

private let reconstructionSource = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 8,
                                             backingScale: 1, originX: 0, originY: 0)

@Test func reconstructionAutoZoomOffPreservesManualEdits() {
    var timeline = Timeline(duration: 8)
    timeline.audio.speedRampsAuto = false
    timeline.camera.autoZoom = false
    let manual = ZoomSegment(start: 4, end: 6, scale: 1.5, focus: .fixed(x: 0.5, y: 0.5), origin: .manual)
    timeline.zoom = [ZoomSegment(start: 1, end: 3, scale: 2, focus: .follow, origin: .auto), manual]
    let input = DirectorInput(events: [], source: reconstructionSource)
    #expect(Director.planRecordingZoom(events: [], ax: [], source: reconstructionSource, timeline: timeline) == [manual])
    #expect(Director.derive(timeline, input: input, revision: 1).zoom == [manual])
}

@Test func reconstructionSuppressionSurvivesStopTimePlanner() {
    var timeline = Timeline(duration: 8)
    timeline.audio.speedRampsAuto = false
    let events = [InputEvent(t: 2, kind: .down, x: 600, y: 350)]
    let automatic = Director.planRecordingZoom(events: events, ax: [], source: reconstructionSource, timeline: timeline)
    #expect(!automatic.isEmpty)
    timeline.suppressedAuto = automatic.map { $0.id.uuidString }
    #expect(Director.planRecordingZoom(events: events, ax: [], source: reconstructionSource, timeline: timeline).isEmpty)
}

@Test func reconstructionSecureKeyPressAndReleaseDoNotBecomeCues() {
    var timeline = Timeline(duration: 8)
    timeline.audio.speedRampsAuto = false
    timeline.audio.keySounds = true
    timeline.audio.soundEffectsEnabled = true
    let events = [InputEvent(t: 1, kind: .keyDown, keyCode: 0, axFrameIndex: 1),
                  InputEvent(t: 1.1, kind: .keyUp, keyCode: 0)]
    let secure = AXFrame(x: 10, y: 10, w: 300, h: 40, secure: true)
    let out = Director.derive(timeline, input: DirectorInput(events: events, source: reconstructionSource, ax: [secure]), revision: 1)
    #expect((out.derived?.cues ?? []).filter { $0.kind == .key }.isEmpty)
}

@Test func reconstructionMalformedTimeMapDoesNotTrap() {
    var tm = TimeMap(sourceDuration: 8)
    #expect(tm.output(atSource: Double.greatestFiniteMagnitude).isFinite)
    #expect(tm.source(atOutput: .nan).isFinite)
    tm.trimEnd = .infinity
    #expect(tm.outputDuration == 0)
}
