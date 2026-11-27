import Testing
import Foundation
import LumenCore
import LumenProject
import LumenAudio

/// Headless acceptance tests for the CC0 sound engine. No audio engine is
/// started, no window opens, no sound is played: everything is offline DSP.
private let library = KeySoundLibrary.load()

@Test func keyClassMappingCoversEverySpecialKey() {
    #expect(KeyClass.forCode(49) == .space)
    #expect(KeyClass.forCode(36) == .enter)
    #expect(KeyClass.forCode(76) == .enter)
    #expect(KeyClass.forCode(51) == .backspace)
    #expect(KeyClass.forCode(117) == .backspace)
    #expect(KeyClass.forCode(56) == .shift)
    #expect(KeyClass.forCode(60) == .shift)
    for code in [54, 55, 58, 59, 61, 62, 63] {
        #expect(KeyClass.forCode(code) == .modifier, "modifier \(code) fell through")
    }
    #expect(KeyClass.forCode(0) == .alpha)
    #expect(KeyClass.forCode(18) == .number)
    #expect(KeyClass.forCode(123) == .nav)
    #expect(KeyClass.forCode(96) == .fn)
}

@Test func soundLibraryHasRealRecordedVariantsPerClass() {
    #expect(!library.isEmpty)
    for keyClass in KeyClass.allCases where keyClass != .click {
        let downs = library.down[keyClass] ?? []
        let ups = library.up[keyClass] ?? []
        #expect(downs.count >= 5, "\(keyClass) has \(downs.count) down takes, need 5")
        #expect(ups.count >= 4, "\(keyClass) has \(ups.count) up takes, need 4")
        // Releases must be playable, not merely present in the raw inventory:
        // a catalog entry without recorded release evidence is gated silent.
        let playableUps = library.takes(keyClass, .up)
        #expect(playableUps.count >= 4, "\(keyClass) has \(playableUps.count) playable releases")
        #expect(Set(downs.map(\.id)).count == downs.count, "duplicate down take in \(keyClass)")
        for take in downs + ups {
            #expect(!take.samples.isEmpty)
            #expect(take.samples.allSatisfy { $0.isFinite && abs($0) <= 1.0 })
        }
    }
    #expect(library.clicks.count >= 4)
}

@Test func roundRobinCyclesEveryVariantAndStaysDeterministic() {
    var first = KeyVariationRouter()
    var second = KeyVariationRouter()
    let expected = [0, 1, 2, 3, 4, 0, 1, 2, 3, 4, 0, 1]
    let got = (0..<12).map { _ in first.next(.alpha, phase: .down, key: 0, variantCount: 5)?.variant }
    #expect(got == expected)
    // Two fresh routers with the same seed must agree; `first` has already
    // advanced its PRNG by the round-robin check above.
    var third = KeyVariationRouter()
    for _ in 0..<12 {
        let a = third.next(.space, phase: .up, key: 49, variantCount: 4)
        let b = second.next(.space, phase: .up, key: 49, variantCount: 4)
        #expect(a == b, "variation router is not deterministic")
    }
}

@Test func variationJitterStaysInsideSmallBounds() {
    var router = KeyVariationRouter()
    for i in 0..<200 {
        guard let v = router.next(i % 2 == 0 ? .alpha : .shift, phase: .down,
                                  key: i % 128, variantCount: 5) else { continue }
        #expect(abs(v.pitchCents) <= KeyVariationRouter.pitchRangeCents + 1e-9)
        #expect(abs(v.gainDb) <= KeyVariationRouter.gainRangeDb + 1e-9)
    }
}

@Test func cuePlacementIsSampleAccurate() {
    var synthetic = KeySoundLibrary()
    let impulse: [Float] = [0, 0, 0, 1, 0]
    synthetic.down[.space] = [KeyTake(id: "impulse", samples: impulse)]
    var router = KeyVariationRouter()
    let out = KeySoundEngine.render(cues: [SFXCue(t: 0.25, kind: .key, gainDb: -60, keyCode: 49)],
                                    library: synthetic, router: &router,
                                    settings: KeyMixSettings(), frames: 48_000)
    // 0.25 s * 48 kHz = sample 12 000. The take's own 3-sample offset and the
    // bounded pitch resampler spread energy over at most a few samples, but
    // nothing may leak outside that window.
    let onset = 12_000
    let window = Array(out.l[(onset - 4)...(onset + 10)])
    let outside = Array(out.l[..<(onset - 4)]) + Array(out.l[(onset + 10)...])
    #expect((window.map(abs).max() ?? 0) > 1e-7, "no impulse energy at the cue time")
    #expect(outside.allSatisfy { abs($0) < 1e-9 }, "energy leaked outside the cue window")
}

