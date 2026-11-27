import Testing
import LumenProject

@Test func mixerOnlyControlsDoNotInvalidateDerivedCamera() {
    let baseline = AudioPlan()
    var next = baseline
    next.micGainDb = -6
    next.systemGainDb = -12
    next.outputGainDb = -2
    next.typingLevelDb = -18
    next.musicGainDb = -24
    next.sfxGainDb = -16
    #expect(baseline.hasSameDerivation(as: next))
    #expect(next.hasSameDerivation(as: baseline))
}

@Test func cuesRampsAndDuckingStillInvalidateDerivedTracks() {
    let baseline = AudioPlan()
    var next = baseline
    next.clickGainDb += 1
    #expect(!baseline.hasSameDerivation(as: next))
    next = baseline; next.speedRampMinIdle += 1
    #expect(!baseline.hasSameDerivation(as: next))
    next = baseline; next.duckDepthDb -= 1
    #expect(!baseline.hasSameDerivation(as: next))
    next = baseline; next.keySounds.toggle()
    #expect(!baseline.hasSameDerivation(as: next))
}
