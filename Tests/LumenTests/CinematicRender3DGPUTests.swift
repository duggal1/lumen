import Foundation
import Testing
import Metal
import CoreVideo
import simd
@testable import LumenRender
@testable import LumenDirector
import LumenProject

// MARK: - Cinematic 3D through the REAL Metal renderer (headless)
//
// Injects a tilted FrameState through RenderRequest.live so a leaked or
// over-limit 3D value is tested at the exact point it would reach export.

private enum C3DGPU {
    /// Metal texture-cache setup is intermittently unavailable under a loaded
    /// test runner. Retry before declaring the environment broken; never turn a
    /// setup failure into a vacuous PASS.
    static func setup(_ attempts: Int = 4) throws -> (Renderer, SourceFrame) {
        var last: (Renderer, SourceFrame)?
        for _ in 0..<attempts {
            if let renderer = try? Renderer() {
                if let frame = stripedFrame(device: renderer.device) {
                    last = (renderer, frame); break
                }
            }
        }
        return try #require(last)
    }

    static func stripedFrame(device: MTLDevice, width: Int = 1920, height: Int = 1080) -> SourceFrame? {
        let attrs = [kCVPixelBufferMetalCompatibilityKey as String: true,
                     kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        var pb: CVPixelBuffer?
        let cr = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb)
        guard cr == kCVReturnSuccess, let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let v: UInt8 = ((x / 4) % 2 == 0) ? 24 : 231
                    row[x * 4 + 0] = v
                    row[x * 4 + 1] = v
                    row[x * 4 + 2] = v
                    row[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var cache: CVMetalTextureCache?
        let c1 = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard c1 == kCVReturnSuccess, let cache else { return nil }
        var cv: CVMetalTexture? = nil
        let c2 = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                                                           width, height, 0, &cv)
        guard c2 == kCVReturnSuccess, let cv, let texture = CVMetalTextureGetTexture(cv) else { return nil }
        return SourceFrame(id: 1, pts: 0, pixelBuffer: buffer, texture: texture, cv: cv)
    }

    static func timeline(_ mode: TiltMode) -> Timeline {
        var tl = Timeline(duration: 1)
        tl.audio.speedRampsAuto = false
        tl.camera.shutter = 0          // one sub-frame: tilt change is isolated
        tl.camera.tilt = mode
        tl.camera.upscaleEnabled = false
        tl.style.background = .solid
        tl.style.colors = [RGBA(0x101010), RGBA(0xDADADA)]
        return tl
    }

    static func pixels(_ renderer: Renderer, _ tl: Timeline, tilt: SIMD2<Float>,
                       canvas: SIMD2<Int>, frame: SourceFrame) -> [UInt8]? {
        var req = RenderRequest(timeline: tl, t: 0.5, screen: frame, canvas: canvas,
                                fps: 60, backingScale: 1, quality: .export)
        let state = FrameState(
            cameraCenter: SIMD2<Float>(Float(frame.texture.width) / 2, Float(frame.texture.height) / 2),
            cameraScale: 1, cameraTilt: tilt,
            cursor: CursorSample(position: .zero, velocity: .zero, opacity: 0, press: 1, shape: 0),
            clickFX: [], webcamCrop: [0, 0, 1, 1], sourceTime: 0)
        req.live = state
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferMetalCompatibilityKey as String: true,
                     kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(nil, canvas.x, canvas.y, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        let done = DispatchSemaphore(value: 0)
        guard renderer.render(req, into: buffer, completion: { done.signal() }) else { return nil }
        guard case .success = done.wait(timeout: .now() + 15) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var out = [UInt8](repeating: 0, count: canvas.x * canvas.y * 4)
        for y in 0..<canvas.y {
            memcpy(&out[y * canvas.x * 4], base.advanced(by: y * stride), canvas.x * 4)
        }
        return out
    }

    static func difference(_ a: [UInt8]?, _ b: [UInt8]?) -> Int {
        guard let a, let b, a.count == b.count else { return -1 }
        var total = 0
        for i in a.indices { total += a[i] > b[i] ? Int(a[i] - b[i]) : Int(b[i] - a[i]) }
        return total
    }
}

@Suite(.serialized)
struct CinematicRender3DGPUTests {

    @Test func offModeDropsLeakedTiltBeforeExport() throws {
        let (renderer, frame) = try C3DGPU.setup()
        let canvas = SIMD2<Int>(256, 256)
        let tl = C3DGPU.timeline(.off)
        let flatMaybe = C3DGPU.pixels(renderer, tl, tilt: .zero, canvas: canvas, frame: frame)
        let leakedMaybe = C3DGPU.pixels(renderer, tl, tilt: SIMD2(12, -6), canvas: canvas, frame: frame)
        #expect(flatMaybe != nil && leakedMaybe != nil)
        let flat = try #require(flatMaybe), leaked = try #require(leakedMaybe)
        #expect(C3DGPU.difference(flat, leaked) == 0,
                "tilt leaked into exported pixels while mode is off")
    }

