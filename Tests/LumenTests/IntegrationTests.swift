import Testing
import Foundation
import Metal
import AVFoundation
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
import LumenExport

@Test func eventLogRoundTrip() {
    let event = InputEvent(t: 0.25, kind: .down, x: 123, y: 45, button: 1, keyCode: 42, flags: 3, cursorShape: 2, axFrameIndex: 7)
    var bytes: [UInt8] = []
    EventCodec.encode(event, into: &bytes)
    #expect(bytes.count == 32)
    #expect(EventCodec.decode(EventCodec.header() + Data(bytes)) == [event])
}

@Test func timeMapRoundTripAndSpeechProtection() {
    let tm = TimeMap(sourceDuration: 5, ramps: [SpeedRamp(start: 1, end: 4, speed: 4)])
    var last = -1.0
    for i in 0...500 {
        let source = Double(i) / 100
        let output = tm.output(atSource: source)
        #expect(output > last)
        #expect(abs(tm.source(atOutput: output) - source) < 0.005)
        last = output
    }
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 5, backingScale: 1, originX: 0, originY: 0)
    let tl = Director.derive(Timeline(duration: 5), input: DirectorInput(events: [], source: src, vad: [0...5]), revision: 1)
    #expect(tl.timeMap.ramps.isEmpty)
}

@Test func manualZoomSurvivesAndCameraStaysInBounds() {
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 1, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 1)
    tl.audio.speedRampsAuto = false
    let manual = ZoomSegment(start: 0, end: 1, scale: 2, focus: .fixed(x: 0, y: 0), origin: .manual)
    tl.zoom = [manual]
    let events = [InputEvent(t: 0.4, kind: .down, x: 12, y: 12), InputEvent(t: 0.6, kind: .up, x: 12, y: 12)]
    let output = Director.derive(tl, input: DirectorInput(events: events, source: src), revision: 1)
    #expect(output.zoom.contains(manual))
    let click = output.evaluate(at: 0.4).cursor.position
    #expect(abs(click.x - 12) < 0.5 && abs(click.y - 12) < 0.5)
    for i in 0...240 {
        let frame = output.evaluate(at: Double(i) / 240)
        let halfW = 320 / frame.cameraScale, halfH = 180 / frame.cameraScale
        #expect(frame.cameraCenter.x >= halfW - 0.5 && frame.cameraCenter.x <= 640 - halfW + 0.5)
        #expect(frame.cameraCenter.y >= halfH - 0.5 && frame.cameraCenter.y <= 360 - halfH + 0.5)
    }
}

@Test func offlineAudioIsRepeatableAndLimited() throws {
    let src = SourceInfo(width: 640, height: 360, fps: 60, duration: 1, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 1)
    tl.audio.micClean = false
    tl.audio.speedRampsAuto = false
    tl = Director.derive(tl, input: DirectorInput(events: [], source: src), revision: 1)
    let voice = (0..<48000).map { Float(0.2 * sin(2 * Double.pi * 440 * Double($0) / 48000)) }
    let mixer = AudioMixer(mic: voice, micOffset: 0, system: nil, systemOffset: 0)
    let a = try #require(mixer.mix(tl)), b = try #require(mixer.mix(tl))
    #expect(a.l == b.l && a.r == b.r)
    #expect(abs(a.lufs + 14) <= 0.5)
    #expect(a.truePeakDb <= -1)
}

@Test func rendererAndExportRoundTrip() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try ProjectBundle.create(named: "Integration", in: root)
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
    try bundle.save(ProjectFile(meta: ProjectMeta(name: "Integration", source: source, clock: RecordingClock()), timeline: timeline))
    try EventCodec.header().write(to: bundle.eventsURL)
    let renderer = try Renderer()
    let (session, loaded) = try await ProjectSession.open(bundle, device: renderer.device)
    let derived = session.derive(loaded, revision: 1)
    let a = try await FrameImage.render(renderer: renderer, session: session, timeline: derived, t: 0.25, canvas: SIMD2(320, 180))
    let b = try await FrameImage.render(renderer: renderer, session: session, timeline: derived, t: 0.25, canvas: SIMD2(320, 180))
    func pixels(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: CVPixelBufferGetDataSize(buffer))
    }
    #expect(pixels(a) == pixels(b))
    let output = root.appendingPathComponent("export.mp4")
    try await Exporter.run(session: session, timeline: derived, preset: ExportPreset(name: "test", codec: .h264, height: 180, fps: 30), to: output) { _ in }
    let asset = AVURLAsset(url: output)
    let duration = try await asset.load(.duration).seconds
    #expect(abs(duration - 1) < 0.02)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let outputTrack = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(outputTrack)
    #expect(reader.startReading())
    var frameCount = 0
    while let sample = outputTrack.copyNextSampleBuffer() { frameCount += CMSampleBufferGetNumSamples(sample) }
    #expect(frameCount == 30)
    let geometry = Geometry(canvas: SIMD2(180, 320), src: SIMD2(320, 180), style: timeline.style)
    #expect(abs(geometry.content.z / geometry.content.w - 16.0 / 9) < 0.03)
}
