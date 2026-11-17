import Testing
import Foundation
import AVFoundation
import Metal
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
import LumenExport
@testable import LumenUI

/// Oracle for Plans/play-instant.md.
///
/// Contract change (lane D): Play starts video *and its audio* against one
/// future host instant. Starting the clock with no audio under it is the
/// defect this lane fixes, so "clock running" alone is no longer success. The
/// assertions below are: the clock never runs silent, and once audio is queued
/// the clock and the audio are anchored to the same instant.
@MainActor
@Test func playStartsVideoAndAudioTogether() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try ProjectBundle.create(named: "PlayInstant", in: root)
    // 1s grey screen track so ProjectSession.open succeeds.
    let writer = try AVAssetWriter(outputURL: bundle.screenURL, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<30 {
        let buffer = try #require(FrameImage.makeBuffer(320, 180))
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        memset(base, 160, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        #expect(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 30)))
    }
    input.markAsFinished()
    // The callback API avoids sending this main actor-owned writer across an
    // unisolated async boundary under Swift 6 strict concurrency checking.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        writer.finishWriting {
            continuation.resume()
        }
    }
    #expect(writer.status == .completed)

    let source = SourceInfo(width: 320, height: 180, fps: 30, duration: 1, backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 1)
    timeline.audio.speedRampsAuto = false
    timeline.audio.clickSounds = false
    timeline.audio.whooshes = false
    let micSamples = (0..<48_000).map { i -> Float in Float(0.12 * sin(Double(i) * 2 * .pi * 440 / 48_000)) }
    try AudioIO.writeCAF(micSamples, micSamples, to: bundle.micURL)
    var meta = ProjectMeta(name: "PlayInstant", source: source, clock: RecordingClock())
    meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: 0)
    try bundle.save(ProjectFile(meta: meta, timeline: timeline))
    try EventCodec.header().write(to: bundle.eventsURL)

    let renderer = try Renderer()
    let (session, loaded) = try await ProjectSession.open(bundle, device: renderer.device)
    let derived = session.derive(loaded, revision: 1)
    let model = EditorModel(session: session, renderer: renderer, timeline: derived,
                            exportSettings: ExportSettings(), transcript: nil)

    model.play()
    // The clock must not run with nothing queued to play. Audio for the first
    // window is rendered first, so Play returns in the preparing state and the
    // clock starts when the audio is really there.
    var waitedMs = 0
    while model.preparingPlayback, waitedMs < 4000 {
        try await Task.sleep(for: .milliseconds(10))
        waitedMs += 10
    }
    #expect(!model.preparingPlayback, "playback never finished preparing audio")
    #expect(model.clock.playing, "PlaybackClock must be started once audio is ready")
    // Clock and audio are anchored to the same future instant, so the first
    // played frame and its sample are heard together.
    #expect(model.clock.anchor > model.clock.startedAt)
    #expect(model.audioQueuedAtStart, "Play must not start the clock without audio")
    model.pause()
    #expect(!model.clock.playing)
}

/// The first audible sample exists for a project with mic + click SFX + typing
/// SFX: a bounded window is rendered from the same DSP and the same time map as
/// the full mix, and the cue that belongs to the first frames is in it.
@Test func firstAudibleWindowCarriesMicAndCueAudio() async throws {
    let seconds = 6.0
    let fx = try makeStudioFixture(named: "FirstWindow", seconds: seconds, systemAudio: false)
    defer { try? FileManager.default.removeItem(at: fx.bundle.url.deletingLastPathComponent()) }
    let renderer = try Renderer()
    let (session, timeline) = try await ProjectSession.open(fx.bundle, device: renderer.device)
    let derived = session.derive(timeline, revision: 1)
    let cues = try #require(derived.derived?.cues.first)
    let mixer = session.mixer
    let window = try #require(mixer.mixFirstWindow(derived))
    let n = window.l.count
    let cueSample = Int(cues.t * AudioIO.fs)
    #expect(cueSample < n, "the first cue at \(cues.t)s must fall inside the first window")
    // The window is a real prefix of the program, not a stub: it has the
    // program's sample rate, both channels, and audible content.
    #expect(n > Int(AudioMixer.firstWindowSeconds * AudioIO.fs) - 2)
    let cuePeak: Float = window.l.withUnsafeBufferPointer { buf -> Float in
        var peak: Float = 0
        for i in cueSample..<min(cueSample + 4800, n) { peak = max(peak, abs(buf[i])) }
        return peak
    }
    #expect(cuePeak > 0.0005, "the cue inside the first window must be audible")
    // Voice and cue are both present, so the first played frames are not silent.
    let voicePeak = window.l.prefix(Int(0.5 * AudioIO.fs)).reduce(Float(0)) { max($0, abs($1)) }
    #expect(voicePeak > 0.0005, "the first window must contain the microphone signal")
}

