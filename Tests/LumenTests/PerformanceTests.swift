import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

/// Performance + smoothness budgets (not smoke tests): these fail if the
/// Director regresses to multi-second derives or teleporting camera steps.
private let perfSource = SourceInfo(width: 1920, height: 1080, fps: 60,
                                    duration: 60, backingScale: 1,
                                    originX: 0, originY: 0)

private func perfInput() -> DirectorInput {
    var events: [InputEvent] = []
    for i in 0..<120 {
        let t = Double(i) * 0.5
        events.append(InputEvent(t: t, kind: .move, x: Float(200 + (i * 37) % 1500), y: Float(200 + (i * 53) % 700)))
        if i % 10 == 0 { events.append(InputEvent(t: t, kind: .down, x: Float(200 + (i * 37) % 1500), y: Float(200 + (i * 53) % 700))) }
    }
    return DirectorInput(events: events, source: perfSource)
}

@Test func deriveOfSixtySecondRecordingStaysWithinBudget() {
    var tl = Timeline(duration: 60)
    tl.audio.speedRampsAuto = false
    let start = Date()
    let out = Director.derive(tl, input: perfInput(), revision: 1)
    let elapsed = Date().timeIntervalSince(start)
    #expect(out.derived != nil)
    #expect(!out.zoom.isEmpty)
    // Generous ceiling for CI, but catches the old multi-second-plus
    // editor-open stall class. Typical local run is well under 1s.
    #expect(elapsed < 5.0, "derive took \(elapsed)s")
}

@Test func frameEvaluationThroughputIsFarAboveSixtyFps() {
    var tl = Timeline(duration: 60)
    tl.audio.speedRampsAuto = false
    let out = Director.derive(tl, input: perfInput(), revision: 1)
    let start = Date()
    var checksum = 0.0
    for i in 0..<20_000 {
        let f = out.evaluate(at: Double(i) / 1000.0)
        checksum += Double(f.cameraCenter.x) + Double(f.cameraScale)
    }
    let elapsed = Date().timeIntervalSince(start)
    #expect(checksum.isFinite && checksum != 0)
    #expect(elapsed < 2.0, "20k evaluations took \(elapsed)s")
}

@Test func cameraStepsNeverTeleportBetweenGridSamples() {
    var tl = Timeline(duration: 60)
    tl.audio.speedRampsAuto = false
    let out = Director.derive(tl, input: perfInput(), revision: 1)
    guard let cam = out.derived?.camera else { Issue.record("no camera track"); return }
    // At 1440Hz even a fast pan moves only a few source px per sample.
    // A step >50px means the camera teleported (the smoothness bug).
    var maxStep = 0.0
    for i in 1..<cam.nx.count {
        let dx = (Double(cam.nx[i] - cam.nx[i - 1])) * 1920.0
        let dy = (Double(cam.ny[i] - cam.ny[i - 1])) * 1080.0
        maxStep = max(maxStep, hypot(dx, dy))
        #expect(cam.nx[i].isFinite && cam.lz[i].isFinite)
    }
    #expect(maxStep < 50, "camera teleported \(maxStep)px in one 1/1440s sample")
}

@Test func largeSigmaGaussianPreservesStepMidpoint() {
    // The O(n) box approximation must keep the step midpoint at ~0.5 and
    // stay monotonic (a broken kernel would ring or shift the edge).
    var a = [Double](repeating: 0, count: 4000)
    for i in 2000..<4000 { a[i] = 1 }
    let out = gaussianSmooth(a, sigma: 50)
    #expect(out.count == 4000)
    #expect(abs(out[2000] - 0.5) < 0.15, "midpoint was \(out[2000])")
    #expect(out[1900] < out[2000] && out[2000] < out[2100])
    #expect(out[0] < 0.1 && out[3999] > 0.9)
}
