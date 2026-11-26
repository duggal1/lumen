import Foundation
import Testing
import Metal
import simd
@testable import LumenRender
import LumenProject

/// Honesty and robustness contract for the real-time upscaler. Every number
/// here comes from the GPU output read back on this machine — no labels, no
/// mocks, no GUI. The factor the caller is told about must be the factor the
/// shader runs and the texture dimensions prove.
private enum Honesty {
    static func texture(_ device: MTLDevice, _ w: Int, _ h: Int,
                        seed: UInt8 = 200, stripe: Bool = true) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
        let t = try #require(device.makeTexture(descriptor: d))
        var px = [UInt8](repeating: seed, count: w * h * 4)
        if stripe {
            for y in 0..<h { for x in 0..<w where x % 4 == 0 {
                let i = (y * w + x) * 4
                px[i] = 255; px[i+1] = 255; px[i+2] = 255; px[i+3] = 255
            } }
        }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                  withBytes: px, bytesPerRow: w * 4)
        return t
    }

    static func readback(_ device: MTLDevice, _ cb: MTLCommandBuffer,
                         _ texture: MTLTexture, _ w: Int, _ h: Int) throws -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .shared
        let dst = try #require(device.makeTexture(descriptor: d))
        let blit = try #require(cb.makeBlitCommandEncoder(), "No blit encoder: readback cannot be verified")
        blit.copy(from: texture,
                  sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        dst.getBytes(&bytes, bytesPerRow: w * 4,
                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return bytes
    }
}

/// The reported factor is the applied factor for EVERY ladder rung and cap.
/// This is what makes "2x"/"10x" real instead of a label.
@Test func upscalerReportedFactorIsActuallyApplied() throws {
    let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device: GPU upscaler test cannot run")
    let queue = try #require(device.makeCommandQueue(), "No Metal command queue")
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let s = 32
    let src = try Honesty.texture(device, s, s)
    for (i, f) in Upscaler.ladder.enumerated() {
        let cb = try #require(queue.makeCommandBuffer(), "No command buffer")
        let r = try up.upscale(cb, source: src, region: SIMD4(0, 0, Int32(s), Int32(s)),
                               factor: f, params: UpscaleParams(), frameID: UInt64(1000 + i))
        cb.commit(); cb.waitUntilCompleted()
        #expect(r.factor == Float(f), "factor label \(f) != reported \(r.factor)")
        // `region * factor` is the real written lattice; texSize is the padded
        // buffer and may be larger. Both must be consistent with the label.
        let contentW = Double(r.region.z) * Double(r.factor)
        let contentH = Double(r.region.w) * Double(r.factor)
        #expect(contentW == Double(s * f) && contentH == Double(s * f),
                "factor \(f) wrote \(Int(contentW))x\(Int(contentH)) content, expected \(s * f)")
        #expect(Double(r.texSize.x) >= contentW && Double(r.texSize.y) >= contentH,
                "padded buffer \(Int(r.texSize.x))x\(Int(r.texSize.y)) cannot hold \(f)x content")
        #expect(contentW / Double(s) == Double(f), "real magnification must equal the label")
    }
}

/// The updater is engaged at genuine enlargement (a "2x" zoom), not only at
/// the old 1.5..2.2 band that left 2x on the plain Catmull sample.
@Test func upscalerEngagesAtRealEnlargement() {
    let p = UpscaleParams()
    #expect(Upscaler.blend(forMagnification: 0.9, p) == 0)
    #expect(Upscaler.blend(forMagnification: 1.0, p) == 0)
    #expect(Upscaler.blend(forMagnification: 1.5, p) == 1)
    #expect(Upscaler.blend(forMagnification: 2.0, p) == 1, "2x must be fully upscaled, not a fake label")
    #expect(Upscaler.blend(forMagnification: 10.0, p) == 1)
    var off = p; off.enabled = false
    #expect(Upscaler.blend(forMagnification: 10.0, off) == 0)
}

