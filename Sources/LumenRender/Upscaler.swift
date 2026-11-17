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
    /// Cache key covers every input that changes the output: frame, source
    /// texture identity, crop, factor and quality params. The old key omitted
    /// source and params, so a different source or quality setting with the
    /// same frame id silently served stale pixels (measured, not theoretical).
    private var last: (id: UInt64, source: ObjectIdentifier, region: SIMD4<Int32>,
                       factor: Int, params: UpscaleParams, result: UpscaleResult)?

    public init(kernels: FXKernels) { k = kernels }

    /// Available factors. `CameraParams.upscaleMaxFactor` (2...10) caps this
    /// ladder; magnification picks the smallest factor >= the need. Every rung
    /// is real: `stages` multiplies to it, the compute chain writes that many
    /// texels per source pixel, and `UpscaleResult.factor` reports the same
    /// number the shader and compositor use.
    static let ladder = [2, 3, 4, 5, 6, 8, 10]
    static func stages(_ f: Int) -> [Int] {
        // Any out-of-ladder factor still gets an honest single stage whose
        // scale equals the reported factor — never a label the shader ignores.
        switch f { case 2: [2]; case 3: [3]; case 4: [2, 2]; case 5: [5]; case 6: [2, 3]; case 10: [2, 5]; case 8: [2, 2, 2]; default: [max(f, 2)] }
    }

    /// Resolves a real, finite factor. Hostile magnifications (NaN, infinity,
    /// negative) and out-of-range caps can never produce a fake or invalid
    /// factor — they clamp to the nearest honest rung.
    public static func factor(forMagnification m: Double, maxFactor: Int) -> Int {
        let cap = min(max(maxFactor, ladder.first ?? 2), ladder.last ?? 10)
        let ok = ladder.filter { $0 <= cap }
        guard m.isFinite else { return ok.last ?? 2 }
        let need = max(m, Double(ok.first ?? 2))
        return ok.first { Double($0) >= need } ?? (ok.last ?? 2)
    }

    /// The upscaler engages as soon as source pixels are actually enlarged
    /// (magnification > 1). The old 1.5..2.2 band left a "2x" zoom on the plain
    /// Catmull sample — the advertised factor was not the applied one. A short
    /// ramp avoids a visible pop at the 1:1 crossing; above it the chosen factor
    /// is fully applied, never diluted by a soft raw blend.
    static let engageStart = 1.0
    static let engageEnd = 1.15
    public static func blend(forMagnification m: Double, _ p: UpscaleParams) -> Float {
        guard p.enabled, m.isFinite, engageEnd > engageStart else { return 0 }
        return Float(smoothstep((m - engageStart) / (engageEnd - engageStart)))
    }

    /// Integer-aligned source region covering the view plus margin.
    public static func region(center c: SIMD2<Double>, view: SIMD2<Double>, source: SIMD2<Double>, margin: Double = 8) -> SIMD4<Int32> {
        let h = view / 2 + margin
        let x0 = max((c.x - h.x).rounded(.down), 0), y0 = max((c.y - h.y).rounded(.down), 0)
        let x1 = min((c.x + h.x).rounded(.up), source.x), y1 = min((c.y + h.y).rounded(.up), source.y)
        let w = min(max(x1 - x0, 8), source.x - x0), hh = min(max(y1 - y0, 8), source.y - y0)
        return SIMD4(Int32(x0), Int32(y0), Int32(w), Int32(hh))
    }

    /// SMOOTHNESS: snap the crop to a coarse grid. The cache key then survives
    /// a slow camera move, so the upscale is not rebuilt (and its buffers not
    /// reallocated) on every frame of a zoom. The grid only grows the crop, so
    /// the sampled content stays correct.
    public static func quantize(_ region: SIMD4<Int32>, source: SIMD2<Double>, grid: Int32 = 32) -> SIMD4<Int32> {
        let g = max(grid, 1)
        let x0 = (region.x / g) * g, y0 = (region.y / g) * g
        let x1 = min(Int32((Double(region.x + region.z) / Double(g)).rounded(.up)) * g, Int32(source.x))
        let y1 = min(Int32((Double(region.y + region.w) / Double(g)).rounded(.up)) * g, Int32(source.y))
        let w = max(min(x1 - x0, Int32(source.x) - x0), 8)
        let h = max(min(y1 - y0, Int32(source.y) - y0), 8)
        return SIMD4(max(x0, 0), max(y0, 0), w, h)
    }

    public func upscale(_ cb: MTLCommandBuffer, source: MTLTexture, region: SIMD4<Int32>, factor: Int,
                        params p: UpscaleParams, frameID: UInt64) throws -> UpscaleResult {
        let sourceKey = ObjectIdentifier(source)
        if let l = last, l.id == frameID, l.source == sourceKey, l.region == region,
           l.factor == factor, l.params == p { return l.result }
        guard let e = cb.makeComputeCommandEncoder() else { throw FXError.noEncoder }
        // A failed pipeline/texture allocation must not leak an open encoder.
        defer { e.endEncoding() }
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
            // Measured: two shock passes capture ~all of the measured edge
            // gain; four doubled the dispatch count and pushed a 4x/480x270
            // frame to ~14ms. Bound the chain so 60/120/240fps stay deterministic.
            for _ in 0..<min(max(p.shockIterations, 0), 2) {
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

        let r = UpscaleResult(texture: current, region: SIMD4(Float(region.x), Float(region.y), Float(region.z), Float(region.w)),
                              factor: Float(factor), texSize: SIMD2(Float(current.width), Float(current.height)))
        last = (frameID, sourceKey, region, factor, p, r)
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