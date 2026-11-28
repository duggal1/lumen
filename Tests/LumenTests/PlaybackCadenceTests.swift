import Testing
import LumenRender

@Test func cadenceNeedsActualTenSecondWindow() throws {
    let cadence = PlaybackCadence()
    var result: PlaybackCadence.Report?
    for i in 0...610 {
        let t = Double(i) / 60
        if let value = cadence.record(generation: 1, sourceTime: t, actual: 100 + t, expected: 1.0 / 60) {
            result = value
        }
        if i < 600 { #expect(result == nil) }
    }
    let proof = try #require(result)
    #expect(proof.elapsedSeconds >= 10)
    #expect(abs(proof.presentedFPS - 60) < 0.01)
    #expect(proof.lateFraction == 0)
}

@Test func cadenceDoesNotJoinAcrossSeekOrRevision() {
    let cadence = PlaybackCadence()
    for i in 0...400 {
        let t = Double(i) / 60
        #expect(cadence.record(generation: 1, sourceTime: t, actual: 100 + t, expected: 1.0 / 60) == nil)
    }
    for i in 0...400 {
        let t = Double(i) / 60
        #expect(cadence.record(generation: 2, sourceTime: t, actual: 110 + t, expected: 1.0 / 60) == nil)
    }
}

@Test func cadenceReportsPresentationMisses() throws {
    let cadence = PlaybackCadence()
    var result: PlaybackCadence.Report?
    for i in 0...330 {
        let t = Double(i) / 30
        if let value = cadence.record(generation: 1, sourceTime: t, actual: 100 + t, expected: 1.0 / 60) {
            result = value
        }
    }
    let proof = try #require(result)
    #expect(proof.lateFraction == 1)
    #expect(proof.presentedFPS < 31)
}
