import Foundation
import Testing
import Metal
import CoreVideo
import AppKit
import simd
@testable import LumenRender
@testable import LumenDirector
import LumenProject
import LumenCore

// MARK: - Render helpers
//
// Small headless render rig: a uniform source frame, one frame through the real
// Renderer, pixels back. Shared by the cursor and ripple tests.

enum LumenTestRender {
    static func solidFrame(device: MTLDevice, width: Int = 1920, height: Int = 1080) -> SourceFrame? {
        let attrs = [kCVPixelBufferMetalCompatibilityKey as String: true,
                     kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height { memset(base.advanced(by: y * row), 0x38, width * 4) }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        var cv: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &cv) == kCVReturnSuccess,
              let cv, let texture = CVMetalTextureGetTexture(cv) else { return nil }
        return SourceFrame(id: 1, pts: 0, pixelBuffer: buffer, texture: texture, cv: cv)
    }

    /// One frame through the real renderer, returned as RGBA bytes. Uses the
    /// public render entry point so GPU work stays on the renderer's own queue.
    static func pixels(_ renderer: Renderer, timeline: Timeline, t: Double, canvas: SIMD2<Int>,
                       quality: RenderQuality, frame: SourceFrame, live: FrameState? = nil,
                       cursorOnly: Bool = false) -> [UInt8]? {
        let attrs = [kCVPixelBufferMetalCompatibilityKey as String: true,
                     kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, canvas.x, canvas.y, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        var req = RenderRequest(timeline: timeline, t: t, screen: frame, canvas: canvas, fps: 60,
                                backingScale: 2, quality: quality)
        // A cursor-only pass has no opaque backdrop, so the alpha centroid is
        // the cursor itself and not the middle of a filled frame.
        req.cursorOnly = cursorOnly
        req.live = live
        let done = DispatchSemaphore(value: 0)
        guard renderer.render(req, into: buffer, completion: { done.signal() }) else { return nil }
        guard case .success = done.wait(timeout: .now() + 15) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var out = [UInt8](repeating: 0, count: canvas.x * canvas.y * 4)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        for y in 0..<canvas.y {
            memcpy(&out[y * canvas.x * 4], base.advanced(by: y * row), canvas.x * 4)
        }
        return out
    }

    /// Alpha-weighted centroid of a cursor-only frame, in canvas pixels.
    static func alphaCentroid(_ px: [UInt8], canvas: SIMD2<Int>) -> SIMD2<Double>? {
        var sum = 0.0, sx = 0.0, sy = 0.0
        for y in 0..<canvas.y {
            for x in 0..<canvas.x {
                let a = Double(px[(y * canvas.x + x) * 4 + 3])
                if a > 0.004 { sum += a; sx += Double(x) * a; sy += Double(y) * a }
            }
        }
        guard sum > 0 else { return nil }
        return SIMD2(sx / sum, sy / sum)
    }
}

private func stockAtlas(_ pack: CursorPack, customs: [CustomCursor] = []) throws -> (CursorAtlas, MTLDevice) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        throw CursorTestError.noDevice
    }
    guard let atlas = CursorAtlas(device: device, queue: queue, pack: pack, customs: customs) else {
        throw CursorTestError.noAtlas
    }
    return (atlas, device)
}

enum CursorTestError: Error { case noDevice, noAtlas, noLayer }

private func layerPixels(_ atlas: CursorAtlas, layer: Int) -> [UInt8] {
    let n = CursorAtlas.px
    var buf = [UInt8](repeating: 0, count: n * n * 4)
    buf.withUnsafeMutableBytes { p in
        guard let base = p.baseAddress else { return }
        atlas.texture.getBytes(base, bytesPerRow: n * 4, bytesPerImage: n * n * 4,
                                 from: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, slice: layer)
    }
    return buf
}

private func byteHash(_ px: [UInt8]) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in px { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return h
}

// MARK: - Persistence

@Test func cursorClickArtworkSettingsSurviveProjectRoundTrip() throws {
    var style = CursorStyle()
    style.pack = .pro
    style.clickEffect = .burst
    style.clickDuration = 0.72
    style.clickColor = RGBA(0x12ABEF)
    let restored = try JSONDecoder().decode(CursorStyle.self, from: JSONEncoder().encode(style))
    #expect(restored.pack == .pro)
    #expect(restored.clickEffect == .burst)
    #expect(abs(restored.clickDuration - 0.72) < 0.00001)
    #expect(restored.clickColor == RGBA(0x12ABEF))
}

