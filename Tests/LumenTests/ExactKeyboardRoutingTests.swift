import Testing
import LumenProject
@testable import LumenAudio

@Test func exactKeyboardUsesPhysicalCodeAndPhaseWithoutRandomFallback() {
    var lib = KeySoundLibrary()
    lib.usesExactKeys = true
    lib.exactDown[0] = KeyTake(id: "A", samples: [0.25, 0])
    lib.exactDown[1] = KeyTake(id: "S", samples: [0.5, 0])
    lib.exactUp[0] = KeyTake(id: "A-up", samples: [-0.25, 0])
    lib.down[.alpha] = [KeyTake(id: "rejected", samples: [0.8])]
    var settings = KeyMixSettings()
    settings.keyLevelDb = 0; settings.limiterCeiling = 1
    var router = KeyVariationRouter()
    let output = KeySoundEngine.render(cues: [
        SFXCue(t: 0, kind: .key, gainDb: 0, keyCode: 0),
        SFXCue(t: 0.01, kind: .key, gainDb: 0, keyCode: 1),
        SFXCue(t: 0.02, kind: .key, gainDb: 0, keyCode: 0, isKeyRelease: true),
        SFXCue(t: 0.03, kind: .key, gainDb: 0, keyCode: 99),
    ], library: lib, router: &router, settings: settings, frames: 2000)
    #expect(output.l[0] == 0.25)
    #expect(output.l[480] == 0.5)
    #expect(output.l[960] == -0.25)
    #expect(output.l[1440] == 0)
}

@Test func productionKeyboardUsesRealExactMechvibesKeys() throws {
    let library = KeySoundLibrary.loadProduction()
    #expect(library.usesExactKeys)
    let a = try #require(library.takes(keyCode: 0, phase: .down).first)
    let s = try #require(library.takes(keyCode: 1, phase: .down).first)
    #expect(a.id != s.id)
    #expect(a.samples != s.samples)
    #expect(library.takes(keyCode: 10000, phase: .down).isEmpty)
    #expect(library.takes(keyCode: 10000, phase: .up).isEmpty)
}
