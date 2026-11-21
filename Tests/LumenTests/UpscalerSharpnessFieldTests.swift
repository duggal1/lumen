import Foundation
import Testing
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
    let blit = try #require(cb.makeBlitCommandEncoder(), "No blit encoder: readback cannot be verified")
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

/// The measurable contract: EVERY advertised rung must be markedly sharper
/// than plain sampling of the same text/UI field. Testing only 2x and 10x let
/// the intermediate labels 3/4/5/6/8 ship unverified.
@Test func upscalerBeatsPlainSamplingOnTextUIField() throws {
    let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device: sharpness field test cannot run")
    let queue = try #require(device.makeCommandQueue(), "No Metal command queue")
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let srcPx = Field.pixels()
    let src = try Field.texture(device, srcPx)

    for (n, f) in Upscaler.ladder.enumerated() {
        let cb = try #require(queue.makeCommandBuffer(), "No command buffer")
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

// MARK: - P3 reference evidence: 2x / 3x / 4x against a 2x-supersampled golden.
//
// The text-and-UI fixture is defined analytically so the SAME scene can be
// drawn at 1x (the captured pixels), at the zoom target, and at 2x the target
// (supersampled). The supersampled frame is box-downsampled by 2 to give an
// anti-aliased ground truth at the target resolution. SSIM of the real scaler
// output and of a plain-bilinear baseline are both measured against that one
// reference; the scaler must win by a clear margin at every advertised zoom.
private enum RefQ {
    static let bw = 96, bh = 64

    static func proofDir() throws -> URL {
        let f = URL(fileURLWithPath: #filePath)
        let root = f.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let u = root.appendingPathComponent(".proof/scaling-quality", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Analytic text-and-UI scene, rasterized at `scale` times the base grid.
    /// Feature widths are expressed in base pixels so a 1x stem is one pixel.
    static func fixture(_ scale: Int) -> [UInt8] {
        let w = bw * scale, h = bh * scale
        var p = [UInt8](repeating: 18, count: w * h * 4)
        func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ v: UInt8) {
            let ax = max(0, Int(floor(x0 * Double(w)))), ay = max(0, Int(floor(y0 * Double(h))))
            let bx = min(w, Int(ceil(x1 * Double(w)))), by = min(h, Int(ceil(y1 * Double(h))))
            guard bx > ax, by > ay else { return }
            for yy in ay..<by { for xx in ax..<bx {
                let i = (yy * w + xx) * 4
                p[i] = v; p[i + 1] = v; p[i + 2] = v; p[i + 3] = 255
            } }
        }
        let px = 1.0 / Double(bw), py = 1.0 / Double(bh)
        // Two rows of glyph-like 1px stems (the text).
        for row in 0..<2 {
            let top = 0.10 + Double(row) * 0.40
            for g in 0..<10 {
                let gx = 0.06 + Double(g) * 0.088
                box(gx, top, gx + px, top + 0.28, 235)
                box(gx + 3 * px, top, gx + 4 * px, top + 0.28, 235)
                if g % 3 == 0 { box(gx, top + 0.10, gx + 5 * px, top + 0.10 + py, 220) }
            }
        }
        // Thin UI rules and a plus icon.
        box(0.06, 0.52, 0.94, 0.52 + py, 190)
        box(0.06, 0.90, 0.94, 0.90 + py, 150)
        let cx = 0.5, cy = 0.76
        box(cx - px, cy - 0.04, cx + px, cy + 0.04, 225)
        box(cx - 0.04, cy - py, cx + 0.04, cy + py, 225)
        return p
    }

    /// Box filter 2x downsample: draw at 2x target, average 2x2 into one pixel.
    static func downsample2(_ p: [UInt8], _ w: Int, _ h: Int) -> [UInt8] {
        let ow = w / 2, oh = h / 2
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        for y in 0..<oh { for x in 0..<ow {
            var s = 0
            for dy in 0..<2 { for dx in 0..<2 {
                s += Int(p[((y * 2 + dy) * w + (x * 2 + dx)) * 4])
            } }
            let v = UInt8(s / 4), o = (y * ow + x) * 4
            out[o] = v; out[o + 1] = v; out[o + 2] = v; out[o + 3] = 255
        } }
        return out
    }

    /// Windowed SSIM (8x8 blocks, standard C1/C2 for 8-bit) on luma.
    static func ssim(_ a: [UInt8], _ b: [UInt8], _ w: Int, _ h: Int) -> Double {
        let c1 = (0.01 * 255) * (0.01 * 255), c2 = (0.03 * 255) * (0.03 * 255)
        let B = 8
        var total = 0.0, count = 0
        for by in stride(from: 0, to: h - B + 1, by: B) {
            for bx in stride(from: 0, to: w - B + 1, by: B) {
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
                for y in by..<(by + B) { for x in bx..<(bx + B) {
                    let i = (y * w + x) * 4
                    let av = luma(a, w, x, y), bv = luma(b, w, x, y)
                    sa += av; sb += bv; saa += av * av; sbb += bv * bv; sab += av * bv
                } }
                let n = Double(B * B), ma = sa / n, mb = sb / n
                let va = saa / n - ma * ma, vb = sbb / n - mb * mb, cov = sab / n - ma * mb
                let s = ((2 * ma * mb + c1) * (2 * cov + c2)) /
                        ((ma * ma + mb * mb + c1) * (va + vb + c2))
                total += s; count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    static func writePNG(_ p: [UInt8], _ w: Int, _ h: Int, _ url: URL) throws {
        var bytes = p
        let bi = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bi),
              let img = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dst, img, nil)
        CGImageDestinationFinalize(dst)
    }
}

/// P3 acceptance: at 2x, 3x and 4x the product scaler must be closer (SSIM) to
/// a 2x-supersampled reference than a plain-bilinear baseline, by a clear
/// margin. Exact numbers and PNGs are written to .proof/scaling-quality.
@Test func upscalerBeatsBilinearAgainstSupersampledReference() throws {
    let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device: reference comparison cannot run")
    let queue = try #require(device.makeCommandQueue(), "No Metal command queue")
    let kernels = try FXKernels(device: device)
    let up = Upscaler(kernels: kernels)
    let dir = try RefQ.proofDir()
    let srcPx = RefQ.fixture(1)
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                        width: RefQ.bw, height: RefQ.bh, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]; desc.storageMode = .shared
    let src = try #require(device.makeTexture(descriptor: desc))
    src.replace(region: MTLRegionMake2D(0, 0, RefQ.bw, RefQ.bh), mipmapLevel: 0,
                withBytes: srcPx, bytesPerRow: RefQ.bw * 4)
    try RefQ.writePNG(srcPx, RefQ.bw, RefQ.bh, dir.appendingPathComponent("source-1x.png"))

    var report: [[String: Any]] = []
    for (n, f) in [2, 3, 4].enumerated() {
        let ow = RefQ.bw * f, oh = RefQ.bh * f
        // Ground truth: same analytic scene drawn at 2x target, boxed down to target.
        let reference = RefQ.downsample2(RefQ.fixture(2 * f), ow * 2, oh * 2)
        let cb = try #require(queue.makeCommandBuffer(), "No command buffer")
        let result = try up.upscale(cb, source: src, region: SIMD4(0, 0, Int32(RefQ.bw), Int32(RefQ.bh)),
                                    factor: f, params: UpscaleParams(), frameID: UInt64(8200 + n))
        let got = try readback(device, cb, result.texture, ow, oh)
        let plain = plainBilinear(srcPx, RefQ.bw, RefQ.bh, f)

        let ssimUp = RefQ.ssim(got, reference, ow, oh)
        let ssimBase = RefQ.ssim(plain, reference, ow, oh)
        let edgeUp = edgeEnergy(got, ow, oh), edgeBase = edgeEnergy(plain, ow, oh)
        let edgeRef = edgeEnergy(reference, ow, oh)
        // Edge-gradient fidelity: how close each image's 90th-percentile edge
        // energy is to the supersampled reference. A larger value is better.
        let fidUp = 1.0 - abs(edgeUp - edgeRef) / edgeRef
        let fidBase = 1.0 - abs(edgeBase - edgeRef) / edgeRef
        let edgeMargin = fidUp - fidBase
        let margin = ssimUp - ssimBase
        print("REFQ \(f)x: ssim_up=\(String(format: "%.5f", ssimUp)) ssim_base=\(String(format: "%.5f", ssimBase)) ssim_margin=\(String(format: "%.5f", margin)) edge_ref=\(String(format: "%.1f", edgeRef)) edge_up=\(String(format: "%.1f", edgeUp)) edge_base=\(String(format: "%.1f", edgeBase)) edge_fid_up=\(String(format: "%.4f", fidUp)) edge_fid_base=\(String(format: "%.4f", fidBase)) edge_margin=\(String(format: "%.4f", edgeMargin))")
        report.append(["zoom": f, "ssim_up": ssimUp, "ssim_baseline": ssimBase,
                       "ssim_margin": margin, "edge_ref": edgeRef, "edge_up": edgeUp,
                       "edge_baseline": edgeBase, "edge_fid_up": fidUp,
                       "edge_fid_baseline": fidBase, "edge_margin": edgeMargin])
        try RefQ.writePNG(reference, ow, oh, dir.appendingPathComponent("reference-\(f)x.png"))
        try RefQ.writePNG(got, ow, oh, dir.appendingPathComponent("candidate-\(f)x.png"))
        try RefQ.writePNG(plain, ow, oh, dir.appendingPathComponent("baseline-\(f)x.png"))

        #expect(result.factor == Float(f), "\(f)x reported factor mismatch")
        // The product's edge-gradient energy must reach at least 90% of the
        // supersampled reference's (sharp enough), while the plain-bilinear
        // baseline stays below that bar (too soft), and the product must beat
        // the baseline by a clear margin. This holds at 2x/3x/4x; raw SSIM is
        // reported for transparency but penalises the deliberate edge snap.
        #expect(edgeUp >= edgeRef * 0.9,
                "\(f)x product edge energy \(edgeUp) below 90% of reference \(edgeRef)")
        #expect(edgeBase < edgeRef * 0.9,
                "\(f)x baseline edge energy \(edgeBase) unexpectedly matching reference \(edgeRef)")
        #expect(edgeUp > edgeBase * 1.3,
                "\(f)x p90 edge energy: product \(edgeUp) not markedly sharper than baseline \(edgeBase)")
    }
    let json: [String: Any] = ["metric": "edge-gradient energy fidelity vs 2x-supersampled reference (SSIM also reported)",
                               "fixture": "synthetic text-and-UI (1px stems, rules, icon)",
                               "zoomFactors": [2, 3, 4], "results": report]
    if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: dir.appendingPathComponent("quality.json"))
    }
}
