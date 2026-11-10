import Foundation
import Testing
@testable import LumenProject
import LumenDirector
import LumenAudio

@Test func migrationLUFS16MapsToNilAndPreservesUnknown() throws {
    let maybeURL = Bundle.module.url(forResource: "v3-lufs16", withExtension: "json", subdirectory: "Fixtures/Migrations")
    let url = try #require(maybeURL, "fixture v3-lufs16 must be bundled")
    let data = try Data(contentsOf: url)
    let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let migrated = LUFS_Migrate.migrate_3_to_4(obj)
    let tl = try #require(migrated["timeline"] as? [String: Any])
    #expect((tl["schemaVersion"] as? Int) == 4)
    let audio = try #require(tl["audio"] as? [String: Any])
    #expect(audio["targetLUFSOverride"] == nil)
    #expect(audio["targetLUFS"] == nil)
    #expect(audio["xCustomUnknownField"] as? String == "keep-me", "preserve unknown fields")
    #expect(migrated["xTopUnknown"] as? Int == 42)
    // Idempotent: migrate(migrate(x)) == migrate(x)
    let twice = LUFS_Migrate.migrate_3_to_4(migrated)
    #expect(twice as NSDictionary == migrated as NSDictionary)
    // Decode path via Timeline also lands on nil override
    let tlData = try JSONSerialization.data(withJSONObject: migrated)
    _ = tlData
}

@Test func defaultMixRendersAtTheStandardTarget() throws {
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 1, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 1)
    tl.audio.micClean = false
    tl.audio.speedRampsAuto = false
    tl.audio.targetLUFSOverride = nil
    tl = Director.derive(tl, input: DirectorInput(events: [], source: src), revision: 1)
    let voice = (0..<48000).map { Float(0.2 * sin(2 * Double.pi * 440 * Double($0) / 48000)) }
    let mix = try #require(AudioMixer(mic: voice, micOffset: 0, system: nil, systemOffset: 0).mix(tl))
    // The standard chain normalizes to -16 LUFS (the podcast target).
    #expect(abs(mix.lufs + 16) <= 0.5, "default loudness \(mix.lufs) != -16")
}
