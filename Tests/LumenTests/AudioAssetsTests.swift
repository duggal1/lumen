import Testing
import Foundation
import LumenAudio
import LumenProject

/// Lumen ships recorded MP3s and never synthesizes effects. These tests fail
/// when an asset is missing or a cue silently renders nothing, which is how a
/// procedural fallback would creep back in unnoticed.
@Test func bundledEffectsAreRealRecordedAudio() {
    let bank = SFXBank()
    let cues: [(SFXCue.Kind, ClickSound)] = [
        (.click, .mouse), (.click, .subtle), (.click, .fresh),
    ]
    for (kind, tone) in cues {
        let (samples, gain) = bank.render(kind, clickTone: tone)
        #expect(!samples.isEmpty)
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        #expect(peak > 0.5)
        #expect(gain == 0)
    }
    // Production uses the actual A-key recording, not a generic tap fallback.
    let (keySamples, _) = bank.render(.key, clickTone: .mouse)
    #expect(!keySamples.isEmpty)
    #expect(keySamples.reduce(Float(0)) { max($0, abs($1)) } > 0.0001)
}

@Test func bundledMusicLibraryIsPresent() {
    let music = BundledAudioAssets.music
    #expect(music.count >= 15)
    for track in music {
        #expect(FileManager.default.fileExists(atPath: track.url.path))
        #expect(!track.title.isEmpty)
    }
    #expect(Set(music.map(\.category)) == ["calm", "epic", "futuristic", "tension", "upbeat"])
}

@Test func touchSoundsAreBundledPlayableAndPersisted() throws {
    let bank = SFXBank()
    let choices = ClickSound.allCases.filter { ![.mouse, .subtle, .fresh].contains($0) && !ClickSound.studioCollection.contains($0) }
    #expect(ClickSound.activeCollection.count == 4)
    for sound in choices {
        let (samples, _) = bank.render(.click, clickTone: sound)
        #expect(!samples.isEmpty)
        var plan = AudioPlan(); plan.clickTone = sound
        let saved = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(AudioPlan.self, from: saved).clickTone == sound)
    }
}

@Test func curatedCursorSoundsDecodeAndAreDistinct() throws {
    let bank = SFXBank()
    var samplesSeen = Set<[Float]>()
    #expect(ClickSound.studioCollection.count == 3)
    for sound in ClickSound.studioCollection {
        let url = try #require(BundledAudioAssets.effect(named: sound.assetPath))
        let original = try AudioIO.readMono(url)
        let samples = bank.render(.click, clickTone: sound).samples
        #expect(!samples.isEmpty)
        #expect(samples.count == original.count)
        #expect(samples.count >= 960 && samples.count <= 12000)
        let allSamplesFinite = samples.allSatisfy { $0.isFinite }
        #expect(allSamplesFinite)
        #expect(samplesSeen.insert(samples).inserted)
        #expect(samples == original)
        #expect(samples.reduce(Float(0)) { max($0, abs($1)) } <= 0.41)
        var plan = AudioPlan(); plan.clickTone = sound
        #expect(try JSONDecoder().decode(AudioPlan.self, from: JSONEncoder().encode(plan)).clickTone == sound)
    }
}
