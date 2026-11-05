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
        (.click, .mouse), (.click, .subtle), (.key, .mouse),
        (.whooshIn, .mouse), (.whooshOut, .mouse),
    ]
    for (kind, tone) in cues {
        let (samples, gain) = bank.render(kind, clickTone: tone)
        #expect(!samples.isEmpty)
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        #expect(peak > 0.5)
        #expect(gain == 0)
    }
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
