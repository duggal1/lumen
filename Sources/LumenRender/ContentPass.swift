import Metal
import simd
import LumenProject

public struct ContentLayout {
    public var canvas: SIMD2<Int32>
    public var contentRect: SIMD4<Float>       // canvas px: x, y, w, h
    public var radii: SIMD4<Float>             // tl, tr, br, bl
    public var srcSize: SIMD2<Float>
    /// The same zoom-1 source view used by contentFS, after browser/area crop.
    /// nil retains the full-source geometry for standalone callers.
    public var sampledBaseSize: SIMD2<Float>?
    public init(canvas: SIMD2<Int32>, contentRect: SIMD4<Float>, radii: SIMD4<Float>,
                srcSize: SIMD2<Float>, sampledBaseSize: SIMD2<Float>? = nil) {
        self.canvas = canvas; self.contentRect = contentRect; self.radii = radii; self.srcSize = srcSize
        self.sampledBaseSize = sampledBaseSize
    }
    /// Canvas px per sampled source px at zoom 1 (not per recording pixel).
    public var baseMagnification: Float { contentRect.z / (sampledBaseSize?.x ?? srcSize.x) }
}

/// Camera-transformed content over the cached backdrop, rounded per corner, with optional upscaled sampling.
/// SMOOTHNESS: the upscaled texture is consumed by `contentFS` directly; this
/// type only prepares the compute chain.
public final class ContentPass {
    private let k: FXKernels
    public init(kernels: FXKernels) { k = kernels }

    /// Runs the upscaler if magnification is high enough. Encodes its own compute work into `cb` (call before `encode`).
    public func prepareUpscale(_ up: Upscaler, _ cb: MTLCommandBuffer, layout L: ContentLayout, camCenter c: SIMD2<Float>, zoom: Float,
                               source: MTLTexture, sourceID: UInt64, params p: UpscaleParams,
                               pixelLimit: Int = 12_582_912) throws -> (UpscaleResult, Float)? {
        let m = Double(zoom * L.baseMagnification)
        let blend = Upscaler.blend(forMagnification: m, p)
        guard blend > 0 else { return nil }
        let view = L.sampledBaseSize.map { SIMD2<Double>(Double($0.x), Double($0.y)) / Double(zoom) }
            ?? SIMD2<Double>(Double(L.contentRect.z), Double(L.contentRect.w)) / m
        // SMOOTHNESS: the crop is snapped to a coarse grid so the upscaled
        // texture is reused while the camera drifts.
        let region = Upscaler.quantize(
            Upscaler.region(center: SIMD2(Double(c.x), Double(c.y)), view: view,
                            source: SIMD2(Double(L.srcSize.x), Double(L.srcSize.y)), margin: 12),
            source: SIMD2(Double(L.srcSize.x), Double(L.srcSize.y)))
        guard let f = Upscaler.boundedFactor(forMagnification: m, maxFactor: p.maxFactor,
                                             region: region, pixelLimit: pixelLimit) else { return nil }
        return (try up.upscale(cb, source: source, region: region, factor: f, params: p, frameID: sourceID), blend)
    }
}