@Test func burstTypingNeverClipsTheBus() {
    let cues = (0..<1_000).map { i in
        SFXCue(t: 0.01 + Double(i) * 0.001, kind: i % 7 == 0 ? .keyUp : .key,
               gainDb: 0, keyCode: UInt16([0, 49, 36, 51, 55, 56, 123, 40][i % 8]))
    }
    var router = KeyVariationRouter()
    let out = KeySoundEngine.render(cues: cues, library: library, router: &router,
                                    settings: KeyMixSettings(), frames: 2 * 48_000)
    #expect(out.l.count == 2 * 48_000)
    #expect(out.l.allSatisfy { $0.isFinite && abs($0) <= 0.9 })
    #expect(out.r.allSatisfy { $0.isFinite && abs($0) <= 0.9 })
}

@Test func clickDownAndUpUseDistinctRecordedVariants() {
    var router = KeyVariationRouter()
    guard let pair = router.clickPair(library.clicks.count) else {
        Issue.record("no click pair"); return
    }
    #expect(pair.down != pair.up)
    let out = KeySoundEngine.render(cues: [SFXCue(t: 0.1, kind: .click, gainDb: 0)],
                                    library: library, router: &router,
                                    settings: KeyMixSettings(), frames: 48_000)
    #expect(out.l.contains { abs($0) > 1e-4 })
}

@Test func selectedStudioClickUsesItsCuratedRecording() throws {
    for sound in ClickSound.studioCollection {
        let samples = try #require(library.studioClicks[sound]?.samples)
        var settings = KeyMixSettings()
        settings.clickTone = sound
        settings.clickLevelDb = 0
        settings.limiterCeiling = 1
        var router = KeyVariationRouter()
        let out = KeySoundEngine.render(cues: [SFXCue(t: 0, kind: .click, gainDb: 0)],
                                        library: library, router: &router, settings: settings,
                                        frames: samples.count)
        #expect(out.l == samples, "\(sound) did not render its selected recording")
    }
}

@Test func everyShippedFileIsLicensedMasteredAndMeasured() throws {
    let manifestURL = try #require(BundledAudioAssets.sound(named: "manifest.json"))
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    #expect(manifest.sampleRate == 48_000)
    #expect(manifest.masteringPolicy == "static-gain-transient-preserved")
    #expect(manifest.targetPeakDb == -6)
    #expect(manifest.files.count >= 86)
    let licenseText = try String(contentsOf: manifestURL.deletingLastPathComponent()
        .appendingPathComponent("LICENSES.md"), encoding: .utf8)
    var seenHashes = Set<String>()
    for file in manifest.files {
        #expect(file.license == "CC0 1.0", "\(file.path) is not CC0")
        #expect(file.sourceUrl.hasPrefix("https://"))
        #expect(file.pageUrl.hasPrefix("https://"))
        #expect(file.sha256.count == 64)
        #expect(file.sourceSha256.count == 64, "\(file.path) lacks an original hash")
        #expect(file.mastering.sampleRate == 48_000)
        #expect(seenHashes.insert(file.sha256).inserted, "\(file.path) reuses another recording")
        #expect(licenseText.contains("`\(file.path)`"), "\(file.path) missing from LICENSES.md")
        // One static gain to a -6 dBFS peak: transients are preserved instead
        // of being compressed to a loudness target.
        #expect(abs(file.mastering.peakDb - -6.0) <= 0.5,
                "\(file.path) peaks at \(file.mastering.peakDb) dBFS")
        if file.phase == "up" {
            #expect(file.releaseEvidence != nil, "\(file.path) release has no recorded evidence")
        }
    }
}

private struct Manifest: Decodable {
    let sampleRate: Int
    let masteringPolicy: String
    let targetPeakDb: Double
    let files: [ManifestFile]
}
private struct ManifestFile: Decodable {
    let path: String
    let phase: String
    let license: String
    let sourceUrl: String
    let pageUrl: String
    let sha256: String
    let sourceSha256: String
    let releaseEvidence: String?
    let mastering: Mastering
}
private struct Mastering: Decodable {
    let sampleRate: Int
    let peakDb: Double
    enum CodingKeys: String, CodingKey {
        case sampleRate
        case peakDb
    }
}
