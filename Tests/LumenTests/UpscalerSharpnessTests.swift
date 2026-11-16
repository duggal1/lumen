import Foundation
import Testing
import Metal
import simd
@testable import LumenRender
import LumenProject

/// Headless quality contract for the pixel upscaler.
///
/// Resolution tests prove *how big* the output is; these prove *how sharp* it
/// is. A screen recording is mostly one-pixel UI strokes, so a 1 px source
/// stroke must survive a 10x upscale as a crisp, high-contrast line with no
/// halo. Everything is measured on the GPU output read back to the CPU — no
/// window, no display, no golden image file.
private enum Pattern {
    case singleStroke   // one white source pixel on black
    case textStripes    // alternating 1 px on / 1 px off (text-stem spacing)
}

private func sourceTexture(_ device: MTLDevice, width: Int, height: Int,
                           pattern: Pattern) throws -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                     width: width, height: height, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]
    d.storageMode = .shared
    let t = try #require(device.makeTexture(descriptor: d))
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    switch pattern {
    case .singleStroke:
        for y in 0..<height {
            let i = (y * width + width / 2) * 4
            bytes[i] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255; bytes[i + 3] = 255
        }
    case .textStripes:
        for y in height / 4..<(3 * height / 4) {
            for x in 0..<width where x % 2 == 0 {
                let i = (y * width + x) * 4
                bytes[i] = 255; bytes[i + 1] = 255; bytes[i + 2] = 255; bytes[i + 3] = 255
            }
        }
    }
    t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
              withBytes: bytes, bytesPerRow: width * 4)
    return t
}

private func readback(_ device: MTLDevice, _ cb: MTLCommandBuffer,
                      _ texture: MTLTexture) throws -> [UInt8] {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                     width: texture.width, height: texture.height,
                                                     mipmapped: false)
    d.usage = [.shaderRead]
    d.storageMode = .shared
    let dst = try #require(device.makeTexture(descriptor: d))
    guard let blit = cb.makeBlitCommandEncoder() else { return [] }
    blit.copy(from: texture,
              sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
              to: dst, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    dst.getBytes(&bytes, bytesPerRow: texture.width * 4,
                 from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    return bytes
}

private func luma(_ bytes: [UInt8], _ stride: Int, _ x: Int, _ y: Int) -> Double {
    let i = (y * stride + x) * 4
    return (54.0 * Double(bytes[i]) + 183.0 * Double(bytes[i + 1]) + 19.0 * Double(bytes[i + 2])) / 256.0
}

/// A one-pixel stroke must not melt into a grey smear at 10x. Guards peak
/// contrast, the width of the bright core, the transition width and ringing.
@Test func upscalerKeepsSinglePixelStrokesCrispAtTenX() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let s = 64, factor = 10
    let source = try sourceTexture(device, width: s, height: s, pattern: .singleStroke)
    guard let cb = queue.makeCommandBuffer() else { return }
    let result = try up.upscale(cb, source: source, region: SIMD4(0, 0, Int32(s), Int32(s)),
                                factor: factor, params: UpscaleParams(), frameID: 9001)
    let bytes = try readback(device, cb, result.texture)
    let stride = result.texture.width, row = stride / 2 - 9   // away from any horizontal feature
    let center = stride / 2 + factor / 2

    var peak = 0.0
    for x in 0..<stride { peak = max(peak, luma(bytes, stride, x, row)) }
    var core = 0, halo = 0.0
    for x in 0..<stride {
        let v = luma(bytes, stride, x, row)
        if v >= 0.8 * peak { core += 1 }
        if abs(x - center) > factor + 4 { halo = max(halo, v) }
    }
    var rise = 0
    for x in 0..<stride {
        let v = luma(bytes, stride, x, row)
        if v >= 0.1 * peak { rise = 1 }
        if rise > 0 {
            rise += 1
            if v >= 0.9 * peak { break }
        }
    }
    print("SHARP stroke: peak=\(Int(peak)) core=\(core) rise=\(rise) halo=\(Int(halo))")
    #expect(peak >= 230, "1 px stroke lost contrast: peak \(Int(peak))")
    #expect(core >= factor - 3 && core <= factor + 5, "stroke smeared: core \(core) px for \(factor)x")
    #expect(rise <= 3, "edge too soft: 10-90% rise \(rise) px at \(factor)x")
    #expect(halo <= 16, "ringing/halo outside the stroke: \(Int(halo))")
}

/// Text stems alternate every source pixel. A high-quality kernel keeps that
/// Nyquist-rate modulation instead of blurring it to flat grey.
@Test func upscalerKeepsTextStemContrastAtTenX() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let s = 64, factor = 10
    let source = try sourceTexture(device, width: s, height: s, pattern: .textStripes)
    guard let cb = queue.makeCommandBuffer() else { return }
    let result = try up.upscale(cb, source: source, region: SIMD4(0, 0, Int32(s), Int32(s)),
                                factor: factor, params: UpscaleParams(), frameID: 9002)
    let bytes = try readback(device, cb, result.texture)
    let stride = result.texture.width, row = stride / 2
    var lo = 255.0, hi = 0.0
    for x in stride / 8..<(7 * stride / 8) {
        let v = luma(bytes, stride, x, row)
        lo = min(lo, v); hi = max(hi, v)
    }
    let contrast = (hi - lo) / (hi + lo)
    print("SHARP stripes: lo=\(Int(lo)) hi=\(Int(hi)) contrast=\(String(format: "%.3f", contrast))")
    #expect(contrast >= 0.85, "text stems blurred to grey: Michelson contrast \(contrast)")
}
