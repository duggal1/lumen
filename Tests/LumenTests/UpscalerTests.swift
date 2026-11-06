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
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 256, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let source = try #require(device.makeTexture(descriptor: desc))
    guard let cb = device.makeCommandQueue()?.makeCommandBuffer() else { return }
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
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1920, height: 1080, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    desc.storageMode = .shared
    let source = try #require(device.makeTexture(descriptor: desc))
    var times: [Double] = []
    for i in 0..<20 {
        guard let cb = queue.makeCommandBuffer() else { return }
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
