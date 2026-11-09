import Testing
import Foundation
import Metal
import AVFoundation
import CoreGraphics
import LumenCore
import LumenProject
import LumenDirector
@testable import LumenRender
import LumenAudio
import LumenExport

/// Rendered proofs for the compositor-only frontend work: the caption card is
/// a real blurred material with guaranteed white-text contrast, the ripple is
/// centred on the click and soft-edged, and the mosaic is crisp source-space
/// cells that cover the field and never leak outside it.

private let out = URL(fileURLWithPath: "repro-out")

private struct Fixture {
    let bundle: ProjectBundle
    let session: ProjectSession
    var timeline: Timeline
    let renderer: Renderer
}

private func makeFixture(w: Int = 640, h: Int = 360,
                         draw: (CGContext, Int, Int) -> Void) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bundle = try ProjectBundle.create(named: "Visual", in: root)
    let writer = try AVAssetWriter(outputURL: bundle.screenURL, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    ])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<30 {
        let buffer = try #require(FrameImage.makeBuffer(w, h))
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer),
           let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            draw(ctx, w, h)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        _ = adapter.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()

    let source = SourceInfo(width: w, height: h, fps: 30, duration: 1, backingScale: 1, originX: 0, originY: 0)
    var timeline = Timeline(duration: 1)
    timeline.audio.speedRampsAuto = false
    timeline.audio.clickSounds = false
    timeline.audio.whooshes = false
    // Identity geometry for the proofs: no padding, no auto-zoom, so source
    // pixels map 1:1 to canvas pixels and the ripple centroid/mosaic field
    // can be asserted in absolute pixels. Production padding/zoom stay
    // exercised by the geometry-aware caption probe.
    timeline.style.padding = 0
    timeline.camera.autoZoom = false
    let zeros = [Float](repeating: 0, count: 48_000)
    try AudioIO.writeCAF(zeros, zeros, to: bundle.micURL)
    var meta = ProjectMeta(name: "Visual", source: source, clock: RecordingClock())
    meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: 0)
    try bundle.save(ProjectFile(meta: meta, timeline: timeline))
    // Before the 0.8 s end cutoff in Cursor.run, or the click is dropped.
    let events = [InputEvent(t: 0.15, kind: .down, x: 400, y: 200),
                  InputEvent(t: 0.16, kind: .up, x: 400, y: 200)]
    var blob = EventCodec.header()
    for e in events { var b: [UInt8] = []; EventCodec.encode(e, into: &b); blob.append(contentsOf: b) }
    try blob.write(to: bundle.eventsURL)

    let renderer = try Renderer()
    let (session, loaded) = try await ProjectSession.open(bundle, device: renderer.device)
    let derived = session.derive(loaded, revision: 1)
    return Fixture(bundle: bundle, session: session, timeline: derived, renderer: renderer)
}

private func checkerboard(_ ctx: CGContext, _ w: Int, _ h: Int) {
    let tones: [CGColor] = [
        CGColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1),
        CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        CGColor(red: 0.95, green: 0.35, blue: 0.05, alpha: 1),
        CGColor(red: 0.10, green: 0.35, blue: 0.95, alpha: 1),
    ]
    let cell = 40
    for y in stride(from: 0, to: h, by: cell) {
        for x in stride(from: 0, to: w, by: cell) {
            ctx.setFillColor(tones[((x / cell) + (y / cell)) % tones.count])
            ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
        }
    }
}

