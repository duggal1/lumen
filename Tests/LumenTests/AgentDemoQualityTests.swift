import Testing
@testable import LumenControl

private func qualityFixture(_ fails: [String], revision: Int = 3) -> JSONValue {
    .object(["revision": .int(revision), "checks": .array(["loudness", "privacy_masked", "no_dropped_frames"].map {
        .object(["name": .string($0), "ok": .bool(!fails.contains($0))])
    }), "audio_measurement": .object(["expected": .bool(true), "measured": .bool(true),
                                    "lufs": .number(-27), "true_peak_db": .number(-12)])])
}

@Test func demoQualityRepairsOnlyOneMeasuredGainDefect() async throws {
    var assessments = 0
    var repairs = 0
    let result = try await AgentDemoQuality.run(assess: {
        assessments += 1
        return qualityFixture(assessments == 1 ? ["loudness"] : [], revision: assessments + 2)
    }, repair: { delta, revision in
        repairs += 1
        #expect(delta == 6)
        #expect(revision == 3)
        return true
    })
    #expect(assessments == 2)
    #expect(repairs == 1)
    #expect(result.corrections.count == 1)
}

@Test func demoQualityDoesNotRepairAroundPrivacyFailure() async throws {
    var repairs = 0
    do {
        _ = try await AgentDemoQuality.run(assess: { qualityFixture(["privacy_masked", "loudness"]) }, repair: { _, _ in
            repairs += 1; return true
        })
        Issue.record("Privacy failure passed.")
    } catch let error as ToolError {
        #expect(error.code == "QA_FAILED")
        #expect(repairs == 0)
    }
}

@Test func demoQualityRejectsMissingCheckEvidence() throws {
    #expect(throws: ToolError.self) { _ = try AgentDemoQuality.failedChecks(.object([:])) }
}
