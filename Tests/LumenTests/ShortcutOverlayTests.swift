import Testing
import Foundation
import LumenCore
import LumenProject
import LumenRender

/// Headless overlay tests: pure timeline math and detector logic. No Metal
/// device, no window, no wall clock. A Metal texture is only needed in the
/// renderer hook, which is exercised by the build, not by these tests.
private var plan: ShortcutOverlayPlan {
    var p = ShortcutOverlayPlan(); p.enabled = true; return p
}

@Test func detectsCommandShortcutFromRecordedEvent() {
    let events = [InputEvent(t: 2.0, kind: .keyDown, keyCode: 40, flags: 0x0010)]
    let displays = ShortcutDetector.displays(in: events, plan: plan)
    #expect(displays.count == 1)
    #expect(displays[0].text == "⌘K")
    #expect(displays[0].start == 2.0)
    #expect(displays[0].end == 3.1)
}

@Test func modifierGlyphsUseMacMenuOrder() {
    #expect(ShortcutDetector.modifierPrefix(0x0010) == "⌘")
    #expect(ShortcutDetector.modifierPrefix(0x0012) == "⇧⌘")
    #expect(ShortcutDetector.modifierPrefix(0x001A) == "⌥⇧⌘")
    #expect(ShortcutDetector.modifierPrefix(0x0018) == "⌥⌘")
    #expect(ShortcutDetector.modifierPrefix(0x001E) == "⌃⌥⇧⌘")
}

@Test func glyphsAreCrispSingleCharactersForCommonShortcuts() {
    #expect(ShortcutDetector.glyphString(for: 40) == "K")
    #expect(ShortcutDetector.glyphString(for: 49) == "Space")
    #expect(ShortcutDetector.glyphString(for: 36) == "↩")
    #expect(ShortcutDetector.glyphString(for: 51) == "⌫")
    #expect(ShortcutDetector.glyphString(for: 123) == "←")
    #expect(ShortcutDetector.glyphString(for: 126) == "↑")
    #expect(ShortcutDetector.glyphString(for: 122) == "F1")
    #expect(ShortcutDetector.glyphString(for: 18) == "1")
}

@Test func modifierOnlyEventsNeverRenderAPill() {
    let events = [InputEvent(t: 1, kind: .flagsChanged, keyCode: 55, flags: 0x0010),
                  InputEvent(t: 1.1, kind: .keyDown, keyCode: 0, flags: 0)]
    #expect(ShortcutDetector.displays(in: events, plan: plan).isEmpty)
}

@Test func fastConsecutiveShortcutsReplaceInsteadOfPilingUp() {
    let events = [InputEvent(t: 1.0, kind: .keyDown, keyCode: 40, flags: 0x0010),
                  InputEvent(t: 1.2, kind: .keyDown, keyCode: 11, flags: 0x0010),
                  InputEvent(t: 1.3, kind: .keyDown, keyCode: 15, flags: 0x0010)]
    let displays = ShortcutDetector.displays(in: events, plan: plan, maxStack: 2)
    #expect(displays.count == 3)
    #expect(displays[0].end <= 1.2 + 1e-9, "outgoing pill was not replaced at the new event")
    #expect(displays[1].end <= 1.3 + 1e-9)
    #expect(displays.last?.text == "⌘R")
}

@Test func disabledPlanAndNonCommandKeysRenderNothing() {
    var off = plan; off.enabled = false
    let events = [InputEvent(t: 1, kind: .keyDown, keyCode: 40, flags: 0x0010)]
    #expect(ShortcutDetector.displays(in: events, plan: off).isEmpty)
    #expect(ShortcutDetector.displays(in: [InputEvent(t: 1, kind: .keyDown, keyCode: 40)], plan: plan).isEmpty)
}

@Test func springPoseIsDeterministicBoundedAndFadesToZero() {
    let first = shortcutPose(at: 1.12, start: 1.0, end: 2.1, unit: 1)
    let second = shortcutPose(at: 1.12, start: 1.0, end: 2.1, unit: 1)
    #expect(first == second)
    #expect(shortcutPose(at: 1.0, start: 1.0, end: 2.1).opacity < 0.001)
    let settled = shortcutPose(at: 1.45, start: 1.0, end: 2.1)
    #expect(settled.opacity > 0.98 && settled.opacity <= 1.001)
    var peak = 0.0
    for i in 0...600 {
        let t = 1.0 + Double(i) / 1000.0
        peak = max(peak, shortcutPose(at: t, start: 1.0, end: 2.1).scale)
    }
    #expect(peak <= 1.10, "spring overshoot \(peak) is too large")
    #expect(shortcutPose(at: 2.1, start: 1.0, end: 2.1).opacity < 0.001)
}

@Test func timelineSettingSurvivesAnEmptyAndARoundTripDecode() throws {
    var timeline = Timeline(duration: 2)
    timeline.shortcutOverlay.enabled = true
    timeline.shortcutOverlay.position = .topMiddle
    timeline.shortcutOverlay.holdSeconds = 0.8
    let data = try JSONEncoder().encode(timeline)
    let restored = try JSONDecoder().decode(Timeline.self, from: data)
    #expect(restored.shortcutOverlay == timeline.shortcutOverlay)

    // A project saved before this setting existed has no key at all: defaults
    // must apply, and nothing else in the project may be discarded.
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json.removeValue(forKey: "shortcutOverlay")
    let legacy = try JSONDecoder().decode(Timeline.self,
                                          from: JSONSerialization.data(withJSONObject: json))
    #expect(legacy.shortcutOverlay == ShortcutOverlayPlan())
    #expect(legacy.schemaVersion == timeline.schemaVersion)
}

@Test func overlayTimingSamplesAt60FpsAreStableUnderScrubbing() {
    let events = [InputEvent(t: 1.0, kind: .keyDown, keyCode: 40, flags: 0x0010)]
    let displays = ShortcutDetector.displays(in: events, plan: plan)
    #expect(displays.count == 1)
    for frame in 0...66 {
        let t = 1.0 + Double(frame) / 60.0
        let a = shortcutPose(at: t, start: displays[0].start, end: displays[0].end, unit: 1)
        let b = shortcutPose(at: t, start: displays[0].start, end: displays[0].end, unit: 1)
        #expect(a == b, "frame \(frame) changed between two identical scrubs")
        #expect(a.opacity >= 0 && a.opacity <= 1.001)
        #expect(a.scale > 0.8 && a.scale < 1.1)
    }
}
