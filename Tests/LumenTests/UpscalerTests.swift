import Foundation
import Testing
import Metal
@testable import LumenRender
import LumenProject

/// The "6.5×" claim, measured honestly: the ladder is {2,3,4,6,8} and the
/// default maxFactor is 8, so magnification 6.5 selects 8×. What we can
/// prove is the real output resolution for a given factor — no marketing
/// number without a measurement.
@Test func upscalerFactorLadderAndBlend() {
    #expect(Upscaler.ladder == [2, 3, 4, 5, 6, 8, 10])
    #expect(Upscaler.factor(forMagnification: 1.2, maxFactor: 8) == 2)
    #expect(Upscaler.factor(forMagnification: 2.5, maxFactor: 8) == 3)
    #expect(Upscaler.factor(forMagnification: 6.5, maxFactor: 8) == 8)
    #expect(Upscaler.factor(forMagnification: 6.5, maxFactor: 6) == 6)
    #expect(Upscaler.stages(6) == [2, 3])
    #expect(Upscaler.stages(8) == [2, 2, 2])
    var p = UpscaleParams()
    #expect(Upscaler.blend(forMagnification: 1.0, p) == 0)
    #expect(Upscaler.blend(forMagnification: 3.0, p) == 1)
    p.enabled = false
    #expect(Upscaler.blend(forMagnification: 3.0, p) == 0)
}

@Test func upscalerProducesMeasuredResolution() throws {
    let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device: resolution test cannot run")
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 256, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let source = try #require(device.makeTexture(descriptor: desc))
    let cb = try #require(device.makeCommandQueue()?.makeCommandBuffer(), "No command buffer")
    let result = try up.upscale(cb, source: source, region: SIMD4(0, 0, 256, 256),
                                factor: 6, params: UpscaleParams(), frameID: 42)
    cb.commit()
    cb.waitUntilCompleted()
    // Measured: 256px region at factor 6 -> 1536px output (6.0x, not a claim).
    #expect(result.factor == 6)
    #expect(result.texSize.x == 1536 && result.texSize.y == 1536)
    #expect(Double(result.texSize.x) / 256.0 == 6.0)
}

@Test func upscalerFactorMatrixPerUserSetting() {
    // The user's cap decides the factor, not a fixed "6.5x" claim.
    // cap 5: magnification beyond 5x is capped at 5x
    #expect(Upscaler.factor(forMagnification: 4.5, maxFactor: 5) == 5)
    #expect(Upscaler.factor(forMagnification: 6.0, maxFactor: 5) == 5)
    #expect(Upscaler.factor(forMagnification: 9.0, maxFactor: 5) == 5)
    // cap 8 (default): 6.5x magnification selects 8x
    #expect(Upscaler.factor(forMagnification: 6.5, maxFactor: 8) == 8)
    #expect(Upscaler.factor(forMagnification: 7.0, maxFactor: 8) == 8)
    // cap 10: 9x magnification selects 10x, 4.5x selects 5x
    #expect(Upscaler.factor(forMagnification: 9.0, maxFactor: 10) == 10)
    #expect(Upscaler.factor(forMagnification: 4.5, maxFactor: 10) == 5)
    #expect(Upscaler.factor(forMagnification: 1.1, maxFactor: 10) == 2)
    // Stage decomposition multiplies back to the factor.
    for f in Upscaler.ladder {
        #expect(Upscaler.stages(f).reduce(1, *) == f, "stages for \(f)x must multiply to \(f)")
    }
    #expect(Upscaler.stages(5) == [5])
    #expect(Upscaler.stages(10) == [2, 5])
}

@Test func upscalerRunsInsideFrameBudget() throws {
    // Real-time proof: upscale the actual zoom workload — a 480x270 view
    // region (1920x1080 source at 4x magnification) at 4x — after warmup,
    // and require average GPU time inside a 60fps budget.
    let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device: budget test cannot run")
    let queue = try #require(device.makeCommandQueue(), "No Metal command queue")
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1920, height: 1080, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let source = try #require(device.makeTexture(descriptor: desc))
    var times: [Double] = []
    for i in 0..<20 {
        let cb = try #require(queue.makeCommandBuffer(), "No command buffer")
        let start = Date()
        _ = try up.upscale(cb, source: source, region: SIMD4(0, 0, 480, 270),
                           factor: 4, params: UpscaleParams(), frameID: UInt64(100 + i))
        cb.commit()
        cb.waitUntilCompleted()
        if i >= 5 { times.append(Date().timeIntervalSince(start)) }  // drop pipeline-compile warmup
    }
    let avg = times.reduce(0, +) / Double(times.count)
    let worst = times.max() ?? 0
    #expect(avg < 0.0167, "average upscale \(avg * 1000)ms exceeds 60fps budget")
    #expect(worst < 0.033, "worst upscale \(worst * 1000)ms exceeds 30fps floor")
}

@Test func cropAwareUpscaleUsesTheDisplayedSourcePixels() throws {
    let layout = ContentLayout(canvas: SIMD2(320, 180), contentRect: SIMD4(80, 45, 160, 90),
                               radii: .zero, srcSize: SIMD2(1024, 768),
                               sampledBaseSize: SIMD2(16, 9))
    let uncropped = ContentLayout(canvas: layout.canvas, contentRect: layout.contentRect,
                                  radii: .zero, srcSize: layout.srcSize)
    #expect(uncropped.baseMagnification < 1)
    #expect(layout.baseMagnification == 10)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let kernels = try FXKernels(device: device)
    let upscaler = Upscaler(kernels: kernels)
    let pass = ContentPass(kernels: kernels)
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1024,
                                                        height: 768, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let source = try #require(device.makeTexture(descriptor: desc))
    let queue = try #require(device.makeCommandQueue())
    let cb = try #require(queue.makeCommandBuffer())
    var params = UpscaleParams()
    params.maxFactor = 10
    let prepared = try pass.prepareUpscale(upscaler, cb, layout: layout,
        camCenter: SIMD2(512, 384), zoom: 1, source: source, sourceID: 777,
        params: params, pixelLimit: 524_288)
    let (result, blend) = try #require(prepared)
    cb.commit()
    cb.waitUntilCompleted()
    #expect(cb.status == .completed)
    #expect(result.factor == 10)
    #expect(blend == 1)
    #expect(result.region.x <= 504 && result.region.x + result.region.z >= 520)
    #expect(result.region.y <= 379 && result.region.y + result.region.w >= 389)
    #expect(result.texSize.x >= Float(result.region.z) * result.factor)
    #expect(result.texSize.y >= Float(result.region.w) * result.factor)
}