@Test func canvasColorsAndCellSurviveProjectRoundTrip() throws {
    var style = Style()
    style.background = .solid
    style.colors = [RGBA(0x0A0A0A), RGBA(0xFF6A00)]
    style.ditherCell = 7
    style.ditherDensity = 0.42
    let restored = try JSONDecoder().decode(Style.self, from: JSONEncoder().encode(style))
    #expect(restored.colors == style.colors)
    #expect(restored.ditherCell == 7)
    #expect(restored.ditherDensity == 0.42)
    // Legacy JSON without ditherCell must decode to the current default (4),
    // not silently change the saved look on reload.
    let legacy = try JSONSerialization.data(withJSONObject: ["background": "solid", "colors": [["r": 0, "g": 0, "b": 0, "a": 1]]])
    let decoded = try JSONDecoder().decode(Style.self, from: legacy)
    #expect(decoded.ditherCell == Style().ditherCell)
}

@Test func holidayCursorPackLoadsIntoAtlas() throws {
    // Pack survives Codable round-trip (old projects unaffected).
    let restored = try JSONDecoder().decode(CursorPack.self, from: JSONEncoder().encode(CursorPack.holiday))
    #expect(restored == .holiday)
    let (atlas, _) = try stockAtlas(.holiday)
    #expect(atlas.entry(StockCursor.arrow.rawValue) != nil)
    #expect(atlas.entry(StockCursor.pointingHand.rawValue) != nil)
    guard let snow = atlas.entry(StockCursor.arrow.rawValue) else { return }
    #expect(abs(snow.hot.x - 0.5) < 0.05 && abs(snow.hot.y - 0.5) < 0.05, "snowflake hotspot must be centered")
}

// MARK: - Distinct art per stock shape

@Test func everyStockShapeGetsItsOwnArtwork() throws {
    let (atlas, _) = try stockAtlas(.system)
    var hashes: [UInt64] = []
    var layers: [Int] = []
    for shape in StockCursor.allCases {
        guard let entry = atlas.entry(shape.rawValue) else { continue }
        layers.append(entry.layer)
        hashes.append(byteHash(layerPixels(atlas, layer: entry.layer)))
    }
    #expect(hashes.count == StockCursor.allCases.count, "every stock shape resolves to a layer")
    #expect(Set(layers).count == layers.count, "every shape has its own layer")
    #expect(Set(hashes).count == hashes.count,
            "identical artwork for two shapes: \(Set(hashes).count) of \(hashes.count) are distinct")
}

@Test func stylizedPacksKeepOneGlyphForEveryShape() throws {
    for pack in [CursorPack.dot, CursorPack.ring, CursorPack.holiday] {
        let (atlas, _) = try stockAtlas(pack)
        var hashes: Set<UInt64> = []
        for shape in StockCursor.allCases {
            guard let entry = atlas.entry(shape.rawValue) else { continue }
            hashes.insert(byteHash(layerPixels(atlas, layer: entry.layer)))
        }
        // The stylized packs are an explicit user override: one glyph, any shape.
        #expect(hashes.count == 1, "\(pack) must draw one glyph for every shape, got \(hashes.count)")
    }
}

@Test func everyStockShapeHasInkUnderItsHotspot() throws {
    let (atlas, _) = try stockAtlas(.system)
    let n = CursorAtlas.px
    for shape in StockCursor.allCases {
        guard let entry = atlas.entry(shape.rawValue) else { continue }
        let px = layerPixels(atlas, layer: entry.layer)
        let cx = Int((entry.hot.x * Double(n)).rounded()), cy = Int((entry.hot.y * Double(n)).rounded())
        var maxAlpha: UInt8 = 0
        for y in max(cy - 4, 0)...min(cy + 4, n - 1) {
            for x in max(cx - 4, 0)...min(cx + 4, n - 1) {
                maxAlpha = max(maxAlpha, px[(y * n + x) * 4 + 3])
            }
        }
        // A hotspot in empty space would make the click land off the pointer.
        #expect(maxAlpha > 40, "\(shape) hotspot has no ink (max alpha \(maxAlpha))")
    }
}

// MARK: - Cursor state strip (artifact for visual review)

