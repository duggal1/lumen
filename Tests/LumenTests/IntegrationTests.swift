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
    #expect(abs(a.lufs + 16) <= 0.5)
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
    let micSamples = (0..<48_000).map { i -> Float in
        Float(0.12 * sin(Double(i) * 2 * .pi * 440 / 48_000))
    }
    try AudioIO.writeCAF(micSamples, micSamples, to: bundle.micURL)
    var meta = ProjectMeta(name: "Integration", source: source, clock: RecordingClock())
    meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: 0)
    try bundle.save(ProjectFile(meta: meta, timeline: timeline))
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

    // Security regression: changes must affect actual rendered pixels. Each
    // independent mask must cover its own source region before export.
    var privacy = derived
    privacy.overlays.masks = [
        Mask(start: 0, end: 1, mode: .solid,
             keys: [MaskKey(t: 0, x: 110, y: 58, w: 58, h: 28)], padding: 0),
        Mask(start: 0, end: 1, mode: .solid,
             keys: [MaskKey(t: 0, x: 220, y: 100, w: 50, h: 38)], padding: 0)
    ]
    func blue(_ buffer: CVPixelBuffer, sourcePoint: SIMD2<Double>,
              state: FrameState, style: Style) -> UInt8 {
        let geometry = Geometry(canvas: SIMD2(320, 180), src: SIMD2(320, 180), style: style)
        let canvas = geometry.toCanvas(sourcePoint,
                                       cam: SIMD2(Double(state.cameraCenter.x), Double(state.cameraCenter.y)),
                                       scale: Double(state.cameraScale))
        let x = min(max(Int(canvas.x), 0), 319)
        let y = min(max(Int(canvas.y), 0), 179)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let address = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        return address[y * CVPixelBufferGetBytesPerRow(buffer) + x * 4]
    }
    let protected = try await FrameImage.render(renderer: renderer, session: session, timeline: privacy,
                                                 t: 0.25, canvas: SIMD2(320, 180))
    #expect(blue(protected, sourcePoint: SIMD2(139, 72), state: privacy.evaluate(at: 0.25),
                 style: privacy.style) < 70)
    #expect(blue(protected, sourcePoint: SIMD2(244, 118), state: privacy.evaluate(at: 0.25),
                 style: privacy.style) < 70)
    #expect(blue(a, sourcePoint: SIMD2(139, 72), state: derived.evaluate(at: 0.25),
                 style: derived.style) > 110)

    // The masks are SOURCE-anchored, so even a changing camera zoom cannot
    // expose their original pixels.
    var zoomProtected = privacy
    zoomProtected.camera.autoZoom = false
    zoomProtected.zoom = [ZoomSegment(start: 0, end: 1, scale: 2,
                                      focus: .fixed(x: 0.5, y: 0.5), origin: .manual)]
    zoomProtected = session.derive(zoomProtected, revision: 11)
    let zoomFrame = try await FrameImage.render(renderer: renderer, session: session, timeline: zoomProtected,
                                                t: 0.65, canvas: SIMD2(320, 180))
    #expect(blue(zoomFrame, sourcePoint: SIMD2(139, 72), state: zoomProtected.evaluate(at: 0.65),
                 style: zoomProtected.style) < 70)

    // Caption text and manual subtitles must affect rendered PIXELS, not just
    // live in Codable models. Preview and export call this exact renderer.
    var captioned = derived
    captioned.captions.enabled = true
    captioned.captions.style.size = 0.13
    captioned.captions.style.animation = .none
    captioned.derived?.captions = [CaptionChunk(start: 0, end: 1,
        lines: [[CaptionWord(text: "VISIBLE CAPTION", start: 0, end: 0.8)]], y: 0.5)]
    let captionFrame = try await FrameImage.render(renderer: renderer, session: session, timeline: captioned,
                                                   t: 0.25, canvas: SIMD2(320, 180))
    #expect(pixels(captionFrame) != pixels(a))
    var noWordHighlight = captioned
    noWordHighlight.captions.style.wordHighlight = false
    let plainCaption = try await FrameImage.render(renderer: renderer, session: session, timeline: noWordHighlight,
                                                   t: 0.25, canvas: SIMD2(320, 180))
    #expect(pixels(plainCaption) != pixels(captionFrame))
    var titled = derived
    titled.overlays.texts = [TextBlock(start: 0, end: 1, text: "TITLE", x: 0.5, y: 0.5, size: 0.14)]
    let titleFrame = try await FrameImage.render(renderer: renderer, session: session, timeline: titled,
                                                 t: 0.25, canvas: SIMD2(320, 180))
    #expect(pixels(titleFrame) != pixels(a))

    var patterned = derived
    patterned.style.padding = 0.2
    patterned.style.contentScale = 0.5
    patterned.style.colors = [RGBA(0xFFFFFF), RGBA(0x000000)]
    patterned.style.background = .wave
    let wave = try await FrameImage.render(renderer: renderer, session: session, timeline: patterned, t: 0.25, canvas: SIMD2(320, 180))
    patterned.style.background = .field
    let field = try await FrameImage.render(renderer: renderer, session: session, timeline: patterned, t: 0.25, canvas: SIMD2(320, 180))
    #expect(pixels(wave) != pixels(field))
    patterned.style.colors = [RGBA(0xFFFFFF), RGBA(0xFF6A00)]
    let recolored = try await FrameImage.render(renderer: renderer, session: session, timeline: patterned, t: 0.25, canvas: SIMD2(320, 180))
    #expect(pixels(field) != pixels(recolored))
    let restoredStyle = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(patterned.style))
    #expect(restoredStyle == patterned.style)
    var larger = patterned.style
    larger.contentScale = 2
    let smallGeometry = Geometry(canvas: SIMD2(320, 180), src: SIMD2(320, 180), style: patterned.style)
    let largeGeometry = Geometry(canvas: SIMD2(320, 180), src: SIMD2(320, 180), style: larger)
    #expect(largeGeometry.content.z > smallGeometry.content.z)
    let output = root.appendingPathComponent("export.mp4")
    try await Exporter.run(session: session, timeline: derived, preset: ExportPreset(name: "test", codec: .h264, height: 180, fps: 30), to: output) { _ in }
    let stemOutput = root.appendingPathComponent("stem-export.mp4")
    try await Exporter.run(session: session, timeline: derived,
                           preset: ExportPreset(name: "stem-test", codec: .h264, height: 180, fps: 30),
                           to: stemOutput, exportStems: true) { _ in }
    let wav = root.appendingPathComponent("stem-export-microphone.wav")
    #expect(FileManager.default.fileExists(atPath: wav.path))
    let stemFile = try AVAudioFile(forReading: wav)
    #expect(stemFile.length >= 47_900)
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
    var short = loaded
    short.timeMap.trimEnd = 1.0 / 30
    let shortTimeline = session.derive(short, revision: 2)
    let fourK = root.appendingPathComponent("export-4k.mp4")
    try await Exporter.run(session: session, timeline: shortTimeline,
                           preset: ExportPreset(name: "4k30-h264", codec: .h264, height: 2160, fps: 30), to: fourK) { _ in }
    let fourKAsset = AVURLAsset(url: fourK)
    let fourKTrack = try #require(try await fourKAsset.loadTracks(withMediaType: .video).first)
    let dimensions = try await fourKTrack.load(.naturalSize)
    #expect(dimensions.width == 3840 && dimensions.height == 2160)
    #expect(try await fourKAsset.load(.isPlayable))
    let geometry = Geometry(canvas: SIMD2(180, 320), src: SIMD2(320, 180), style: timeline.style)
    #expect(abs(geometry.content.z / geometry.content.w - 16.0 / 9) < 0.03)
}