private func luma(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
    func linear(_ v: UInt8) -> Double {
        let c = Double(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
}

private struct RGBA8 { var r: UInt8, g: UInt8, b: UInt8, a: UInt8 }

private func pixels(_ pb: CVPixelBuffer, _ body: (UnsafeMutableRawPointer, Int, Int) -> Void) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
    body(base, CVPixelBufferGetBytesPerRow(pb), CVPixelBufferGetWidth(pb))
}

private func sample(_ base: UnsafeMutableRawPointer, _ row: Int, _ x: Int, _ y: Int) -> RGBA8 {
    let p = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
    return RGBA8(r: p[2], g: p[1], b: p[0], a: p[3])
}

private func diff(_ a: CVPixelBuffer, _ b: CVPixelBuffer, _ body: (Int, Int, Int) -> Void) {
    let w = CVPixelBufferGetWidth(a), h = CVPixelBufferGetHeight(a)
    pixels(a) { pa, ra, _ in
        pixels(b) { pb, rb, _ in
            for y in 0..<h {
                for x in 0..<w {
                    let x1 = sample(pa, ra, x, y), x2 = sample(pb, rb, x, y)
                    let d = abs(Int(x1.r) - Int(x2.r)) + abs(Int(x1.g) - Int(x2.g)) + abs(Int(x1.b) - Int(x2.b))
                    body(x, y, d)
                }
            }
        }
    }
}

@Test func captionCardIsABlurredMaterialWithWhiteTextContrast() async throws {
    var f = try await makeFixture(draw: checkerboard)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    f.timeline.captions.enabled = true
    f.timeline.captions.style.size = 0.13
    f.timeline.captions.style.animation = .none
    f.timeline.captions.style.wordHighlight = false
    let chunk = CaptionChunk(start: 0, end: 1, lines: [
        [CaptionWord(text: "Ry 123", start: 0, end: 1)],
        [CaptionWord(text: "Gy 456", start: 0, end: 1)],
    ], y: 0.75)
    f.timeline.derived?.captions = [chunk]

    // Ask the shared raster cache where the card actually is, so the proof
    // samples the material behind the text rather than guessing a rectangle.
    let geo = Geometry(canvas: SIMD2(640, 360), src: SIMD2(640, 360), style: f.timeline.style)
    let cache = TextOverlayCache()
    let sprite = try #require(cache.caption(chunk, style: f.timeline.captions.style, time: 0.25,
                                            canvas: SIMD2(640, 360), videoRect: geo.content,
                                            device: f.renderer.device))
    let cardW = Float(sprite.texture.width), cardH = Float(sprite.texture.height)
    let card = CGRect(x: Double(sprite.center.x - cardW / 2), y: Double(sprite.center.y - cardH / 2),
                      width: Double(cardW), height: Double(cardH))

    let frame = try await FrameImage.render(renderer: f.renderer, session: f.session, timeline: f.timeline,
                                            t: 0.25, canvas: SIMD2(640, 360))
    try FrameImage.writePNG(frame, to: out.appendingPathComponent("caption-busy.png"))

    // Sample the card's padding, never a glyph. The left and right bands are
    // 15 px wide at this font size; 4...10 px inside is pure material.
    var worst = 0.0
    var adjacent = 0.0
    var adjacentCount = 0
    var maxStep = 0.0
    let x0 = Int(card.minX) + 4, x1 = Int(card.minX) + 10
    let x2 = Int(card.maxX) - 10, x3 = Int(card.maxX) - 4
    let inset = Int((sprite.card?.radius ?? 8) + 4)
    let bandX = Int(card.minX) + 7
    pixels(frame) { base, row, _ in
        for y in (Int(card.minY) + inset)..<(Int(card.maxY) - inset) {
            for x in x0..<x1 { let c = sample(base, row, x, y); worst = max(worst, luma(c.r, c.g, c.b)) }
            for x in x2..<x3 { let c = sample(base, row, x, y); worst = max(worst, luma(c.r, c.g, c.b)) }
        }
        // Down a side padding band proves the material is blurred. The band
        // crosses two checkerboard edges: sharp glass would jump ~200 in one
        // pixel at each edge (max step ~255, mean over ~106 px ~4). The mip-
        // blurred card spreads each edge over ~16 px, so the worst single
        // step is <40 and the mean is ~1. The old 0.08 bound required <9
        // total variation for the whole column, which no edge — blurred or
        // sharp — can satisfy, so it measured "no edge", not blur.
        for y in ((Int(card.minY) + inset + 1)..<(Int(card.maxY) - inset)) {
            let a = sample(base, row, bandX, y - 1), b = sample(base, row, bandX, y)
            let dr = abs(Double(a.r) - Double(b.r)), dg = abs(Double(a.g) - Double(b.g)), db = abs(Double(a.b) - Double(b.b))
            adjacent += dr + dg + db
            adjacentCount += 3
            maxStep = max(maxStep, dr, dg, db)
        }
    }
    let contrast = 1.05 / (worst + 0.05)
    // White text needs 4.5:1; 0.18 relative luminance is the hard ceiling.
    #expect(worst <= 0.18, "card material luma \(worst)")
    #expect(contrast >= 4.5, "white text contrast \(contrast)")
    #expect(maxStep < 60, "material has a hard edge: max step \(maxStep)")
    #expect(adjacent / Double(max(adjacentCount, 1)) < 2.0, "material is not blurred")
}

