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

// Phase 0 reproduction: caption orientation + cursor accuracy at click frames.
// Writes PNGs to .proof/repro/ for visual inspection via the read tool.
@Test func reproCaptionOrientationAndCursorAccuracy() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try ProjectBundle.create(named: "Repro", in: root)
    let writer = try AVAssetWriter(outputURL: bundle.screenURL, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<30 {
        let buffer = try #require(FrameImage.makeBuffer(640, 360))
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        memset(base, 255, CVPixelBufferGetDataSize(buffer)) // white page = contrast stress
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        _ = adapter.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
    let source = SourceInfo(width: 640, height: 360, fps: 30, duration: 1, backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 1)
    timeline.audio.speedRampsAuto = false
    timeline.audio.clickSounds = false
    timeline.audio.whooshes = false
    timeline.captions.enabled = true
    timeline.captions.style.size = 0.13
    let micSamples = (0..<48_000).map { _ in Float(0) }
    try AudioIO.writeCAF(micSamples, micSamples, to: bundle.micURL)
    var meta = ProjectMeta(name: "Repro", source: source, clock: RecordingClock())
    meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: 0)
    try bundle.save(ProjectFile(meta: meta, timeline: timeline))
    // Cursor: one click at a known pixel
    let events = [InputEvent(t: 0.5, kind: .down, x: 200, y: 150), InputEvent(t: 0.51, kind: .up, x: 200, y: 150)]
    var blob = EventCodec.header()
    for e in events { var b: [UInt8] = []; EventCodec.encode(e, into: &b); blob.append(contentsOf: b) }
    try blob.write(to: bundle.eventsURL)
    let renderer = try Renderer()
    let (session, loaded) = try await ProjectSession.open(bundle, device: renderer.device)
    var derived = session.derive(loaded, revision: 1)
    // Two-line asymmetric caption: line order must read top-first, glyphs upright.
    derived.derived?.captions = [CaptionChunk(start: 0, end: 1, lines: [
        [CaptionWord(text: "Ry 123", start: 0, end: 0.8)],
        [CaptionWord(text: "Gy 456", start: 0, end: 0.8)],
    ], y: 0.75)]
    let outDir = URL(fileURLWithPath: "repro-out")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    // Caption golden: white page, "Ry 123" top line, "Gy 456" bottom line.
    let cap = try await FrameImage.render(renderer: renderer, session: session, timeline: derived, t: 0.25, canvas: SIMD2(640, 360))
    let capURL = outDir.appendingPathComponent("caption-golden.png")
    try FrameImage.writePNG(cap, to: capURL)
    print("caption png: \(capURL.path)")
    // Cursor accuracy at the click frame: drawn cursor position vs raw (200,150).
    let st = derived.evaluate(at: 0.5)
    print("cursor state pos: \(st.cursor.position.x),\(st.cursor.position.y) scale:\(st.cameraScale) center:\(st.cameraCenter.x),\(st.cameraCenter.y)")
    let err = hypot(st.cursor.position.x - 200, st.cursor.position.y - 150)
    print("cursor error px: \(err)")
    #expect(err < 1.0)
    // Mosaic visual: secret card gets synth cells, identity email keeps
    // luminance shape. Rendered, not asserted — judged by eye.
    var masked = derived
    masked.overlays.masks = [
        Mask(start: 0, end: 1, mode: .blur, keys: [MaskKey(t: 0, x: 380, y: 40, w: 220, h: 40)],
             origin: .auto, approved: true, category: "card", padding: 6),
        Mask(start: 0, end: 1, mode: .blur, keys: [MaskKey(t: 0, x: 380, y: 110, w: 220, h: 40)],
             origin: .auto, approved: true, category: "email", padding: 6),
    ]
    let mosaic = try await FrameImage.render(renderer: renderer, session: session, timeline: masked, t: 0.25, canvas: SIMD2(640, 360))
    let mosaicURL = outDir.appendingPathComponent("mosaic.png")
    try FrameImage.writePNG(mosaic, to: mosaicURL)
    print("mosaic png: \(mosaicURL.path)")
    #expect(FileManager.default.fileExists(atPath: capURL.path))
    #expect(FileManager.default.fileExists(atPath: mosaicURL.path))
}
