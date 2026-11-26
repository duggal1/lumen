import Testing
@testable import LumenCapture

private func sample(_ elapsed: Double, _ written: Int, _ dropped: Int, width: Int = 3840, fps: Double = 60) -> CaptureStats {
    CaptureStats(elapsed: elapsed, micLevel: 0, systemLevel: 0, dropped: dropped, thermal: 0,
                 written: written, width: width, height: 2160, configuredFPS: fps)
}

@Test func captureGuardShedsOnlyAfterSustainedMeasuredPressure() {
    var guardrail = CaptureQualityGuard()
    #expect(guardrail.observe(sample(0, 0, 0), paused: false) == .nominal)
    #expect(guardrail.observe(sample(1, 40, 20), paused: false) == .nominal)
    #expect(guardrail.observe(sample(2, 80, 40), paused: false) == .shedOptionalWork)
    #expect(guardrail.observe(sample(3, 80, 40), paused: true) == .nominal)
    #expect(guardrail.observe(sample(4, 81, 40), paused: false) == .nominal)
    #expect(guardrail.observe(sample(5, 82, 40), paused: false) == .nominal)
}

@Test func captureGuardDoesNotInventNativeResolutionOrCadence() {
    var guardrail = CaptureQualityGuard()
    #expect(guardrail.observe(sample(0, 0, 0, width: 2560), paused: false) == .belowRequestedFormat)
    #expect(guardrail.observe(sample(0, 0, 0, fps: 30), paused: false) == .belowRequestedFormat)
}
