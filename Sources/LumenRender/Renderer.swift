import Foundation
import Metal
import CoreVideo
import QuartzCore
import simd
import os
import LumenCore
import LumenProject
import LumenDirector

public enum RenderError: Error { case noDevice, pipeline(String) }
public enum RenderQuality: Sendable { case preview, export }

public struct RenderRequest: @unchecked Sendable {
    public var live: FrameState?
    public var timeline: Timeline, t: Double
    public var screen: SourceFrame, webcam: SourceFrame?
    public var canvas: SIMD2<Int>, fps: Double, backingScale: Double, quality: RenderQuality
    public init(timeline: Timeline, t: Double, screen: SourceFrame, webcam: SourceFrame? = nil, canvas: SIMD2<Int>,
                fps: Double = 60, backingScale: Double = 2, quality: RenderQuality = .export) {
        self.timeline = timeline; self.t = t; self.screen = screen; self.webcam = webcam
        self.canvas = canvas; self.fps = fps; self.backingScale = backingScale; self.quality = quality
    }
}

/// Frame placement inside the canvas. Pixel-snapped so the frame edge is crisp. Shared with the UI (focus editor).
public struct Geometry: Sendable {
    public var canvas: SIMD2<Double>, src: SIMD2<Double>
    public var content: SIMD4<Double>        // x y w h in canvas px
    public var radius: Double, ui: Double
    public init(canvas c: SIMD2<Int>, src: SIMD2<Double>, style: Style) {
        let cv = SIMD2<Double>(Double(c.x), Double(c.y)), pad = style.padding * cv.x
        let aw = cv.x - 2 * pad, ah = cv.y - 2 * pad, sa = src.x / max(src.y, 1)
        let w = min(aw, ah * sa), h = w / sa
        canvas = cv; self.src = src
        content = SIMD4(((cv.x - w) / 2).rounded(), ((cv.y - h) / 2).rounded(), w.rounded(), h.rounded())
        ui = cv.x / 1440; radius = style.cornerRadius * ui
    }
    /// Source px -> canvas px for a given camera.
    public func toCanvas(_ p: SIMD2<Double>, cam: SIMD2<Double>, scale: Double) -> SIMD2<Double> {
        let view = src / scale, n = (p - (cam - view / 2)) / view
        return SIMD2(content.x + n.x * content.z, content.y + n.y * content.w)
    }
}

private struct QuadU { var rect: SIMD4<Float>; var canvas: SIMD2<Float> }
private struct BackdropU { var content: SIMD4<Float>; var canvas: SIMD2<Float>; var angle: Float; var count: Int32; var kind: Int32
                           var radius: Float; var shadow: Float; var scale: Float }
private struct ContentU { var content: SIMD4<Float>; var src: SIMD2<Float>; var cam: SIMD2<Float>; var scale: Float; var radius: Float; var border: Float; var p: Float }
private struct CursorU { var content: SIMD4<Float>; var radius: Float; var opacity: Float; var layer: UInt32; var p: Float }
private struct RingU { var content: SIMD4<Float>; var color: SIMD4<Float>; var center: SIMD2<Float>; var radius: Float; var progress: Float; var cr: Float }
private struct WebU { var crop: SIMD4<Float>; var bubble: SIMD4<Float>; var radius: Float; var shape: Float; var mirror: Float; var border: Float
                      var shadow: Float; var bw: Float; var minif: Float; var margin: Float }
private struct AccU { var weight: Float }
private struct ResU { var levels: Float; var seed: UInt32 }
private struct BackdropKey: Equatable { var style: Style; var size: SIMD2<Int> }
private struct Keep: @unchecked Sendable { let o: Any }

