import Testing
@testable import LumenControl

@Test func agentQualityAllowsIntentionalStaticAndSilentVideo() {
    #expect(AgentQualityPolicy.zoomPass(clicks: 0, zoomed: 0, centered: 0, settled: 0, automatic: true))
    #expect(AgentQualityPolicy.zoomPass(clicks: 4, zoomed: 0, centered: 0, settled: 0, automatic: false))
    let silent = AgentQualityPolicy.audioPass(expected: false, measured: false, loudness: -120, truePeak: -120)
    #expect(silent.level && silent.audible)
}

@Test func agentQualityDoesNotPassMissingRequiredEvidence() {
    #expect(!AgentQualityPolicy.zoomPass(clicks: 4, zoomed: 0, centered: 0, settled: 0, automatic: true))
    #expect(!AgentQualityPolicy.zoomPass(clicks: 4, zoomed: 4, centered: 3, settled: 4, automatic: true))
    let missing = AgentQualityPolicy.audioPass(expected: true, measured: false, loudness: -18, truePeak: -2)
    #expect(!missing.level && !missing.audible)
    let clipping = AgentQualityPolicy.audioPass(expected: true, measured: true, loudness: -18, truePeak: 0)
    #expect(!clipping.level && clipping.audible)
}