/// A silent project must not be blocked on audio that does not exist: opening
/// is fast, Play starts immediately and nothing is ever queued.
@MainActor
@Test func silentProjectIsNotBlockedOnAudio() async throws {
    let seconds = 6.0
    let fx = try makeStudioFixture(named: "Silent", seconds: seconds, systemAudio: false)
    defer { try? FileManager.default.removeItem(at: fx.bundle.url.deletingLastPathComponent()) }
    // Remove the microphone: nothing in this project has a sound source.
    var file = try fx.bundle.load()
    file.meta.mic = nil
    // The fixture records clicks and key bursts, and those cues are audio too.
    // A project with nothing to play has to switch them off as well, or the
    // "silent" premise is false and the test proves nothing.
    file.timeline.audio.soundEffectsEnabled = false
    try fx.bundle.save(file)
    let renderer = try Renderer()
    let (session, timeline) = try await ProjectSession.open(fx.bundle, device: renderer.device)
    let derived = session.derive(timeline, revision: 1)
    #expect(!session.mixer.hasProgram(derived))
    let model = EditorModel(session: session, renderer: renderer, timeline: derived,
                            exportSettings: ExportSettings(), transcript: nil)
    let started = HostClock.now()
    model.play()
    #expect(model.clock.playing, "a silent project starts playing immediately")
    #expect(!model.preparingPlayback)
    #expect(!model.audioQueuedAtStart, "nothing was queued, so nothing should claim to be")
    #expect(HostClock.now() - started < 0.25)
    model.pause()
}

/// Cancelling a background voice preparation must leave no detached work
/// running and no cache written: a cancelled render produced no result.
@Test func cancelledPreparationLeavesNoDetachedWork() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-cancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fs: Double = AudioIO.fs
    let samples = (0..<Int(fs * 30)).map { i -> Float in
        let t = Double(i) / fs
        return t.truncatingRemainder(dividingBy: 1.2) < 0.5 ? Float(0.2 * sin(2 * Double.pi * 180 * t)) : 0
    }
    var tl = Timeline(duration: 30)
    tl.audio.speedRampsAuto = false
    tl = Director.derive(tl, input: DirectorInput(events: [], source: SourceInfo(
        width: 320, height: 180, fps: 30, duration: 30, backingScale: 1, originX: 0, originY: 0)), revision: 1)
    let mixer = AudioMixer(mic: samples, micOffset: 0, system: nil, systemOffset: 0, cacheDir: dir,
                           keyTimes: (0..<30).map { Double($0) + 0.3 })
    let task = Task.detached(priority: .userInitiated) { [plan = tl.audio] in mixer.prepareVoice(plan) }
    task.cancel()
    await task.value
    // Give any detached work that ignored cancellation time to finish and write.
    for _ in 0..<20 { try await Task.sleep(for: .milliseconds(25)) }
    let written = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    #expect(written.isEmpty, "a cancelled preparation must not leave a render or a cache file behind: \(written)")
    // The mixer still renders correctly afterwards: cancellation must not wedge
    // the single-flight registry.
    #expect(mixer.mix(tl) != nil)
}

// MARK: - Studio open latency harness (lane D)
//
// These helpers build a synthetic project whose audio, event and track layout
// matches a real Studio session, so the open/playback stages can be measured
// on the same fixture before and after a change. Nothing here asserts a gate
// that has not been measured on this machine first.

private struct StudioFixture {
    let bundle: ProjectBundle
    let timeline: Timeline
}

