import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenAudio

@Suite struct Core03AudioRegressionTests {
    private func render(_ cues: [SFXCue], _ library: KeySoundLibrary,
                        settings: KeyMixSettings = KeyMixSettings(),
                        frames: Int = 4096, start: Int64 = 0) -> StereoBuffer {
        var router = KeyVariationRouter()
        return KeySoundEngine.render(cues: cues, library: library, router: &router,
                                     settings: settings, frames: frames, startFrame: start)
    }

    @Test func clickUsesExactlySelectedTakeAndNeverInventsRelease() {
        var lib = KeySoundLibrary()
        lib.clicks = (0..<5).map { KeyTake(id: "test-\($0)", samples: [Float($0 + 1) / 10, 0]) }
        var settings = KeyMixSettings()
        settings.clickTone = .click3; settings.clickLevelDb = 0; settings.limiterCeiling = 1
        let cues = [SFXCue(t: 0, kind: .click, gainDb: 0),
                    SFXCue(t: 0.05, kind: .click, gainDb: 0)]
        let out = render(cues, lib, settings: settings)
        #expect(out.l[0] == 0.3)
        #expect(out.l[2400] == 0.3)
        #expect(out.l[864] == 0)
        #expect(out.l.filter { $0 != 0 }.count == 2)
        #expect(out.l == out.r)
    }

    @Test func persistedReleaseFlagUsesReleaseRecordingAndUnverifiedReleaseIsSilent() {
        var lib = KeySoundLibrary()
        lib.down[.alpha] = [KeyTake(id: "down", samples: [0.6, 0.6, 0.6, 0])]
        lib.up[.alpha] = [KeyTake(id: "up", samples: [-0.4, -0.4, -0.4, 0])]
        let release = SFXCue(t: 0, kind: .key, gainDb: 0, keyCode: 0, isKeyRelease: true)
        let known = render([release], lib)
        #expect(known.l[0] < 0)
        lib.unverifiedReleaseIDs.insert("up")
        #expect(render([release], lib).l.allSatisfy { $0 == 0 })
        #expect(render([SFXCue(t: 0, kind: .keyUp, gainDb: 0)], lib).l.allSatisfy { $0 == 0 })
    }

    @Test func typingLevelHasSingleSixDecibelGainSlope() {
        var lib = KeySoundLibrary()
        lib.down[.alpha] = [KeyTake(id: "test", samples: [0.3, 0.2, 0.1, 0])]
        let cue = SFXCue(t: 0, kind: .key, gainDb: 0)
        var a = KeyMixSettings(), b = a
        a.keyLevelDb = -18; b.keyLevelDb = -12
        let x = render([cue], lib, settings: a).l.map(abs).max()!
        let y = render([cue], lib, settings: b).l.map(abs).max()!
        #expect(x > 0)
        #expect(abs(20 * log10(Double(y / x)) - 6) < 0.001)
    }

    @Test func limiterIncludesCurrentSampleAndPreservesStereoRatio() {
        var l: [Float] = [2, 2, 0, 0.2, .nan, 3, 3, 3]
        var r: [Float] = [1, 1, 0, 0.1, .infinity, 1.5, 1.5, 1.5]
        let limiter = BusLimiter(ceiling: 0.8, lookahead: 2, release: 0.5)
        limiter.process(left: &l, right: &r)
        #expect(l.allSatisfy { $0.isFinite && abs($0) <= 0.800001 })
        #expect(r.allSatisfy { $0.isFinite && abs($0) <= 0.800001 })
        #expect(l[4] == 0 && r[4] == 0)
        for i in [0, 1, 3, 5, 6, 7] { #expect(abs(l[i] - 2 * r[i]) < 1e-6) }
    }

    @Test func limiterWindowMatchesReferenceOnOverlappingPeaks() {
        var l = (0..<1000).map { Float(sin(Double($0) * 0.23) * 2.3) }
        var r = (0..<1000).map { Float(cos(Double($0) * 0.19) * 1.7) }
        let sourceL = l, sourceR = r
        let cap: Float = 0.73, release: Float = 0.021
        var gain: Float = 1
        let look = 17
        BusLimiter(ceiling: cap, lookahead: look, release: release).process(left: &l, right: &r)
        for i in l.indices {
            let peak = (i...min(i + look, l.count - 1)).map { max(abs(sourceL[$0]), abs(sourceR[$0])) }.max()!
            let required: Float = peak > cap ? cap / peak : 1
            gain = min(required, gain + (1 - gain) * release)
            #expect(abs(l[i] - sourceL[i] * gain) < 1e-6)
            #expect(abs(r[i] - sourceR[i] * gain) < 1e-6)
        }
    }

    @Test func windowRetainsVariantIdentityAndSampleTiming() {
        var lib = KeySoundLibrary()
        lib.down[.alpha] = (0..<3).map { KeyTake(id: "test-\($0)", samples: [0.1 * Float($0 + 1), 0.01, 0]) }
        let cues = (0..<25).map { SFXCue(t: Double($0) * 0.05, kind: .key, gainDb: -12) }
        let full = render(cues, lib, frames: 72_000)
        let start: Int64 = 24_000
        let window = render(cues, lib, frames: 20_000, start: start)
        #expect(window.l == Array(full.l[24_000..<44_000]))
        #expect(window.r == Array(full.r[24_000..<44_000]))
    }

    @Test func hostileCueTimesAndGainsAreIgnored() {
        var lib = KeySoundLibrary()
        lib.clicks = [KeyTake(id: "test", samples: [1, 0])]
        var settings = KeyMixSettings(); settings.clickTone = .mouse
        let cues = [SFXCue(t: .nan, kind: .click, gainDb: 0),
                    SFXCue(t: 1e300, kind: .click, gainDb: 0),
                    SFXCue(t: 0, kind: .click, gainDb: .infinity)]
        #expect(render(cues, lib, settings: settings).l.allSatisfy { $0 == 0 })
    }
}
