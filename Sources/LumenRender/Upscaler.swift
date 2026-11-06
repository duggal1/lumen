import Metal
import simd
import LumenCore
import LumenProject

public struct UpscaleResult {
    public let texture: MTLTexture
    public let region: SIMD4<Float>            // source px: x, y, w, h
    public let factor: Float
    public let texSize: SIMD2<Float>           // physical size; may exceed region * factor
}

private struct DirectedParams { var srcOrigin: SIMD2<Int32>; var srcSize: SIMD2<Int32>; var outSize: SIMD2<Int32>; var scale: Float; var sharp: Float }
private struct ShockParams { var size: SIMD2<Int32>; var strength: Float; var edgeLo: Float; var edgeHi: Float; var k: Float }
private struct SharpParams { var size: SIMD2<Int32>; var amount: Float; var pad: Float = 0 }

/// Training-free UI upscaler. Upscales only the visible source region, on a source-aligned lattice, by a quantized factor
/// {2,3,4,6,8}, as a chain of edge-directed stages (each followed by shock iterations) and a final limited sharpen.
/// The compositor then resamples this texture with Catmull-Rom, so continuous zoom never shimmers.
/// Owned by one render queue. Use a separate instance per consumer (view, loupe): the buffers are reused every call.
public final class Upscaler {
    private let k: FXKernels
    private var sets: [[MTLTexture?]] = [[nil, nil], [nil, nil]]
    private var last: (id: UInt64, region: SIMD4<Int32>, factor: Int, result: UpscaleResult)?

    public init(kernels: FXKernels) { k = kernels }

    /// Available factors. The user setting (`CameraParams.upscaleMaxFactor`,
    /// 2...10) caps this ladder; magnification then picks the smallest
    /// factor >= the needed magnification. So "5×"/"8×"/"10×" are settings,
    /// not fixed claims: mag 4.5 with cap 10 picks 5×, mag 6.5 picks 8×.
    static let ladder = [2, 3, 4, 5, 6, 8, 10]
    static func stages(_ f: Int) -> [Int] {
        switch f { case 2: [2]; case 3: [3]; case 4: [2, 2]; case 5: [5]; case 6: [2, 3]; case 10: [2, 5]; default: [2, 2, 2] }
    }

    public static func factor(forMagnification m: Double, maxFactor: Int) -> Int {
        let ok = ladder.filter { $0 <= maxFactor }
        return ok.first { Double($0) >= m } ?? (ok.last ?? 2)
    }

    /// 0 below blendStart (plain Catmull-Rom), 1 above blendEnd. Avoids a visible pop when the upscaler engages.
    public static func blend(forMagnification m: Double, _ p: UpscaleParams) -> Float {
        guard p.enabled, p.blendEnd > p.blendStart else { return 0 }
        return Float(smoothstep((m - p.blendStart) / (p.blendEnd - p.blendStart)))
    }

    /// Integer-aligned source region covering the view plus margin.
    public static func region(center c: SIMD2<Double>, view: SIMD2<Double>, source: SIMD2<Double>, margin: Double = 8) -> SIMD4<Int32> {
        let h = view / 2 + margin
        let x0 = max((c.x - h.x).rounded(.down), 0), y0 = max((c.y - h.y).rounded(.down), 0)
        let x1 = min((c.x + h.x).rounded(.up), source.x), y1 = min((c.y + h.y).rounded(.up), source.y)
        let w = min(max(x1 - x0, 8), source.x - x0), hh = min(max(y1 - y0, 8), source.y - y0)
        return SIMD4(Int32(x0), Int32(y0), Int32(w), Int32(hh))
    }

    public func upscale(_ cb: MTLCommandBuffer, source: MTLTexture, region: SIMD4<Int32>, factor: Int,
                        params p: UpscaleParams, frameID: UInt64) throws -> UpscaleResult {
        if let l = last, l.id == frameID, l.region == region, l.factor == factor { return l.result }
        guard let e = cb.makeComputeCommandEncoder() else { throw FXError.noEncoder }
        e.label = "Upscale x\(factor)"
        var input: MTLTexture = source
        var origin = SIMD2<Int32>(region.x, region.y), size = SIMD2<Int32>(region.z, region.w)
        var cum: Float = 1
        var current: MTLTexture = source, spare: MTLTexture = source

        for (n, s) in Self.stages(factor).enumerated() {
            let out = SIMD2<Int32>(size.x * Int32(s), size.y * Int32(s))
            cum *= Float(s)
            var a = try buffer(n & 1, 0, out), b = try buffer(n & 1, 1, out)
            var dp = DirectedParams(srcOrigin: origin, srcSize: size, outSize: out, scale: Float(s), sharp: Float(p.edgeSharpness))
            e.setComputePipelineState(try k.pipeline("up_directed"))
            e.setTexture(input, index: 0); e.setTexture(a, index: 1)
            e.setBytes(&dp, length: MemoryLayout<DirectedParams>.stride, index: 0)
            k.dispatch(e, pipeline: try k.pipeline("up_directed"), width: Int(out.x), height: Int(out.y))

            var sp = ShockParams(size: out, strength: Float(p.shock), edgeLo: 0.04 / cum, edgeHi: 0.25 / cum, k: 30)
            let shock = try k.pipeline("up_shock")
            e.setComputePipelineState(shock)
            for _ in 0..<max(p.shockIterations, 0) {
                e.setTexture(a, index: 0); e.setTexture(b, index: 1)
                e.setBytes(&sp, length: MemoryLayout<ShockParams>.stride, index: 0)
                k.dispatch(e, pipeline: shock, width: Int(out.x), height: Int(out.y))
                swap(&a, &b)
            }
            current = a; spare = b
            input = a; origin = .zero; size = out
        }
        if p.finalSharpen > 0 {
            var sp = SharpParams(size: size, amount: Float(p.finalSharpen))
            let sharp = try k.pipeline("up_sharpen")
            e.setComputePipelineState(sharp)
            e.setTexture(current, index: 0); e.setTexture(spare, index: 1)
            e.setBytes(&sp, length: MemoryLayout<SharpParams>.stride, index: 0)
            k.dispatch(e, pipeline: sharp, width: Int(size.x), height: Int(size.y))
            swap(&current, &spare)
        }
        e.endEncoding()

        let r = UpscaleResult(texture: current, region: SIMD4(Float(region.x), Float(region.y), Float(region.z), Float(region.w)),
                              factor: Float(factor), texSize: SIMD2(Float(current.width), Float(current.height)))
        last = (frameID, region, factor, r)
        return r
    }

    /// Growth-only buffers: bounded by ~1.5x the canvas per side, so reallocation stops after warm-up.
    private func buffer(_ set: Int, _ i: Int, _ size: SIMD2<Int32>) throws -> MTLTexture {
        let w = Int(size.x), h = Int(size.y)
        if let t = sets[set][i], t.width >= w, t.height >= h { return t }
        let nw = (max(w, sets[set][i]?.width ?? 0) + 63) & ~63, nh = (max(h, sets[set][i]?.height ?? 0) + 63) & ~63
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: nw, height: nh, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
        guard let t = k.device.makeTexture(descriptor: d) else { throw FXError.noTexture }
        sets[set][i] = t
        return t
    }
}