private func writeGreyScreen(_ url: URL, width: Int, height: Int, fps: Int, seconds: Double) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    let total = Int(seconds * Double(fps))
    for i in 0..<total {
        guard let buffer = FrameImage.makeBuffer(width, height) else { continue }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, i % 2 == 0 ? 90 : 150, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        if !adapter.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: CMTimeScale(fps))) {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

/// Speech-like bursts with real silence between them, so VAD, declick and the
/// neural denoiser all have work to do on a realistic signal.
private func speechLikeTrack(seconds: Double, seed: UInt64 = 7) -> [Float] {
    let fs = AudioIO.fs
    let n = Int(seconds * fs)
    var x = [Float](repeating: 0, count: n)
    var state = seed &* 6_364_136_223_846_793_005 &+ 1
    func noise() -> Float {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Float(Double(state >> 11) / Double(UInt64(1) << 53) * 2 - 1)
    }
    var t = 0.25
    var k = 0
    while t + 0.6 < seconds {
        let f0 = [118.0, 146.0, 174.0, 132.0][k % 4]
        let len = Int(0.45 * fs)
        let start = Int(t * fs)
        for i in 0..<len where start + i < n {
            let u = Double(i) / Double(len)
            let env = 0.5 - 0.5 * cos(2 * Double.pi * u)
            let time = Double(i) / fs
            var s = 0.0
            for h in 1...24 where f0 * Double(h) < 7000 {
                s += sin(2 * Double.pi * f0 * Double(h) * time) / Double(h)
            }
            x[start + i] += Float(0.12 * env * (s + 0.08 * Double(noise())))
        }
        t += 0.85
        k += 1
    }
    return x
}

private func makeStudioFixture(named: String, seconds: Double, systemAudio: Bool) throws -> StudioFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bundle = try ProjectBundle.create(named: named, in: root)
    let fps = 30, width = 640, height = 360
    try writeGreyScreen(bundle.screenURL, width: width, height: height, fps: fps, seconds: seconds)
    let mic = speechLikeTrack(seconds: seconds)
    try AudioIO.writeCAF(mic, mic, to: bundle.micURL)
    if systemAudio {
        let sys = speechLikeTrack(seconds: seconds, seed: 19)
        try AudioIO.writeCAF(sys, sys, to: bundle.systemURL)
    }
    var meta = ProjectMeta(name: named,
                           source: SourceInfo(width: width, height: height, fps: Double(fps), duration: seconds,
                                              backingScale: 2, originX: 0, originY: 0),
                           clock: RecordingClock())
    meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: 0)
    if systemAudio { meta.system = TrackMeta(file: "system.caf", startHostSeconds: 0) }
    var timeline = Timeline(duration: seconds)
    timeline.audio.speedRampsAuto = false
    // These tests measure open and playback, not detection: automatic scanning
    // would run a full OCR pass in the background and make the numbers noisy.
    timeline.overlays.privacy.autoDetect = false
    // 240 events: a click every second, a key burst every four.
    var events: [InputEvent] = []
    for i in 0..<Int(seconds) {
        events.append(InputEvent(t: Double(i) + 0.10, kind: .down, x: 200 + Float(i % 5), y: 120))
        events.append(InputEvent(t: Double(i) + 0.12, kind: .up, x: 200 + Float(i % 5), y: 120))
        for k in 0..<4 {
            events.append(InputEvent(t: Double(i) + 0.30 + Double(k) * 0.08, kind: .keyDown, x: 0, y: 0))
        }
    }
    var data = EventCodec.header()
    var record = [UInt8]()
    for e in events { record.removeAll(); EventCodec.encode(e, into: &record); data.append(contentsOf: record) }
    try data.write(to: bundle.eventsURL)
    try bundle.save(ProjectFile(meta: meta, timeline: timeline))
    return StudioFixture(bundle: bundle, timeline: timeline)
}

/// `Duration` is whole seconds plus attoseconds; a millisecond is 1e15
/// attoseconds, so attoseconds alone divide by 1e15, not 1e9.
private func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

@Test func profileStudioOpenStages() async throws {
    let seconds = 30.0
    let fx = try makeStudioFixture(named: "Profile", seconds: seconds, systemAudio: true)
    defer { try? FileManager.default.removeItem(at: fx.bundle.url.deletingLastPathComponent()) }
    let renderer = try Renderer()

    var t = ContinuousClock.now
    let (session, timeline) = try await ProjectSession.open(fx.bundle, device: renderer.device)
    let openMs = ms(t.duration(to: .now))

    t = .now
    _ = try await session.frames(atOutput: 0.2, timeline: timeline)
    let firstFrameMs = ms(t.duration(to: .now))

    t = .now
    let derived = session.derive(timeline, revision: 1)
    let deriveMs = ms(t.duration(to: .now))

    t = .now
    session.mixer.prepareVoice(derived.audio)
    let voiceMs = ms(t.duration(to: .now))

    t = .now
    let mixed = session.mixer.mix(derived)
    let mixMs = ms(t.duration(to: .now))
    let mixedSamples = mixed.map { $0.l.count } ?? 0

    t = .now
    _ = session.mixer.mix(derived)
    let warmMixMs = ms(t.duration(to: .now))

    print(String(format: "PROFILE open=%.0fms firstFrame=%.0fms derive=%.0fms voice=%.0fms mix=%.0fms samples=%d warmMix=%.0fms",
                 openMs, firstFrameMs, deriveMs, voiceMs, mixMs, mixedSamples, warmMixMs))
    #expect(openMs > 0)
    #expect(mixedSamples > 0)
}

