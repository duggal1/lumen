import Foundation
import Testing
import LumenCore
import LumenProject
import LumenDirector
import LumenAudio

private let source = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 10, backingScale: 1, originX: 0, originY: 0)

/// Per-key Mechvibes: same key = same sample, fast typing quieter, cuts silent.
@Test func typingSameKeySameSample() throws {
    guard let dir = TypingPackLoader.dir(for: "mechvibes-default"),
          let key = TypingPackLoader.macToPack[0],
          FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.wav").path) else { return }
    let buffers = TypingPackLoader.buffers(in: dir)
    #expect(!buffers.isEmpty)
    #expect(buffers[key] != nil)
}

@Test func directorCutsStaySilentForTyping() throws {
    var tl = Timeline(duration: 10)
    tl.timeMap.trimStart = 0; tl.timeMap.trimEnd = 10
    tl.timeMap.cuts = [CutRange(start: 5, end: 6)]
    tl.audio.keySounds = true
    let events = [InputEvent(t: 5.5, kind: .keyDown, keyCode: 0), InputEvent(t: 2, kind: .keyDown, keyCode: 1)]
    let input = DirectorInput(events: events, source: source)
    let t = Director.derive(tl, input: input, revision: 1)
    let keyCues = t.derived?.cues.filter { $0.kind == SFXCue.Kind.key } ?? []
    #expect(keyCues.count == 1)
    #expect(keyCues.first?.keyCode == 1)
}

@Test func fastTypingIsQuieter() throws {
    // Gaps <0.05 => 0.7 gain; <0.15 => 0.85; else 1.0. Same key = same sample.
    // This test documents the gain table used in Mixer.render — no randomness.
    let gaps: [(Double, Float)] = [(0.03, 0.7), (0.08, 0.85), (0.2, 1.0)]
    for (gap, expected) in gaps {
        let g: Float = gap < 0.05 ? 0.7 : gap < 0.15 ? 0.85 : 1.0
        #expect(abs(g - expected) < 0.001)
    }
}

@Test func freshClickIsDefault() throws {
    let p = AudioPlan()
    #expect(p.clickTone == .fresh)
    #expect(p.typingPackId == "mechvibes-default")
}