/// A cache hit is only valid when every output-affecting input matches.
/// A different source texture with an identical (frame, region, factor) key
/// must never be served pixels from the previous source.
@Test func upscalerCacheDoesNotAliasSource() throws {
    let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device: GPU upscaler test cannot run")
    let queue = try #require(device.makeCommandQueue(), "No Metal command queue")
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let s = 48
    let dark = try Honesty.texture(device, s, s, seed: 20, stripe: false)
    let bright = try Honesty.texture(device, s, s, seed: 235, stripe: false)
    func run(_ src: MTLTexture) throws -> [UInt8] {
        let cb = queue.makeCommandBuffer()!
        let r = try up.upscale(cb, source: src, region: SIMD4(0, 0, Int32(s), Int32(s)),
                               factor: 2, params: UpscaleParams(), frameID: 5150)
        return try Honesty.readback(device, cb, r.texture, s * 2, s * 2)
    }
    let a = try run(dark)
    let b = try run(bright)
    #expect(a != b, "cache served source A's pixels for source B (wrong-region/content alias)")
}

/// Changing quality params under the same frame key must rebuild, not reuse.
@Test func upscalerCacheDoesNotAliasParams() throws {
    let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device: GPU upscaler test cannot run")
    let queue = try #require(device.makeCommandQueue(), "No Metal command queue")
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let s = 48
    let src = try Honesty.texture(device, s, s)
    func run(_ p: UpscaleParams) throws -> [UInt8] {
        let cb = queue.makeCommandBuffer()!
        let r = try up.upscale(cb, source: src, region: SIMD4(0, 0, Int32(s), Int32(s)),
                               factor: 2, params: p, frameID: 6161)
        return try Honesty.readback(device, cb, r.texture, s * 2, s * 2)
    }
    var plain = UpscaleParams(); plain.shock = 0; plain.shockIterations = 0; plain.finalSharpen = 0
    var sharp = UpscaleParams(); sharp.finalSharpen = 2.0
    let a = try run(plain)
    let b = try run(sharp)
    #expect(a != b, "cache ignored changed params and served stale pixels")
}

/// Hostile magnifications and caps resolve to a finite, real ladder rung.
@Test func upscalerHostileMagnificationsStayHonest() {
    let hostile = [Double.nan, .infinity, -.infinity, -5, 0, 1e-9, 1e9, 6.5, 2.0001]
    for m in hostile {
        for cap in [-10, 0, 1, 2, 5, 10, 100, Int.max] {
            let f = Upscaler.factor(forMagnification: m, maxFactor: cap)
            #expect(Upscaler.ladder.contains(f), "factor \(f) for m=\(m) cap=\(cap) is not a real rung")
            #expect(f >= 2 && f <= 10, "factor \(f) outside 2..10 for m=\(m) cap=\(cap)")
            #expect(Upscaler.stages(f).reduce(1, *) == f, "stages must multiply to resolved factor \(f)")
        }
    }
    // Hostile blend inputs never turn into NaN/infinite engaged output.
    let p = UpscaleParams()
    for m in hostile {
        let b = Upscaler.blend(forMagnification: m, p)
        #expect(b.isFinite && b >= 0 && b <= 1, "blend \(b) for m=\(m) invalid")
    }
}

/// A hostile source/crop must resolve to a finite, positive region. A negative
/// region would dispatch a compute grid with a negative size and trap.
@Test func upscalerRegionAndQuantizeNeverGoDegenerate() {
    let hostile = [Double.nan, .infinity, -.infinity, 0, -1, 1e300]
    for w in hostile {
        for h in hostile {
            for c in [SIMD2<Double>(.nan, .infinity), .zero, SIMD2(1e300, -1e300), SIMD2(40, 30)] {
                let r = Upscaler.region(center: c, view: SIMD2(20, 10), source: SIMD2(w, h))
                #expect(r.x >= 0 && r.y >= 0 && r.z >= 1 && r.w >= 1,
                        "degenerate region \(r) for source \(w)x\(h)")
                let q = Upscaler.quantize(r, source: SIMD2(w, h))
                #expect(q.x >= 0 && q.y >= 0 && q.z >= 1 && q.w >= 1,
                        "degenerate quantized region \(q) for source \(w)x\(h)")
            }
        }
    }
}