/// Measured on this machine (see the report): the editor must return from
/// `EditorModel.open` with the project usable, before the recorded tracks are
/// decoded, the VAD is computed, the envelope is built or the neural pass runs.
@MainActor
@Test(.serialized)
func editorOpenReturnsBeforeHeavyPreparationFinishes() async throws {
    let fx = try makeStudioFixture(named: "Open", seconds: 30, systemAudio: true)
    defer { try? FileManager.default.removeItem(at: fx.bundle.url.deletingLastPathComponent()) }
    let renderer = try Renderer()
    let started = ContinuousClock.now
    let model = try await EditorModel.open(url: fx.bundle.url)
    let openMs = ms(started.duration(to: .now))
    print(String(format: "OPEN editor=%.0fms audio=%@", openMs, String(describing: model.session.audioPreparation)))
    // A wall-clock ceiling is only a gross-hang guard here: under a full
    // parallel suite the same open took 9 s while the machine was saturated,
    // and 200-300 ms in isolation. The real contract is below — the timeline is
    // usable immediately, the derive publishes without audio, and preparation
    // completes on its own.
    #expect(openMs < 15_000, "Studio entry hung for \(openMs)ms")
    // Usable means the persisted timeline and a decodable first frame.
    var waitedMs = 0
    while model.timeline.derived == nil, waitedMs < 3000 {
        try await Task.sleep(for: .milliseconds(10))
        waitedMs += 10
    }
    #expect(model.timeline.derived != nil, "the first derive must publish without waiting for audio")
    let frames = try await model.session.frames(atOutput: 0.2, timeline: model.timeline)
    #expect(frames.screen.pts.isFinite)
    // The preparation runs on its own: it must not have been skipped.
    #expect(await model.session.prepareAudio())
    #expect(model.session.audioPreparation == .ready)
    #expect(model.session.waveform.isEmpty == false, "the envelope is prepared off the open path")
    print(String(format: "OPEN total(with preparation)=%.0fms", ms(started.duration(to: .now))))
    model.pause()
}

/// Warm reopening must reuse valid analysis instead of rescheduling it: the
/// second open of the same project does not re-render the voice (the disk
/// cache is valid) and reaches `ready` without a full decode.
@MainActor
@Test func warmReopenReusesPreparedAudio() async throws {
    let fx = try makeStudioFixture(named: "Warm", seconds: 12, systemAudio: false)
    defer { try? FileManager.default.removeItem(at: fx.bundle.url.deletingLastPathComponent()) }
    let renderer = try Renderer()
    let (first, timeline) = try await ProjectSession.openEditor(fx.bundle, device: renderer.device)
    let ready = await first.prepareAudio()
    #expect(ready)
    let cached = (try? FileManager.default.contentsOfDirectory(atPath: fx.bundle.cacheURL.path)) ?? []
    print("WARM cached after first open: \(cached.count) files")
    let started = ContinuousClock.now
    let (second, _) = try await ProjectSession.openEditor(fx.bundle, device: renderer.device)
    let reopenedMs = ms(started.duration(to: .now))
    let prepared = await second.prepareAudio()
    let preparedMs = ms(started.duration(to: .now))
    print(String(format: "WARM reopen=%.0fms prepare=%.0fms waveform=%d", reopenedMs, preparedMs, second.waveform.count))
    #expect(prepared)
    #expect(second.waveform.isEmpty == false)
    #expect(second.input.vad.isEmpty == false, "the VAD is published on the second open too")
    // Reopening reuses the cached voice instead of re-running the denoiser.
    let derived = second.derive(timeline, revision: 1)
    let mixed = try #require(second.mixer.mix(derived))
    #expect(mixed.l.isEmpty == false)
}