/// BGRA source -> mip-mapped copy, regenerated only when a NEW source frame arrives (sample-and-hold reuses the chain).
private final class MipCache {
    private var tex: MTLTexture?
    private var key: UInt64 = .max
    func texture(for f: SourceFrame, device: MTLDevice, cb: MTLCommandBuffer) -> MTLTexture? {
        let w = f.texture.width, h = f.texture.height
        if tex == nil || tex!.width != w || tex!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
            d.usage = [.shaderRead, .renderTarget]; d.storageMode = .private
            tex = device.makeTexture(descriptor: d); key = .max
        }
        guard let t = tex else { return nil }
        if key != f.id, let b = cb.makeBlitCommandEncoder() {
            b.copy(from: f.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                   sourceSize: MTLSize(width: w, height: h, depth: 1), to: t, destinationSlice: 0, destinationLevel: 0,
                   destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            b.generateMipmaps(for: t); b.endEncoding(); key = f.id
        }
        return t
    }
}

/// Pure-ish renderer: output depends only on (RenderRequest). Owned by ONE render queue; not thread-safe.
/// Preview and export call the same `encode`. Triple-buffered; the frame loop allocates nothing after warm-up.
public final class Renderer: @unchecked Sendable {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let lib: MTLLibrary
    private let pBackdrop, pContent, pCursor, pRing, pWeb, pAccum: MTLRenderPipelineState
    private var pResolve: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let sem = DispatchSemaphore(value: 3)
    private var slot = 0
    private var work: [MTLTexture] = [], accum: [MTLTexture] = []
    private var backdrop: MTLTexture?
    private var backdropKey: BackdropKey?
    private var size = SIMD2<Int>(0, 0)
    private let screenMip = MipCache(), webMip = MipCache()
    private var atlas: CursorAtlas?
    private var atlasPack: CursorPack?
    private var customs: [CustomCursor] = []
    private let outCache: CVMetalTextureCache

