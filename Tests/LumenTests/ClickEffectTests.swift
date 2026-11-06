import Foundation
import Testing
import LumenCore
import LumenProject
import LumenDirector

@Test func clickEffectVisibilityAndDurationFollowSavedCursorPreferences() {
    let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 4,
                            backingScale: 2, originX: 0, originY: 0)
    let events = [InputEvent(t: 1, kind: .down, x: 700, y: 350)]
    var timeline = Timeline(duration: 4)
    timeline.audio.speedRampsAuto = false
    timeline.cursor.clickDuration = 0.8
    timeline.cursor.clickEffect = .ripple
    timeline = Director.derive(timeline, input: DirectorInput(events: events, source: source), revision: 1)
    #expect(timeline.evaluate(at: 1.7).clickFX.count == 1)

    timeline.cursor.clickEffect = .none
    #expect(timeline.evaluate(at: 1.1).clickFX.isEmpty)

    timeline.cursor.clickEffect = .pulse
    timeline.cursor.clickDuration = 0.15
    #expect(timeline.evaluate(at: 1.3).clickFX.isEmpty)
}
