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

/// Oracle for Plans/play-instant.md: Play starts video-motion synchronously.
/// Red before the fix (clock waits on the offline mix), green after.
@MainActor
@Test func playStartsVideoSynchronously() async throws {
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
    await writer.finishWriting()
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
    let model = EditorModel(session: session, renderer: renderer, timeline: derived)

    model.play()
    // Synchronous gate: video must be running the line after play() returns.
    #expect(model.isPlaying, "Play must set isPlaying synchronously, not after the mix")
    #expect(model.clock.playing, "PlaybackClock must be started synchronously")
    // 150 ms wall-clock gate from the plan (covers schedulers that tick async).
    var waitedMs = 0
    while !model.clock.playing, waitedMs < 150 {
        try await Task.sleep(for: .milliseconds(10))
        waitedMs += 10
    }
    #expect(model.clock.playing, "Video must start within 150 ms of Play")
    model.pause()
    #expect(!model.clock.playing)
}