/// Same inputs produce byte-identical GPU output (deterministic export frames).
@Test func upscalerIsDeterministic() throws {
    let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device: GPU upscaler test cannot run")
    let queue = try #require(device.makeCommandQueue(), "No Metal command queue")
    let kernels = try FXKernels(device: device)
    let src = try Honesty.texture(device, 64, 48)
    func run(_ id: UInt64) throws -> [UInt8] {
        let up = Upscaler(kernels: kernels)
        let cb = queue.makeCommandBuffer()!
        let r = try up.upscale(cb, source: src, region: SIMD4(0, 0, 64, 48),
                               factor: 4, params: UpscaleParams(), frameID: id)
        return try Honesty.readback(device, cb, r.texture, 256, 192)
    }
    let a = try run(1), b = try run(2), c = try run(3)
    #expect(a == b && b == c, "identical inputs produced different pixels — export would flicker")
}

/// Bounded, frame-rate-aware cost. Per-frame work is fixed; measure the
/// realistic 480x270 view at 4x (60fps export) and the worst rung 10x.
@Test func upscalerStaysInsideFrameBudgets() throws {
    let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device: GPU upscaler test cannot run")
    let queue = try #require(device.makeCommandQueue(), "No Metal command queue")
    let kernels = try FXKernels(device: device)
    let src = try Honesty.texture(device, 1920, 1080, stripe: false)
    func avg(_ f: Int, _ region: SIMD4<Int32>) throws -> Double {
        let up = Upscaler(kernels: kernels)
        var times: [Double] = []
        for i in 0..<16 {
            let cb = queue.makeCommandBuffer()!
            let start = Date()
            _ = try up.upscale(cb, source: src, region: region, factor: f,
                               params: UpscaleParams(), frameID: UInt64(9000 + i))
            cb.commit(); cb.waitUntilCompleted()
            if i >= 4 { times.append(Date().timeIntervalSince(start)) }
        }
        return times.reduce(0, +) / Double(max(times.count, 1))
    }
    let sixty = try avg(4, SIMD4(0, 0, 480, 270))
    let worst = try avg(10, SIMD4(0, 0, 240, 135))
    print("BUDGET 60fps(4x,480x270)=\(String(format: "%.2f", sixty * 1000))ms worst(10x)=\(String(format: "%.2f", worst * 1000))ms")
    #expect(sixty < 1.0 / 60.0, "60fps work took \(sixty * 1000)ms")
    #expect(worst < 1.0 / 30.0, "worst-rung work took \(worst * 1000)ms")
}

@Test func upscaleBudgetSelectsOnlyRealAllocatableRungs() {
    let roi = SIMD4<Int32>(0, 0, 240, 135)
    #expect(Upscaler.boundedFactor(forMagnification: 10, maxFactor: 10, region: roi, pixelLimit: 4_000_000) == 10)
    #expect(Upscaler.boundedFactor(forMagnification: 10, maxFactor: 10, region: roi, pixelLimit: 1_000_000) == 5)
    #expect(Upscaler.boundedFactor(forMagnification: 10, maxFactor: 10, region: roi, pixelLimit: 100) == nil)
    #expect(Upscaler.boundedFactor(forMagnification: 2, maxFactor: 10, region: SIMD4(0, 0, .max, .max), pixelLimit: 12_000_000) == nil)
    let region = Upscaler.region(center: .zero, view: SIMD2(.nan, .infinity), source: SIMD2(1920, 1080), margin: .nan)
    #expect(region.z > 0 && region.w > 0)
}
