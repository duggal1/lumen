import Foundation
import Testing
import LumenProject
import LumenDirector
import LumenAudio

@Test(arguments: [false, true])
func replacedImportedAudioInvalidatesLiveAndDiskMixCache(legacyMusic: Bool) throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("lumen-cache-proof-" + UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let path = dir.appendingPathComponent("input.caf")
    let cache = dir.appendingPathComponent("cache")
    let source = SourceInfo(width: 640, height: 360, fps: 60, duration: 1,
                            backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 1)
    timeline.audio.speedRampsAuto = false
    timeline.audio.normalize = false
    timeline.audio.soundEffectsEnabled = false
    if legacyMusic {
        timeline.audio.musicPath = path.path
    } else {
        timeline.audio.lanes = [AudioLane(role: .voiceover, path: path.path)]
    }
    timeline = Director.derive(timeline, input: DirectorInput(events: [], source: source), revision: 1)
    func signal(_ hz: Double, count: Int) -> [Float] {
        (0..<count).map { Float(0.1 * sin(2 * Double.pi * hz * Double($0) / AudioIO.fs)) }
    }
    let first = signal(330, count: 48_000)
    try AudioIO.writeCAF(first, first, to: path)
    let mixer = AudioMixer(mic: nil, micOffset: 0, system: nil, systemOffset: 0, cacheDir: cache)
    let old = try #require(mixer.mix(timeline))
    let second = signal(660, count: 72_000)
    let replacement = dir.appendingPathComponent("replacement.caf")
    try AudioIO.writeCAF(second, second, to: replacement)
    _ = try fm.replaceItemAt(path, withItemAt: replacement)
    let updated = try #require(mixer.mix(timeline))
    let independent = AudioMixer(mic: nil, micOffset: 0, system: nil, systemOffset: 0)
    let expected = try #require(independent.mix(timeline))
    #expect(old.l != updated.l)
    #expect(updated.l == expected.l)
    let reopened = AudioMixer(mic: nil, micOffset: 0, system: nil, systemOffset: 0, cacheDir: cache)
    let restored = try #require(reopened.mix(timeline))
    #expect(restored.l.count == expected.l.count)
    #expect(zip(restored.l, expected.l).allSatisfy { abs($0.0 - $0.1) < 0.000001 })
}
