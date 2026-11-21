import Testing
import Foundation
import LumenAudio
import LumenProject
import LumenRender
@testable import LumenUI

// MARK: Music timeline + naming
//
// The music bed must be visible on the timeline (a lane of its own), and the
// library must present real, concise titles instead of the raw YouTube dump
// ("FREE | Orchestral ... [videoId]").

@Test func musicLaneGeometryPlacesTrackAtRealTime() {
    let lane = AudioLane(role: .music, path: "/tmp/a.mp3", placement: 12, gainDb: -18)
    #expect(lane.role == .music)
    #expect(lane.placement == 12)
    // A track with an explicit length trims to it.
    var trimmed = lane
    trimmed.trimDuration = 8
    #expect(trimmed.trimDuration == 8)
}

@Test func musicLaneSitsBelowAudioAndAboveBottom() {
    #expect(TimelineStrip.Lanes.music == 184)
    #expect(TimelineStrip.Lanes.audio == 144)
    #expect(TimelineStrip.Lanes.music > TimelineStrip.Lanes.audio)
    #expect(TimelineStrip.Lanes.total == 224)
}

@Test func bundledMusicTitlesAreRealAndConcise() {
    let music = BundledAudioAssets.music
    #expect(music.count >= 15)
    for track in music {
        #expect(!track.title.contains("["), "\(track.title) still has a bracket")
        #expect(!track.title.lowercased().contains("free"), "\(track.title) starts with FREE")
        #expect(!track.title.lowercased().contains("no copyright"))
        #expect(!track.title.lowercased().contains("royalty"))
        #expect(!track.title.contains("⧸"))
        #expect(!track.title.contains("｜"))
        #expect(track.title.count <= 24, "\(track.title) too long")
        #expect(!track.title.isEmpty)
    }
    let titles = Set(music.map(\.title))
    #expect(titles.contains("Majestic Hills"))
    #expect(titles.contains("Juniper"))
    #expect(titles.contains("Echoes in the Dark"))
}

@MainActor @Test func musicNamesResolveFromPathToCuratedTitle() {
    let path = "/assets/music/calm/Majestic Hills - Kevin MacLeod [USUAN1100423].mp3"
    let name = TimelineStrip.musicName(path)
    #expect(name == "Majestic Hills")
}

@Test func cleanStemDropsIdsAndCopyrightTails() {
    #expect(BundledAudioAssets.cleanStem("Some Song [abc123]") == "Some Song")
    #expect(BundledAudioAssets.cleanStem("Song Name - Artist [USUAN1100186]") == "Song Name")
    #expect(BundledAudioAssets.cleanStem("   ") == "Untitled")
}
