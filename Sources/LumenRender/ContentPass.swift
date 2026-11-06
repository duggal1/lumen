import Metal
import simd
import LumenProject

public struct ContentLayout {
    public var canvas: SIMD2<Int32>
    public var contentRect: SIMD4<Float>       // canvas px: x, y, w, h
    public var radii: SIMD4<Float>             // tl, tr, br, bl
    public var srcSize: SIMD2<Float>
    public init(canvas: SIMD2<Int32>, contentRect: SIMD4<Float>, radii: SIMD4<Float>, srcSize: SIMD2<Float>) {
        self.canvas = canvas; self.contentRect = contentRect; self.radii = radii; self.srcSize = srcSize
    }
    /// Canvas px per source px at zoom 1.
    public var baseMagnification: Float { contentRect.z / srcSize.x }
}

private struct UpBindGPU { var region: SIMD4<Float>; var texSize: SIMD2<Float>; var factor: Float; var blend: Float }
private struct ContentParamsGPU {
    var contentRect: SIMD4<Float>; var radii: SIMD4<Float>
    var camCenter: SIMD2<Float>; var srcSize: SIMD2<Float>
    var magnification: Float; var pad: Float = 0
    var canvasSize: SIMD2<Int32>
    var up: UpBindGPU
}

/// Camera-transformed content over the cached backdrop, rounded per corner, with optional upscaled sampling.
public final class ContentPass {
    private let k: FXKernels
    public init(kernels: FXKernels) { k = kernels }

    /// Runs the upscaler if magnification is high enough. Encodes its own compute work into `cb` (call before `encode`).
    public func prepareUpscale(_ up: Upscaler, _ cb: MTLCommandBuffer, layout L: ContentLayout, camCenter c: SIMD2<Float>, zoom: Float,
                               source: MTLTexture, sourceID: UInt64, params p: UpscaleParams,
                               extraMargin: Double = 0) throws -> (UpscaleResult, Float)? {
        let m = Double(zoom * L.baseMagnification)
        let blend = Upscaler.blend(forMagnification: m, p)
        guard blend > 0 else { return nil }
        let view = SIMD2<Double>(Double(L.contentRect.z), Double(L.contentRect.w)) / m
        let region = Upscaler.region(center: SIMD2(Double(c.x), Double(c.y)), view: view,
                                     source: SIMD2(Double(L.srcSize.x), Double(L.srcSize.y)), margin: 8 + extraMargin)
        let f = Upscaler.factor(forMagnification: m, maxFactor: p.maxFactor)
        return (try up.upscale(cb, source: source, region: region, factor: f, params: p, frameID: sourceID), blend)
    }

    public func encode(_ e: MTLComputeCommandEncoder, layout L: ContentLayout, camCenter: SIMD2<Float>, zoom: Float,
                       backdrop: MTLTexture, canvas: MTLTexture, source: MTLTexture, upscaled: (UpscaleResult, Float)?) throws {
        var up = UpBindGPU(region: .zero, texSize: .one, factor: 1, blend: 0)
        if let (r, b) = upscaled { up = UpBindGPU(region: r.region, texSize: r.texSize, factor: r.factor, blend: b) }
        var P = ContentParamsGPU(contentRect: L.contentRect, radii: L.radii, camCenter: camCenter, srcSize: L.srcSize,
                                 magnification: zoom * L.baseMagnification, canvasSize: L.canvas, up: up)
        let pipe = try k.pipeline("fx_content")
        e.setComputePipelineState(pipe)
        e.setTexture(backdrop, index: 0); e.setTexture(canvas, index: 1)
        e.setTexture(source, index: 2); e.setTexture(upscaled?.0.texture ?? source, index: 3)
        e.setBytes(&P, length: MemoryLayout<ContentParamsGPU>.stride, index: 0)
        k.dispatch(e, pipeline: pipe, width: Int(L.canvas.x), height: Int(L.canvas.y))
    }
}