    @Test func leanWarpsContentAndClampsRawTilt() throws {
        let (renderer, frame) = try C3DGPU.setup()
        let canvas = SIMD2<Int>(256, 256)
        let tl = C3DGPU.timeline(.lean)
        let flatMaybe = C3DGPU.pixels(renderer, tl, tilt: .zero, canvas: canvas, frame: frame)
        let warpedMaybe = C3DGPU.pixels(renderer, tl, tilt: SIMD2(8, 6), canvas: canvas, frame: frame)
        let overLimitMaybe = C3DGPU.pixels(renderer, tl, tilt: SIMD2(99, 99), canvas: canvas, frame: frame)
        #expect(flatMaybe != nil && warpedMaybe != nil && overLimitMaybe != nil)
        let flat = try #require(flatMaybe), warped = try #require(warpedMaybe), overLimit = try #require(overLimitMaybe)
        #expect(C3DGPU.difference(flat, warped) > 500,
                "a real lean must visibly change content pixels")
        #expect(C3DGPU.difference(warped, overLimit) == 0,
                "raw tilt above the limit must be clamped before the shader")
    }

    @Test func revealEntranceDiffersFromSettledAndIsDeterministic() throws {
        let (renderer, frame) = try C3DGPU.setup()
        let canvas = SIMD2<Int>(256, 256)
        let tl = C3DGPU.timeline(.reveal)
        let startMaybe = C3DGPU.pixels(renderer, tl, tilt: SIMD2(12, 0), canvas: canvas, frame: frame)
        let settledMaybe = C3DGPU.pixels(renderer, tl, tilt: .zero, canvas: canvas, frame: frame)
        let againMaybe = C3DGPU.pixels(renderer, tl, tilt: SIMD2(12, 0), canvas: canvas, frame: frame)
        #expect(startMaybe != nil && settledMaybe != nil && againMaybe != nil)
        let start = try #require(startMaybe), settled = try #require(settledMaybe), again = try #require(againMaybe)
        #expect(C3DGPU.difference(start, settled) > 200, "reveal entrance must be tilted")
        #expect(C3DGPU.difference(start, again) == 0, "same request must render identically")
        // The 0.92 content-rect entrance scale was deliberately removed: it
        // was the reported "Zoom shrinks" defect (REBUILD-FORENSICS.md 3.3,
        // commit e95283b). Reveal's entrance now lives in the tilt track
        // (yaw 12 -> 0), applied by the real shader like any other tilt.
        // At equal tilt Lean/Reveal must be identical (no hidden shrink); at
        // the larger entrance yaw Reveal must visibly differ — tilt, not scale.
        let lean = C3DGPU.pixels(renderer, C3DGPU.timeline(.lean), tilt: SIMD2(8, 0),
                                 canvas: canvas, frame: frame)
        let reveal = C3DGPU.pixels(renderer, tl, tilt: SIMD2(8, 0), canvas: canvas, frame: frame)
        #expect(lean != nil && reveal != nil)
        #expect(C3DGPU.difference(lean, reveal) == 0,
                "reveal must not apply a content-scale shrink at equal tilt")
        let revealEntrance = C3DGPU.pixels(renderer, tl, tilt: SIMD2(12, 0),
                                           canvas: canvas, frame: frame)
        #expect(revealEntrance != nil)
        #expect(C3DGPU.difference(lean, revealEntrance) > 50,
                "reveal entrance must differ through tilt, not a content scale")
    }

    @Test func offRenderMatchesFlatForAllModesWithZeroTilt() throws {
        let (renderer, frame) = try C3DGPU.setup()
        let canvas = SIMD2<Int>(256, 256)
        var total = 0
        for mode in TiltMode.allCases {
            let tl = C3DGPU.timeline(mode)
            let zero = C3DGPU.pixels(renderer, tl, tilt: .zero, canvas: canvas, frame: frame)
            let leaked = C3DGPU.pixels(renderer, tl, tilt: SIMD2(12, 6), canvas: canvas, frame: frame)
            if mode == .off {
                #expect(C3DGPU.difference(zero, leaked) == 0, "\(mode) must ignore leaked tilt")
            } else {
                let d = C3DGPU.difference(zero, leaked)
                #expect(d > 0, "\(mode) must apply its tilt")
                total += d
            }
        }
        #expect(total > 0)
    }
}
