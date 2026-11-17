import Foundation
import Testing
import Metal
import simd
@testable import LumenRender
import LumenProject

/// Headless sharpness contract on a realistic screen-capture field: 1 px text
/// stems, 2 px bold stems, thin UI rules and grey anti-aliased edges. Plain
/// interpolation at high zoom turns these into a grey smear; the real upscaler
/// must keep their contrast. Every number below is measured on GPU output read
/// back to the CPU — no window, no golden image, no visual claim.
private enum Field {
    static let w = 96, h = 64

    static func pixels() -> [UInt8] {
        var p = [UInt8](repeating: 12, count: w * h * 4) // near-black canvas
        func set(_ x: Int, _ y: Int, _ v: UInt8) {
            guard x >= 0, x < w, y >= 0, y < h else { return }
            let i = (y * w + x) * 4
            p[i] = v; p[i + 1] = v; p[i + 2] = v; p[i + 3] = 255
        }
        // Text rows: regular 1 px stems, a bold 2 px stem, and a grey
        // anti-aliased shoulder — the shape of real UI glyphs at 1x.
        for y in 6..<26 {
            for x in 4..<92 {
                let c = (x - 4) % 9
                if c == 0 || c == 2 { set(x, y, 235) }        // 1 px stems
                else if c == 5 || c == 6 { set(x, y, 235) }   // 2 px bold stem
                else if c == 8 { set(x, y, 70) }              // anti-aliased edge
            }
        }
        for y in 34..<54 {
            for x in 4..<92 {
                let c = (x - 4) % 11
                if c == 1 { set(x, y, 225) }
                else if c == 4 || c == 5 { set(x, y, 225) }
                else if c == 10 { set(x, y, 90) }
            }
        }
        // Thin horizontal UI rules (1 px) and a hairline divider.
        for x in 4..<92 { set(x, 29, 200); set(x, 58, 160) }
        return p
    }

    static func texture(_ device: MTLDevice, _ px: [UInt8]) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
        let t = try #require(device.makeTexture(descriptor: d))
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                  withBytes: px, bytesPerRow: w * 4)
        return t
    }
}

private func luma(_ p: [UInt8], _ stride: Int, _ x: Int, _ y: Int) -> Double {
    let i = (y * stride + x) * 4
    return (54.0 * Double(p[i]) + 183.0 * Double(p[i + 1]) + 19.0 * Double(p[i + 2])) / 256.0
}

/// Laplacian variance: sum of |4*center - neighbours| squared. Higher = sharper edges.
private func laplacianVariance(_ p: [UInt8], _ w: Int, _ h: Int) -> Double {
    var sum = 0.0, n = 0
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let c = luma(p, w, x, y)
            let lap = 4 * c - luma(p, w, x - 1, y) - luma(p, w, x + 1, y)
                - luma(p, w, x, y - 1) - luma(p, w, x, y + 1)
            sum += lap * lap; n += 1
        }
    }
    return sum / Double(max(n, 1))
}

/// 90th-percentile gradient magnitude. Plain interpolation conserves total
/// gradient while spreading it over more pixels; sharp edges concentrate it.
/// A percentile captures that concentration where a mean cannot.
private func edgeEnergy(_ p: [UInt8], _ w: Int, _ h: Int) -> Double {
    var all: [Double] = []
    all.reserveCapacity((w - 2) * (h - 2))
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let gx = (-luma(p, w, x - 1, y - 1) + luma(p, w, x + 1, y - 1)
                      - 2 * luma(p, w, x - 1, y) + 2 * luma(p, w, x + 1, y)
                      - luma(p, w, x - 1, y + 1) + luma(p, w, x + 1, y + 1))
            let gy = (-luma(p, w, x - 1, y - 1) - 2 * luma(p, w, x, y - 1) - luma(p, w, x + 1, y - 1)
                      + luma(p, w, x - 1, y + 1) + 2 * luma(p, w, x, y + 1) + luma(p, w, x + 1, y + 1))
            all.append(sqrt(gx * gx + gy * gy))
        }
    }
    guard !all.isEmpty else { return 0 }
    all.sort()
    return all[Int(Double(all.count - 1) * 0.90)]
}

