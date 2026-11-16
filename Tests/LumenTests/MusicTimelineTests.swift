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
// ("FREE | Orchestral ... [videoId]"). These tests fail if either regresses.

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
    // The strip stacks ruler, clip, zoom, events, audio (voice), music.
    #expect(TimelineStrip.Lanes.music == 184)
    #expect(TimelineStrip.Lanes.audio == 144)
    #expect(TimelineStrip.Lanes.music > TimelineStrip.Lanes.audio)
    #expect(TimelineStrip.Lanes.total == 224)
}

@Test func bundledMusicTitlesAreRealAndConcise() {
    let music = BundledAudioAssets.music
    #expect(music.count >= 15)
    for track in music {
        // No raw dump markers may survive into a title.
        #expect(!track.title.contains("["), "\(track.title) still has a bracket")
        #expect(!track.title.lowercased().contains("free"), "\(track.title) starts with FREE")
        #expect(!track.title.lowercased().contains("no copyright"))
        #expect(!track.title.lowercased().contains("royalty"))
        #expect(!track.title.contains("⧸"))
        #expect(!track.title.contains("｜"))
        #expect(track.title.count <= 24, "\(track.title) too long")
        #expect(!track.title.isEmpty)
    }
    // A few curated titles prove the map is applied.
    let titles = Set(music.map(\.title))
    #expect(titles.contains("Majestic Hills"))
    #expect(titles.contains("Juniper"))
    #expect(titles.contains("Echoes in the Dark"))
}

@Test func musicNamesResolveFromPathToCuratedTitle() {
    let path = "/assets/music/calm/Majestic Hills - Kevin MacLeod [USUAN1100423].mp3"
    let name = TimelineStrip.musicName(path)
    #expect(name == "Majestic Hills")
}

@Test func cleanStemDropsIdsAndCopyrightTails() {
    #expect(BundledAudioAssets.cleanStem("Some Song [abc123]") == "Some Song")
    #expect(BundledAudioAssets.cleanStem("Song Name - Artist [USUAN1100186]") == "Song Name")
    #expect(BundledAudioAssets.cleanStem("   ") == "Untitled")
}

// MARK: Cursor skins
//
// Skins must be genuinely different shapes, not the same pointer recolored.
// The stylized packs (dot, ring, holiday, pixel, outline) replace the pointer
// outright; the ink packs keep the pointer identity and only change ink.

@Test func newCursorSkinsExist() {
    let packs = CursorPack.allCases
    #expect(packs.contains(.pixel))
    #expect(packs.contains(.outline))
    #expect(packs.contains(.ember))
    #expect(packs.contains(.mono))
}

@Test func pixelAndOutlineAreShapeOverrides() {
    #expect(CursorPack.pixel.preservesShape == false)
    #expect(CursorPack.outline.preservesShape == false)
    #expect(CursorPack.dot.preservesShape == false)
    // Ink packs keep the recorded pointer identity.
    #expect(CursorPack.lavender.preservesShape == true)
    #expect(CursorPack.ember.preservesShape == true)
    #expect(CursorPack.system.preservesShape == true)
}

@Test func cursorSkinPreviewsRasterize() {
    for pack in [CursorPack.pixel, CursorPack.outline, CursorPack.ember, CursorPack.mono] {
        let img = CursorAtlas.previewImage(pack: pack)
        #expect(img != nil, "\(pack) preview missing")
    }
}

// MARK: Click sound grid

@Test func clickSoundTitlesAreShort() {
    for tone in ClickSound.allCases {
        let title = ClickSoundGrid.title(tone)
        #expect(!title.isEmpty)
        #expect(title.count <= 8, "\(title) too long")
    }
}

@Test func clickSoundCombNormalizesPeaks() {
    let pcm: [Float] = [0, 0.5, 0, 1, 0, 0.25, 0, 0]
    let comb = ClickSoundGrid.combed(pcm, buckets: 8)
    #expect(comb.count == 8)
    #expect(abs(comb.reduce(Float(0)) { max($0, $1) } - 1.0) < 0.001)
}

@Test func musicCombNormalizesPeaks() {
    let pcm = (0..<100).map { Float(sin(Double($0) * 0.3)) }
    let comb = MusicPicker.combed(pcm, buckets: 20)
    #expect(comb.count == 20)
    #expect(comb.allSatisfy { $0 >= 0 && $0 <= 1.0001 })
}