    public init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw RenderError.noDevice }
        let l = try d.makeDefaultLibrary(bundle: .module), f = MTLPixelFormat.rgba16Float
        device = d; queue = q; lib = l
        pBackdrop = try Self.pipe(d, l, "backdropFS", f, 0)
        pContent = try Self.pipe(d, l, "contentFS", f, 1)
        pCursor = try Self.pipe(d, l, "cursorFS", f, 1)
        pRing = try Self.pipe(d, l, "ringFS", f, 1)
        pWeb = try Self.pipe(d, l, "webFS", f, 1)
        pAccum = try Self.pipe(d, l, "accumFS", f, 2)
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, d, nil, &c)
        guard let c else { throw RenderError.noDevice }
        outCache = c
    }

    /// blend: 0 none, 1 premultiplied over, 2 additive
    private static func pipe(_ d: MTLDevice, _ l: MTLLibrary, _ fs: String, _ fmt: MTLPixelFormat, _ blend: Int) throws -> MTLRenderPipelineState {
        let p = MTLRenderPipelineDescriptor()
        p.vertexFunction = l.makeFunction(name: "quadVS"); p.fragmentFunction = l.makeFunction(name: fs)
        guard p.vertexFunction != nil, p.fragmentFunction != nil else { throw RenderError.pipeline(fs) }
        let a = p.colorAttachments[0]!
        a.pixelFormat = fmt
        if blend > 0 {
            a.isBlendingEnabled = true; a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = blend == 1 ? .oneMinusSourceAlpha : .one
            a.destinationAlphaBlendFactor = blend == 1 ? .oneMinusSourceAlpha : .one
        }
        return try d.makeRenderPipelineState(descriptor: p)
    }

    public func setCustomCursors(_ c: [CustomCursor]) { customs = c; atlas = nil }

    private func ensureTargets(_ s: SIMD2<Int>) {
        guard s != size else { return }
        for _ in 0..<3 { sem.wait() }
        func mk() -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: s.x, height: s.y, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        work = (0..<3).map { _ in mk() }; accum = (0..<3).map { _ in mk() }
        backdrop = mk(); backdropKey = nil; size = s
        for _ in 0..<3 { sem.signal() }
    }

    // MARK: Entry points

    /// Preview: renders into the layer's next drawable. Never blocks: returns false when all 3 frames are in flight.
    @discardableResult
    public func draw(_ r: RenderRequest, to layer: CAMetalLayer) -> Bool {
        guard let dr = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return false }
        guard encode(r, output: dr.texture, commandBuffer: cb, wait: false) else { return false }
        cb.present(dr); cb.commit(); return true
    }

    /// Export: renders into an IOSurface-backed BGRA8 or ARGB2101010 pixel buffer. `completion` fires when the GPU is done.
    public func render(_ r: RenderRequest, into pb: CVPixelBuffer, completion: @escaping @Sendable () -> Void = {}) -> Bool {
        let fmt: MTLPixelFormat
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_32BGRA: fmt = .bgra8Unorm
        case kCVPixelFormatType_ARGB2101010LEPacked: fmt = .bgr10a2Unorm
        default: return false
        }
        var cv: CVMetalTexture?
        let attrs = [kCVMetalTextureUsage as String: NSNumber(value: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue)] as CFDictionary
        guard CVMetalTextureCacheCreateTextureFromImage(nil, outCache, pb, attrs, fmt, CVPixelBufferGetWidth(pb),
                                                        CVPixelBufferGetHeight(pb), 0, &cv) == kCVReturnSuccess,
              let cv, let tex = CVMetalTextureGetTexture(cv), let cb = queue.makeCommandBuffer() else { return false }
        guard encode(r, output: tex, commandBuffer: cb) else { return false }
        let keep = Keep(o: cv)
        cb.addCompletedHandler { _ in withExtendedLifetime(keep) {}; completion() }
        cb.commit(); return true
    }

    // MARK: Frame

    @discardableResult
    public func encode(_ r: RenderRequest, output: MTLTexture, commandBuffer cb: MTLCommandBuffer, wait: Bool = true) -> Bool {
        let cs = r.canvas
        guard output.width == cs.x, output.height == cs.y, cs.x > 0, cs.y > 0 else { return false }
        ensureTargets(cs)
        if wait { sem.wait() } else if sem.wait(timeout: .now()) != .success { return false }
        let s = slot; slot = (slot + 1) % 3
        let tl = r.timeline
        let g = Geometry(canvas: cs, src: SIMD2(Double(r.screen.texture.width), Double(r.screen.texture.height)), style: tl.style)

        guard let srcTex = screenMip.texture(for: r.screen, device: device, cb: cb), let bd = backdrop else { sem.signal(); return false }
        var webTex: MTLTexture?
        if tl.webcam != nil, let w = r.webcam { webTex = webMip.texture(for: w, device: device, cb: cb) }
        if atlas == nil || atlasPack != tl.cursor.pack {
            atlas = CursorAtlas(device: device, queue: queue, pack: tl.cursor.pack, customs: customs); atlasPack = tl.cursor.pack
        }
        let canvasF = SIMD2<Float>(Float(g.canvas.x), Float(g.canvas.y))

        // 1. backdrop cache (style or size change only)
        let key = BackdropKey(style: tl.style, size: cs)
        if backdropKey != key {
            backdropKey = key
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = bd; pd.colorAttachments[0].loadAction = .dontCare; pd.colorAttachments[0].storeAction = .store
            if let e = cb.makeRenderCommandEncoder(descriptor: pd) {
                e.setRenderPipelineState(pBackdrop)
                quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
                let st = tl.style
                var cols = st.colors.isEmpty ? [SIMD4<Float>(0, 0, 0, 1)] : st.colors.map(\.simd)
                if cols.count < 6 { cols += [SIMD4<Float>](repeating: cols[0], count: 6 - cols.count) }
                frag(e, BackdropU(content: SIMD4<Float>(g.content), canvas: canvasF, angle: Float(st.gradientAngle * .pi / 180),
                                  count: Int32(max(st.colors.count, 1)), kind: st.background == .gradient ? 0 : st.background == .mesh ? 1 : 2,
                                  radius: Float(g.radius), shadow: Float(st.shadow), scale: Float(g.ui * 1.33)))
                cols.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                e.endEncoding()
            }
        }

        // 2. sub-frames (motion blur): scene over transparent, accumulated, resolved over the backdrop
        let K = sampleCount(r, g)
        let dt = 1 / max(r.fps, 1)
        for i in 0..<K {
            let off = ((Double(i) + 0.5) / Double(K) - 0.5) * tl.camera.shutter * dt
            var st = r.live ?? tl.evaluate(at: r.t + off)
            if r.live == nil, tl.derived == nil { st.cameraCenter = SIMD2<Float>(Float(g.src.x / 2), Float(g.src.y / 2)) }
            scene(cb, into: work[s], st: st, r: r, g: g, src: srcTex, web: webTex)
            if K > 1 {
                let pd = MTLRenderPassDescriptor()
                pd.colorAttachments[0].texture = accum[s]; pd.colorAttachments[0].loadAction = i == 0 ? .clear : .load
                pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0); pd.colorAttachments[0].storeAction = .store
                if let e = cb.makeRenderCommandEncoder(descriptor: pd) {
                    e.setRenderPipelineState(pAccum); quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
                    frag(e, AccU(weight: 1 / Float(K))); e.setFragmentTexture(work[s], index: 0)
                    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); e.endEncoding()
                }
            }
        }

        // 3. resolve
        let fmt = output.pixelFormat
        if pResolve[fmt] == nil { pResolve[fmt] = try? Self.pipe(device, lib, "resolveFS", fmt, 0) }
        guard let pr = pResolve[fmt] else { sem.signal(); return false }
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = output; pd.colorAttachments[0].loadAction = .dontCare; pd.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: pd) {
            e.setRenderPipelineState(pr); quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
            frag(e, ResU(levels: fmt == .bgr10a2Unorm ? 1023 : 255, seed: UInt32(truncatingIfNeeded: Int(r.t * 1000))))
            e.setFragmentTexture(K > 1 ? accum[s] : work[s], index: 0); e.setFragmentTexture(bd, index: 1)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); e.endEncoding()
        }
        let sem = self.sem, keep = Keep(o: (r.screen, r.webcam))
        cb.addCompletedHandler { _ in withExtendedLifetime(keep) {}; sem.signal() }
        return true
    }

    /// Adaptive K = ceil(max screen-space px/frame / 2), clamped; static scenes cost nothing. Preview <= 2.
    private func sampleCount(_ r: RenderRequest, _ g: Geometry) -> Int {
        let tl = r.timeline
        guard tl.camera.shutter > 0, tl.derived != nil, r.fps > 0 else { return 1 }
        let dt = 1 / r.fps, a = tl.evaluate(at: r.t - dt / 2), b = tl.evaluate(at: r.t + dt / 2)
        let k = g.content.z / g.src.x, sc = Double(b.cameraScale)
        let cam = Double(simd_length(b.cameraCenter - a.cameraCenter)) * k * sc
        let zoom = abs(log(Double(b.cameraScale) / Double(a.cameraScale))) * g.content.z * 0.5
        let cur = Double(simd_length(b.cursor.position - a.cursor.position)) * k * sc
        let n = Int(ceil(max(cam, zoom, cur) / 2))
        return min(max(n, 1), r.quality == .preview ? min(2, tl.camera.maxSamples) : tl.camera.maxSamples)
    }

    private func scene(_ cb: MTLCommandBuffer, into tex: MTLTexture, st: FrameState, r: RenderRequest, g: Geometry, src: MTLTexture, web: MTLTexture?) {
        let tl = r.timeline
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = tex; pd.colorAttachments[0].loadAction = .clear; pd.colorAttachments[0].storeAction = .store
        pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let e = cb.makeRenderCommandEncoder(descriptor: pd) else { return }
        let canvasF = SIMD2<Float>(Float(g.canvas.x), Float(g.canvas.y)), content = SIMD4<Float>(g.content)
        let cam = SIMD2<Double>(Double(st.cameraCenter.x), Double(st.cameraCenter.y)), sc = Double(st.cameraScale)
        let pxPerSrc = g.content.z / g.src.x
        func draw() { e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4) }

        // content
        e.setRenderPipelineState(pContent); quad(e, content, canvasF)
        frag(e, ContentU(content: content, src: SIMD2<Float>(g.src), cam: st.cameraCenter, scale: st.cameraScale,
                         radius: Float(g.radius), border: tl.style.innerBorder ? 1 : 0, p: 0))
        e.setFragmentTexture(src, index: 0); draw()

        // click rings
        if tl.cursor.clickRing != nil {
            e.setRenderPipelineState(pRing)
            let R = 70 * g.ui * pow(sc, 0.5)
            for ring in st.clickFX {
                let c = g.toCanvas(SIMD2<Double>(Double(ring.position.x), Double(ring.position.y)), cam: cam, scale: sc)
                quad(e, SIMD4<Float>(Float(c.x - R), Float(c.y - R), Float(2 * R), Float(2 * R)), canvasF)
                frag(e, RingU(content: content, color: SIMD4(1, 1, 1, 0.7), center: SIMD2<Float>(c), radius: Float(R),
                              progress: ring.progress, cr: Float(g.radius)))
                draw()
            }
        }

        // cursor
        let cs = st.cursor
        if cs.opacity > 0.01, let atlas, let ent = atlas.entry(cs.shape) {
            let S = 32 * r.backingScale * tl.cursor.size * pxPerSrc * pow(sc, 1 - tl.cursor.zoomCompensation) * Double(cs.press)
            let c = g.toCanvas(SIMD2<Double>(Double(cs.position.x), Double(cs.position.y)), cam: cam, scale: sc)
            e.setRenderPipelineState(pCursor)
            quad(e, SIMD4<Float>(Float(c.x - ent.hot.x * S), Float(c.y - ent.hot.y * S), Float(S), Float(S)), canvasF)
            frag(e, CursorU(content: content, radius: Float(g.radius), opacity: cs.opacity, layer: UInt32(ent.layer), p: 0))
            e.setFragmentTexture(atlas.texture, index: 0); draw()
        }

        // webcam bubble
        if let wl = tl.webcam, let web {
            let m = g.canvas.x * 0.03, size = g.canvas.x * wl.size, margin = 40 * g.ui
            let x = (wl.corner == .topLeft || wl.corner == .bottomLeft) ? m : g.canvas.x - m - size
            let y = (wl.corner == .topLeft || wl.corner == .topRight) ? m : g.canvas.y - m - size
            let crop = st.webcamCrop, ww = Double(web.width)
            e.setRenderPipelineState(pWeb)
            quad(e, SIMD4<Float>(Float(x - margin), Float(y - margin), Float(size + 2 * margin), Float(size + 2 * margin)), canvasF)
            frag(e, WebU(crop: crop, bubble: SIMD4<Float>(Float(x), Float(y), Float(size), Float(size)), radius: Float(size * 0.22),
                         shape: wl.shape == .circle ? 0 : 1, mirror: wl.mirror ? 1 : 0, border: wl.border ? 1 : 0, shadow: wl.shadow ? 1 : 0,
                         bw: Float(3 * g.ui), minif: Float(Double(crop.z) * ww / size), margin: Float(margin)))
            e.setFragmentTexture(web, index: 0); draw()
        }
        e.endEncoding()
    }

    private func quad(_ e: MTLRenderCommandEncoder, _ rect: SIMD4<Float>, _ canvas: SIMD2<Float>) {
        var q = QuadU(rect: rect, canvas: canvas)
        e.setVertexBytes(&q, length: MemoryLayout<QuadU>.stride, index: 0)
    }
    private func frag<T: BitwiseCopyable>(_ e: MTLRenderCommandEncoder, _ v: T, _ i: Int = 0) {
        var x = v
        e.setFragmentBytes(&x, length: MemoryLayout<T>.stride, index: i)
    }
}