/// Plain bilinear magnification — what a raw Catmull/linear sample of the
/// captured pixels looks like at high zoom. This is the honest baseline.
private func plainBilinear(_ src: [UInt8], _ w: Int, _ h: Int, _ f: Int) -> [UInt8] {
    let ow = w * f, oh = h * f
    var out = [UInt8](repeating: 0, count: ow * oh * 4)
    for y in 0..<oh {
        for x in 0..<ow {
            let sx = min(max((Double(x) + 0.5) / Double(f) - 0.5, 0), Double(w - 1))
            let sy = min(max((Double(y) + 0.5) / Double(f) - 0.5, 0), Double(h - 1))
            let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
            let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
            let fx = sx - Double(x0), fy = sy - Double(y0)
            func c(_ xx: Int, _ yy: Int) -> Double { luma(src, w, xx, yy) }
            let v = c(x0, y0) * (1 - fx) * (1 - fy) + c(x1, y0) * fx * (1 - fy)
                  + c(x0, y1) * (1 - fx) * fy + c(x1, y1) * fx * fy
            let i = (y * ow + x) * 4
            out[i] = UInt8(min(255, max(0, v.rounded())))
            out[i + 1] = out[i]; out[i + 2] = out[i]; out[i + 3] = 255
        }
    }
    return out
}

private func readback(_ device: MTLDevice, _ cb: MTLCommandBuffer,
                      _ texture: MTLTexture, _ w: Int, _ h: Int) throws -> [UInt8] {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                      width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead]; d.storageMode = .shared
    let dst = try #require(device.makeTexture(descriptor: d))
    guard let blit = cb.makeBlitCommandEncoder() else { return [] }
    blit.copy(from: texture,
              sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1),
              to: dst, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    dst.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return bytes
}

/// The measurable contract: at both a modest 2x and a hostile 10x, the real
/// upscaler must be markedly sharper than plain sampling of the same field.
@Test func upscalerBeatsPlainSamplingOnTextUIField() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let srcPx = Field.pixels()
    let src = try Field.texture(device, srcPx)

    for (n, f) in [2, 10].enumerated() {
        guard let cb = queue.makeCommandBuffer() else { return }
        let result = try up.upscale(cb, source: src, region: SIMD4(0, 0, Int32(Field.w), Int32(Field.h)),
                                    factor: f, params: UpscaleParams(), frameID: UInt64(7000 + n))
        let ow = Field.w * f, oh = Field.h * f
        let got = try readback(device, cb, result.texture, ow, oh)
        let plain = plainBilinear(srcPx, Field.w, Field.h, f)

        let upLap = laplacianVariance(got, ow, oh), plainLap = laplacianVariance(plain, ow, oh)
        let upEdge = edgeEnergy(got, ow, oh), plainEdge = edgeEnergy(plain, ow, oh)
        // Michelson contrast along a text row: the stem must stay black/white,
        // not collapse to a mid-grey as interpolation does.
        let row = 16 * f
        var upLo = 255.0, upHi = 0.0, plainLo = 255.0, plainHi = 0.0
        for x in 4 * f..<(92 * f) {
            let u = luma(got, ow, x, row), p = luma(plain, ow, x, row)
            upLo = min(upLo, u); upHi = max(upHi, u)
            plainLo = min(plainLo, p); plainHi = max(plainHi, p)
        }
        let upContrast = (upHi - upLo) / (upHi + upLo)
        let plainContrast = (plainHi - plainLo) / (plainHi + plainLo)
        print("FIELD \(f)x: lap up=\(Int(upLap)) plain=\(Int(plainLap)) ratio=\(String(format: "%.2f", upLap / max(plainLap, 1))) p90edge up=\(String(format: "%.1f", upEdge)) plain=\(String(format: "%.1f", plainEdge)) contrast up=\(String(format: "%.3f", upContrast)) plain=\(String(format: "%.3f", plainContrast))")
        #expect(result.factor == Float(f), "reported factor must equal applied factor")
        #expect(Double(result.texSize.x) >= Double(ow) && Double(result.texSize.y) >= Double(oh), "output texture too small for \(f)x")
        #expect(upLap > plainLap * 1.5, "\(f)x lap variance \(Int(upLap)) not sharper than plain \(Int(plainLap))")
        #expect(upEdge > plainEdge * 1.3, "\(f)x p90 edge \(upEdge) not sharper than plain \(plainEdge)")
        #expect(upContrast >= plainContrast, "\(f)x contrast \(upContrast) lost to plain \(plainContrast)")
    }
}
