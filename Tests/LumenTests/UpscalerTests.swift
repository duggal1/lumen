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
    #expect(Upscaler.ladder == [2, 3, 4, 6, 8])
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