@Test func captionGlyphLineOrderAndOrientationAreUpright() async throws {
    var f = try await makeFixture { _, _, _ in }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    f.timeline.captions.enabled = true
    f.timeline.captions.style.size = 0.13
    f.timeline.captions.style.animation = .none
    f.timeline.captions.style.wordHighlight = false
    let chunk = CaptionChunk(start: 0, end: 1, lines: [
        [CaptionWord(text: "WWWWWW", start: 0, end: 1)],
        [CaptionWord(text: "......", start: 0, end: 1)],
    ], y: 0.75)
    f.timeline.derived?.captions = [chunk]
    let frame = try await FrameImage.render(renderer: f.renderer, session: f.session, timeline: f.timeline,
                                            t: 0.25, canvas: SIMD2(640, 360))
    try FrameImage.writePNG(frame, to: out.appendingPathComponent("caption-orientation.png"))

    let geo = Geometry(canvas: SIMD2(640, 360), src: SIMD2(640, 360), style: f.timeline.style)
    let cache = TextOverlayCache()
    let sprite = try #require(cache.caption(chunk, style: f.timeline.captions.style, time: 0.25,
                                            canvas: SIMD2(640, 360), videoRect: geo.content,
                                            device: f.renderer.device))
    let w = Float(sprite.texture.width), h = Float(sprite.texture.height)
    let rect = CGRect(x: Double(sprite.center.x - w / 2), y: Double(sprite.center.y - h / 2),
                      width: Double(w), height: Double(h))
    var top = 0, bottom = 0
    let topRange = Int(rect.minY + rect.height * 0.14)..<Int(rect.minY + rect.height * 0.42)
    let bottomRange = Int(rect.minY + rect.height * 0.58)..<Int(rect.minY + rect.height * 0.86)
    pixels(frame) { base, row, _ in
        for y in topRange {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let c = sample(base, row, x, y)
                if luma(c.r, c.g, c.b) > 0.6 { top += 1 }
            }
        }
        for y in bottomRange {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let c = sample(base, row, x, y)
                if luma(c.r, c.g, c.b) > 0.6 { bottom += 1 }
            }
        }
    }
    // Wide caps on the first line, dots on the second. A vertical flip would
    // put the dots on top.
    #expect(top > bottom * 2, "top \(top) bottom \(bottom)")
}