@Test func cursorStateStripIsWrittenForEveryStockShape() throws {
    let (atlas, _) = try stockAtlas(.system)
    let n = CursorAtlas.px
    let scale = 2
    let cell = CursorAtlas.pts * CGFloat(scale)                 // 32 pt at 2x
    let shapes = StockCursor.allCases
    let stripW = Int(cell) * shapes.count, stripH = Int(cell)
    guard let ctx = CGContext(data: nil, width: stripW, height: stripH, bitsPerComponent: 8,
                              bytesPerRow: stripW * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    // Mid grey so the paper rim and the ink both read.
    ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: stripW, height: stripH))
    for (i, shape) in shapes.enumerated() {
        guard let entry = atlas.entry(shape.rawValue) else { continue }
        var px = layerPixels(atlas, layer: entry.layer)
        guard let img: CGImage = px.withUnsafeMutableBytes({ p -> CGImage? in
            guard let base = p.baseAddress else { return nil }
            let c = CGContext(data: base, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            return c?.makeImage()
        }) else { continue }
        // Mark the hotspot with a 1 pt cross so alignment is visible.
        ctx.setStrokeColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1))
        ctx.setLineWidth(1)
        let hx = CGFloat(i) * cell + CGFloat(entry.hot.x) * cell
        let hy = CGFloat(entry.hot.y) * cell
        ctx.move(to: CGPoint(x: hx - 4, y: hy)); ctx.addLine(to: CGPoint(x: hx + 4, y: hy))
        ctx.move(to: CGPoint(x: hx, y: hy - 4)); ctx.addLine(to: CGPoint(x: hx, y: hy + 4))
        ctx.strokePath()
        ctx.draw(img, in: CGRect(x: CGFloat(i) * cell, y: 0, width: cell, height: cell))
    }
    guard let out = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: out)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lumen-cursor-strip.png")
    try png.write(to: url)
    let size = try #require(NSImage(contentsOf: url)?.size)
    print("cursor state strip: \(url.path) (\(Int(size.width))x\(Int(size.height)))")
    #expect(size.width == CGFloat(stripW) && size.height == CGFloat(stripH))
}

// MARK: - Hotspot alignment through the real render path

@Test func hotspotStaysOnTheClickPointUnderZoomAndSizeCompensation() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let renderer = try Renderer()
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 2, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 2)
    tl.audio.speedRampsAuto = false
    // The dot pack's centroid is its hotspot, so the centroid of the rendered
    // sprite is a direct measurement of where the hotspot landed.
    tl.cursor.pack = .dot
    guard let frame = LumenTestRender.solidFrame(device: device) else { return }
    let canvas = SIMD2<Int>(960, 540)
    let g = Geometry(canvas: canvas, src: SIMD2(1920, 1080), style: tl.style)
    let click = SIMD2<Double>(1320, 700)
    for (scale, size) in [(1.0, 1.0), (2.4, 1.0), (1.0, 1.8), (2.4, 1.8)] {
        tl.cursor.size = size
        let st = FrameState(cameraCenter: SIMD2<Float>(Float(click.x), Float(click.y)), cameraScale: Float(scale),
                            cursor: CursorSample(position: SIMD2<Float>(Float(click.x), Float(click.y)), velocity: .zero,
                                                 opacity: 1, press: 1, shape: StockCursor.arrow.rawValue),
                            clickFX: [], webcamCrop: [0, 0, 1, 1], sourceTime: 1.0)
        guard let px = LumenTestRender.pixels(renderer, timeline: tl, t: 1.0, canvas: canvas, quality: .export,
                                              frame: frame, live: st, cursorOnly: true),
              let centroid = LumenTestRender.alphaCentroid(px, canvas: canvas) else { return }
        let expected = g.toCanvas(click, cam: SIMD2(Double(click.x), Double(click.y)), scale: Double(scale))
        let error = hypot(centroid.x - expected.x, centroid.y - expected.y)
        #expect(error < 1.5, "scale \(scale) size \(size): hotspot \(error) px from the click point")
    }
}
@Test func studioCursorInkPersistsAndPreservesLegacyDefault() throws {
    var style = CursorStyle()
    style.ink = RGBA(0x55D3F1)
    let restored = try JSONDecoder().decode(CursorStyle.self, from: JSONEncoder().encode(style))
    #expect(restored.ink == style.ink)
    let legacy = try JSONDecoder().decode(CursorStyle.self, from: Data("{}".utf8))
    #expect(legacy.ink == nil)
}
