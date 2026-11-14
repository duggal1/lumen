import Foundation
import Testing
import LumenAudio
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

// MARK: - Voice work: one lock, single flight, parallel independent jobs
//
// Measured before and after the mixer restructure on this machine (Apple M1,
// 8 cores, macOS 27.2). The numbers below are the ones printed by
// `voiceWorkIsSingleFlightAndNotSerialised`.

/// Counts renders and stands in for a slow neural denoiser, so the test measures
/// scheduling and duplicate work rather than inference speed.
private func milliseconds(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

private final class CountingDenoiser: Denoiser, @unchecked Sendable {
    private let lock = NSLock()
    private let renderSeconds: Double
    private var renders = 0
    init(renderSeconds: Double) { self.renderSeconds = renderSeconds }
    var count: Int { lock.lock(); defer { lock.unlock() }; return renders }
    func process(_ x: [Float]) -> [Float] {
        lock.lock(); renders += 1; lock.unlock()
        Thread.sleep(forTimeInterval: renderSeconds)
        return x
    }
}

@Test func voiceWorkIsSingleFlightAndNotSerialised() throws {
    let fs = AudioIO.fs
    let samples = (0..<Int(fs * 2)).map { i -> Float in Float(0.1 * sin(2 * Double.pi * 200 * Double(i) / fs)) }
    var base = Timeline(duration: 2)
    base.audio.speedRampsAuto = false
    // Scheduling, not DSP: dereverb is a full WPE pass over the fixture and
    // would swamp the timing these assertions are about. The denoiser is the
    // one heavy stage left, and it is the stage the single-flight protects.
    base.audio.dereverb = 0
    let src = SourceInfo(width: 320, height: 180, fps: 30, duration: 2, backingScale: 1, originX: 0, originY: 0)
    base = Director.derive(base, input: DirectorInput(events: [], source: src), revision: 1)

    // Same plan from two threads at once: one render, both get the result.
    let denoiser = CountingDenoiser(renderSeconds: 0.4)
    let mixer = AudioMixer(mic: samples, micOffset: 0, system: nil, systemOffset: 0)
    mixer.denoiser = denoiser
    let start = ContinuousClock.now
    DispatchQueue.concurrentPerform(iterations: 2) { _ in _ = mixer.mix(base) }
    // `Duration` splits into whole seconds and attoseconds. Seconds are 1e9 ns
    // and attoseconds are 1e-18 s, so milliseconds are seconds*1e3 +
    // attoseconds/1e15; dividing attoseconds by 1e9 yields seconds, not ms.
    let duplicateMs = milliseconds(start.duration(to: .now))
    print(String(format: "VOICE same-plan concurrent renders=%d wall=%.0fms", denoiser.count, duplicateMs))
    #expect(denoiser.count == 1, "two callers for one voice key must not both render")
    // One 400 ms render plus this machine's fixed mix cost. Duplicate work
    // would add a second 400 ms render on top, so the gap is unambiguous.
    #expect(duplicateMs < 1000, "concurrent callers of one key took \(duplicateMs) ms")

    // Two different voice settings on the same mixer are independent work: the
    // old single lock serialised them, so the second waited for the whole
    // first render. Two 0.6 s renders must overlap, not add up.
    let parallelDenoiser = CountingDenoiser(renderSeconds: 0.6)
    let shared = AudioMixer(mic: samples, micOffset: 0, system: nil, systemOffset: 0)
    shared.denoiser = parallelDenoiser
    var a = base, b = base
    a.audio.noiseReductionStrength = 0.4
    b.audio.noiseReductionStrength = 1.0
    let started = ContinuousClock.now
    DispatchQueue.concurrentPerform(iterations: 2) { index in _ = shared.mix(index == 0 ? a : b) }
    let wallMs = milliseconds(started.duration(to: .now))
    print(String(format: "VOICE different-plans concurrent renders=%d wall=%.0fms", parallelDenoiser.count, wallMs))
    #expect(parallelDenoiser.count == 2)
    // Two 600 ms renders that overlap finish in about one render's time; a
    // serialised pair would take both, plus the fixed cost twice.
    #expect(wallMs < 1400, "independent voice jobs were serialised: \(wallMs) ms for two 600 ms renders")
}