@Test func rippleIsCentredOnTheClickAndSettles() async throws {
    var f = try await makeFixture { ctx, w, h in
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    // Hide the cursor body so its opaque silhouette cannot occlude the
    // south crest and drag the centroid: the ring proof measures ripple
    // energy alone.
    if var d = f.timeline.derived {
        for i in d.cursor.opacity.indices { d.cursor.opacity[i] = 0 }
        f.timeline.derived = d
    }
    f.timeline.cursor.clickEffect = .none
    let base = try await FrameImage.render(renderer: f.renderer, session: f.session, timeline: f.timeline,
                                           t: 0.27, canvas: SIMD2(640, 360))
    f.timeline.cursor.clickEffect = .ripple
    f.timeline.cursor.clickDuration = 0.55
    f.timeline.cursor.clickColor = RGBA(0xFFFFFF, a: 0)
    let early = try await FrameImage.render(renderer: f.renderer, session: f.session, timeline: f.timeline,
                                            t: 0.27, canvas: SIMD2(640, 360))
    // Settle probe uses the same source frame as its clean twin, so the
    // H.264 codec noise between different timestamps cannot fake energy.
    f.timeline.cursor.clickEffect = .none
    let baseLate = try await FrameImage.render(renderer: f.renderer, session: f.session, timeline: f.timeline,
                                               t: 0.85, canvas: SIMD2(640, 360))
    f.timeline.cursor.clickEffect = .ripple
    let late = try await FrameImage.render(renderer: f.renderer, session: f.session, timeline: f.timeline,
                                           t: 0.85, canvas: SIMD2(640, 360))
    try FrameImage.writePNG(early, to: out.appendingPathComponent("ripple-early.png"))
    try FrameImage.writePNG(late, to: out.appendingPathComponent("ripple-late.png"))

    var total = 0, energy = 0.0, cx = 0.0, cy = 0.0
    diff(base, early) { x, y, d in
        guard x > 300, x < 500, y > 100, y < 300 else { return }
        total += d
        energy += Double(d)
        cx += Double(x) * Double(d)
        cy += Double(y) * Double(d)
    }
    #expect(total > 1_000, "no visible ripple: \(total)")
    let centerX = cx / max(energy, 1), centerY = cy / max(energy, 1)
    #expect(hypot(centerX - 400, centerY - 200) < 2.0, "ripple centroid \(centerX),\(centerY)")
    var lateTotal = 0
    diff(baseLate, late) { x, y, d in
        guard x > 300, x < 500, y > 100, y < 300 else { return }
        lateTotal += d
    }
    #expect(lateTotal < total, "ripple does not settle: early \(total) late \(lateTotal)")
}

@Test func mosaicCoversItsFieldWithCrispSourceCells() async throws {
    var f = try await makeFixture { ctx, _, h in
        // A left-to-right ramp inside the mask field. Identity mosaic must
        // render it as discrete steps, not a smooth gradient or a slab.
        // CGContext is bottom-left, masks are source top-left, so flip y.
        let top: CGFloat = 40, fieldH: CGFloat = 40
        let y: CGFloat = CGFloat(h) - top - fieldH
        for x in stride(from: 380, to: 600, by: 4) {
            let t: CGFloat = CGFloat(x - 380) / 220
            ctx.setFillColor(CGColor(gray: t, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(x), y: y, width: 4, height: fieldH))
        }
    }
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let region = Mask(start: 0, end: 1, mode: .blur,
                      keys: [MaskKey(t: 0, x: 380, y: 40, w: 220, h: 40)],
                      origin: .auto, approved: true, category: "email", padding: 6)
    f.timeline.overlays.masks = [region]
    let masked = try await FrameImage.render(renderer: f.renderer, session: f.session, timeline: f.timeline,
                                             t: 0.25, canvas: SIMD2(640, 360))
    try FrameImage.writePNG(masked, to: out.appendingPathComponent("mosaic-identity.png"))
    f.timeline.overlays.masks[0].category = "card"
    let secret = try await FrameImage.render(renderer: f.renderer, session: f.session, timeline: f.timeline,
                                             t: 0.25, canvas: SIMD2(640, 360))
    try FrameImage.writePNG(secret, to: out.appendingPathComponent("mosaic-secret.png"))

    f.timeline.overlays.masks = []
    let clean = try await FrameImage.render(renderer: f.renderer, session: f.session, timeline: f.timeline,
                                            t: 0.25, canvas: SIMD2(640, 360))
    try FrameImage.writePNG(clean, to: out.appendingPathComponent("mosaic-clean.png"))

    var outside = 0, inside = 0
    diff(clean, masked) { x, y, d in
        let inField = x >= 380 && x < 600 && y >= 40 && y < 80
        // The padded rect is 6 px beyond the key on each side (374..606,
        // 34..86). Allow 10 px so the padded edge itself is not "outside".
        let near = x >= 370 && x < 610 && y >= 30 && y < 90
        if inField { inside += d } else if !near { outside += d }
    }
    #expect(outside == 0, "mask changed pixels outside its field: \(outside)")
    #expect(inside > 10_000, "mask did not cover the field: \(inside)")

    // Each source-space cell is one flat colour. A row across the field may
    // only change at cell edges: 220 / 36 px is about seven cells. The
    // 8-bit write dithers flat cells by 1 LSB, so equal means within 2.
    func isNew(_ a: RGBA8, _ b: RGBA8) -> Bool {
        abs(Int(a.r) - Int(b.r)) > 2 || abs(Int(a.g) - Int(b.g)) > 2 || abs(Int(a.b) - Int(b.b)) > 2
    }
    var runs = 1
    var last: RGBA8?
    pixels(masked) { base, row, _ in
        for x in 382..<598 {
            let c = sample(base, row, x, 60)
            if let l = last, isNew(l, c) { runs += 1 }
            last = c
        }
    }
    #expect(runs <= 9, "identity mosaic is not made of crisp cells: \(runs) runs")

    var secretRuns = 1
    var lastSecret: RGBA8?
    pixels(secret) { base, row, _ in
        for x in 382..<598 {
            let c = sample(base, row, x, 60)
            if let l = lastSecret, isNew(l, c) { secretRuns += 1 }
            lastSecret = c
        }
    }
    #expect(secretRuns <= 7, "secret mosaic is not made of crisp cells: \(secretRuns) runs")
}
