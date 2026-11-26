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
private struct SharpParams { var size: SIMD2<Int32>; var amount: Float }

/// Training-free UI upscaler. Upscales only the visible source region, on a source-aligned lattice, by a quantized factor
/// {2,3,4,5,6,8,10}, as a chain of edge-directed stages (each followed by shock iterations) and a final limited sharpen.
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

    /// Select an actual reconstruction rung before allocating a GPU texture.
    /// The limit is in output texels, not source pixels or a decorative zoom label.
    public static func boundedFactor(forMagnification m: Double, maxFactor: Int,
                                     region: SIMD4<Int32>, pixelLimit: Int) -> Int? {
        guard m.isFinite, m > 1, region.z > 0, region.w > 0, pixelLimit > 0 else { return nil }
        let requested = factor(forMagnification: m, maxFactor: maxFactor)
        return ladder.reversed().first { f in
            let w = Double(region.z) * Double(f), h = Double(region.w) * Double(f)
            return f <= requested && w <= 8192 && h <= 8192
                && ceil(w / 64) * 64 * ceil(h / 64) * 64 <= Double(pixelLimit)
        }
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
        // A degenerate or non-finite source must never yield a negative region:
        // the compute dispatch would write out of bounds.
        // 1e9 is well inside Int32.max and far beyond any real capture.
        let sx = min(max(source.x.isFinite ? source.x : 1, 1), 1e9)
        let sy = min(max(source.y.isFinite ? source.y : 1, 1), 1e9)
        let c0 = SIMD2<Double>(min(max(c.x.isFinite ? c.x : sx / 2, 0), sx),
                               min(max(c.y.isFinite ? c.y : sy / 2, 0), sy))
        let pad = margin.isFinite ? min(max(margin, 0), 1e9) : 8
        let vx = view.x.isFinite ? min(max(view.x, 1), 2e9) : sx
        let vy = view.y.isFinite ? min(max(view.y, 1), 2e9) : sy
        let h = SIMD2(vx, vy) / 2 + pad
        let x0 = min(max((c0.x - h.x).rounded(.down), 0), sx - 1)
        let y0 = min(max((c0.y - h.y).rounded(.down), 0), sy - 1)
        let x1 = min(max((c0.x + h.x).rounded(.up), x0 + 1), sx)
        let y1 = min(max((c0.y + h.y).rounded(.up), y0 + 1), sy)
        let w = min(max(x1 - x0, 1), sx - x0), hh = min(max(y1 - y0, 1), sy - y0)
        return SIMD4(Int32(x0), Int32(y0), Int32(w), Int32(hh))
    }

    /// SMOOTHNESS: snap the crop to a coarse grid so the cache survives a slow
    /// camera move. The grid only grows the crop, so sampled content stays correct.
    public static func quantize(_ region: SIMD4<Int32>, source: SIMD2<Double>, grid: Int32 = 32) -> SIMD4<Int32> {
        let g = max(grid, 1)
        func i32(_ v: Double, _ fallback: Int32) -> Int32 {
            guard v.isFinite else { return fallback }
            return Int32(min(max(v, -1e9), 1e9))
        }
        let sx = i32(source.x, region.x + region.z)
        let sy = i32(source.y, region.y + region.w)
        let x0 = (region.x / g) * g, y0 = (region.y / g) * g
        let x1 = min(Int32((Double(region.x + region.z) / Double(g)).rounded(.up)) * g, sx)
        let y1 = min(Int32((Double(region.y + region.w) / Double(g)).rounded(.up)) * g, sy)
        let w = max(min(x1 - x0, sx - x0), 1)
        let h = max(min(y1 - y0, sy - y0), 1)
        return SIMD4(max(x0, 0), max(y0, 0), w, h)
    }

    public func upscale(_ cb: MTLCommandBuffer, source: MTLTexture, region: SIMD4<Int32>, factor: Int,
                        params p: UpscaleParams, frameID: UInt64) throws -> UpscaleResult {
        // Validate before Int32 multiplication or Metal dispatch. This also
        // protects direct callers (CLI/tests), not only the compositor.
        guard Self.ladder.contains(factor), region.x >= 0, region.y >= 0,
              region.z > 0, region.w > 0,
              Int64(region.x) + Int64(region.z) <= Int64(source.width),
              Int64(region.y) + Int64(region.w) <= Int64(source.height),
              Self.boundedFactor(forMagnification: Double(factor), maxFactor: factor,
                                 region: region, pixelLimit: 12_582_912) == factor else {
            throw FXError.noTexture
        }
        let sourceKey = ObjectIdentifier(source)
        if let l = last, l.id == frameID, l.source == sourceKey, l.region == region,
           l.factor == factor, l.params == p { return l.result }
        last = nil  // a partially encoded failure must not publish an old cache entry
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
            let directed = try k.pipeline("up_directed")
            e.setComputePipelineState(directed)
            e.setTexture(input, index: 0); e.setTexture(a, index: 1)
            e.setBytes(&dp, length: MemoryLayout<DirectedParams>.stride, index: 0)
            k.dispatch(e, pipeline: directed, width: Int(out.x), height: Int(out.y))

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
        var nw = (max(w, sets[set][i]?.width ?? 0) + 63) & ~63
        var nh = (max(h, sets[set][i]?.height ?? 0) + 63) & ~63
        // Alternating portrait/landscape must not retain the Cartesian product
        // of their maximum dimensions.
        if nw * nh > 12_582_912 { nw = (w + 63) & ~63; nh = (h + 63) & ~63 }
        guard nw * nh <= 12_582_912 else { throw FXError.noTexture }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: nw, height: nh, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
        guard let t = k.device.makeTexture(descriptor: d) else { throw FXError.noTexture }
        sets[set][i] = t
        return t
    }
}