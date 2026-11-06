import Foundation
import Metal
import MetalKit
import AppKit
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
    /// The analysis cache, if this recording has generated on-device person mattes.
    public var personMaskDirectory: URL?
    /// Preview-only animation phase for the pixel-dither backdrop. Always 0 for export, so output stays deterministic.
    public var uiTime: Double
    public var pointer: SIMD4<Float>
    /// Keep the scene premultiplied and leave the canvas transparent. Used by
    /// ProRes 4444 deliveries that need an alpha channel.
    public var transparent: Bool
    /// Draw only rings and the cursor, over a transparent canvas. Used to
    /// export the cursor as its own video layer.
    public var cursorOnly: Bool
    public init(timeline: Timeline, t: Double, screen: SourceFrame, webcam: SourceFrame? = nil, canvas: SIMD2<Int>,
                fps: Double = 60, backingScale: Double = 2, quality: RenderQuality = .export, uiTime: Double = 0,
                pointer: SIMD4<Float> = .zero, personMaskDirectory: URL? = nil,
                transparent: Bool = false, cursorOnly: Bool = false) {
        self.timeline = timeline; self.t = t; self.screen = screen; self.webcam = webcam
        self.canvas = canvas; self.fps = fps; self.backingScale = backingScale; self.quality = quality; self.uiTime = uiTime; self.pointer = pointer
        self.personMaskDirectory = personMaskDirectory; self.transparent = transparent; self.cursorOnly = cursorOnly
    }
}

/// Frame placement inside the canvas. Pixel-snapped so the frame edge is crisp. Shared with the UI (focus editor).
public struct Geometry: Sendable {
    public var canvas: SIMD2<Double>, src: SIMD2<Double>
    public var content: SIMD4<Double>        // x y w h in canvas px
    public var radius: Double, ui: Double
    public init(canvas c: SIMD2<Int>, src: SIMD2<Double>, style: Style) {
        let transform = ZoomTransform(canvas: c, source: src, style: style)
        canvas = transform.canvas; self.src = src
        content = transform.videoRect
        ui = canvas.x / 1440; radius = style.cornerRadius * ui
    }
    /// Source px -> canvas px for a given camera.
    public func toCanvas(_ p: SIMD2<Double>, cam: SIMD2<Double>, scale: Double) -> SIMD2<Double> {
        let center = ZoomTransform.clamp(cam, source: src, scale: scale)
        let view = src / max(scale, 1), n = (p - (center - view / 2)) / view
        return SIMD2(content.x + n.x * content.z, content.y + n.y * content.w)
    }
}

private struct QuadU { var rect: SIMD4<Float>; var canvas: SIMD2<Float> }
private struct BackdropU { var content: SIMD4<Float>; var canvas: SIMD2<Float>; var angle: Float; var count: Int32; var kind: Int32
                           var radius: Float; var shadow: Float; var scale: Float; var cell: Float; var density: Float; var hasWall: Int32
                           var time: Float; var pointer: SIMD4<Float> }
private struct ContentU { var content: SIMD4<Float>; var src: SIMD2<Float>; var cam: SIMD2<Float>; var scale: Float; var radius: Float; var border: Float; var p: Float; var tilt: SIMD2<Float> }
private struct CursorU { var content: SIMD4<Float>; var radius: Float; var opacity: Float; var layer: UInt32; var p: Float }
private struct RingU { var content: SIMD4<Float>; var color: SIMD4<Float>; var center: SIMD2<Float>; var radius: Float; var progress: Float; var cr: Float }
private struct PrivacyU {
    var content: SIMD4<Float>
    var sourceRect: SIMD4<Float>
    var sourceSize: SIMD2<Float>
    var safeSample: SIMD2<Float>
    var radius: Float
    var mode: Int32
    var block: Float
    var pad: Float
}
private struct WebU {
    var crop: SIMD4<Float>; var bubble: SIMD4<Float>
    var radius: Float; var shape: Float; var mirror: Float; var border: Float
    var shadow: Float; var bw: Float; var minif: Float; var margin: Float
    var opacity: Float; var maskMode: Float; var matteMix: Float; var detail: Float
    var canvasColor: SIMD4<Float>
}
private struct AccU { var weight: Float }
private struct ResU { var levels: Float; var seed: UInt32; var blur: Float; var alpha: Float }
private struct TextSpriteU { var opacity: Float }
private struct LoupeU {
    var glass: SIMD4<Float>    // centre x,y, radius, border
    var source: SIMD4<Float>   // target x,y, width,height
    var zoom: SIMD2<Float>     // camera scale, magnification
    var opacity: Float
    var round: Float
    var radius: Float
}
private struct HighlightU {
    var rect: SIMD4<Float>
    var content: SIMD4<Float>
    var opacity: Float
    var strength: Float
    var mode: Int32
}
private struct BackdropKey: Equatable { var style: Style; var size: SIMD2<Int>; var wall: String; var phase: Double; var pointer: SIMD4<Float> }
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

/// Counts presented frames and how often a frame missed its expected vsync.
/// This turns "feels smooth" into a number the debug HUD can show.
public final class PresentStats: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<(last: Double, frames: Int, late: Int, worst: Double)>(initialState: (0, 0, 0, 0))
    public init() {}
    public func record(_ time: Double, expected: Double) {
        guard time > 0 else { return }
        state.withLock { s in
            if s.last > 0 {
                let delta = time - s.last
                s.frames += 1
                if delta > expected * 1.5 { s.late += 1 }
                s.worst = max(s.worst, delta)
            }
            s.last = time
        }
    }
    public var snapshot: (frames: Int, late: Int, worstMs: Double) {
        state.withLock { ($0.frames, $0.late, $0.worst * 1000) }
    }
    public func reset() { state.withLock { $0 = (0, 0, 0, 0) } }
}

/// Pure-ish renderer: output depends only on (RenderRequest). Owned by ONE render queue; not thread-safe.
/// Preview and export call the same `encode`. Triple-buffered; the frame loop allocates nothing after warm-up.
public final class Renderer: @unchecked Sendable {
    public let device: MTLDevice
    public let presentStats = PresentStats()
    private let queue: MTLCommandQueue
    private let lib: MTLLibrary
    private let pBackdrop, pContent, pCursor, pRing, pWeb, pPrivacy, pAccum: MTLRenderPipelineState
    private let pTextSprite: MTLRenderPipelineState
    private let pHighlight: MTLRenderPipelineState
    private let pLoupe: MTLRenderPipelineState
    private let textCache = TextOverlayCache()
    private var pResolve: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var personMatte: PersonMatteSequence?
    private let sem = DispatchSemaphore(value: 3)
    /// EMA of GPU seconds per motion-blur sample, used to size preview blur.
    private let perSample = OSAllocatedUnfairLock<Double>(initialState: 0)
    private var slot = 0
    private var work: [MTLTexture] = [], accum: [MTLTexture] = []
    private var backdrop: MTLTexture?
    private var backdropKey: BackdropKey?
    private var backdropMipmapped = false
    private var size = SIMD2<Int>(0, 0)
    private var wallTex: MTLTexture?
    private var wallID = ""
    private var cameraBackground: MTLTexture?
    private var cameraBackgroundID = ""
    private let screenMip = MipCache(), webMip = MipCache()
    private var atlas: CursorAtlas?
    private var atlasPack: CursorPack?
    private var customs: [CustomCursor] = []
    private let outCache: CVMetalTextureCache

    public init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw RenderError.noDevice }
        let l = try Self.library(d), f = MTLPixelFormat.rgba16Float
        device = d; queue = q; lib = l
        pBackdrop = try Self.pipe(d, l, "backdropFS", f, 0)
        pContent = try Self.pipe(d, l, "contentFS", f, 1)
        pCursor = try Self.pipe(d, l, "cursorFS", f, 1)
        pRing = try Self.pipe(d, l, "ringFS", f, 1)
        pPrivacy = try Self.pipe(d, l, "privacyFS", f, 1)
        pWeb = try Self.pipe(d, l, "webFS", f, 1)
        pAccum = try Self.pipe(d, l, "accumFS", f, 2)
        pTextSprite = try Self.pipe(d, l, "textSpriteFS", f, 1)
        pHighlight = try Self.pipe(d, l, "highlightFS", f, 1)
        pLoupe = try Self.pipe(d, l, "loupeFS", f, 1)
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, d, nil, &c)
        guard let c else { throw RenderError.noDevice }
        outCache = c
    }

    /// Prefer the metallib SwiftPM builds. Older Xcode toolchains only copy
    /// `Shaders.metal` into the bundle, so compile it once as a fallback
    /// instead of failing to launch.
    private static func library(_ d: MTLDevice) throws -> MTLLibrary {
        if let lib = try? d.makeDefaultLibrary(bundle: .module) { return lib }
        guard let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw RenderError.pipeline("Missing default.metallib and Shaders.metal")
        }
        return try d.makeLibrary(source: source, options: nil)
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

    /// User-selected image is decoded only on path/version change, never per frame.
    private func loadCameraBackgroundIfNeeded(_ path: String?) {
        guard let path, !path.isEmpty else { cameraBackgroundID = ""; cameraBackground = nil; return }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let version = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let id = "\(url.path)#\(version)"
        guard id != cameraBackgroundID else { return }
        cameraBackgroundID = id
        cameraBackground = try? MTKTextureLoader(device: device)
            .newTexture(URL: url, options: [.SRGB: false])
    }

    /// The Mac's own desktop picture, loaded once per wallpaper change. No download, no bundled asset.
    private func loadWallpaperIfNeeded() {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            wallTex = nil; wallID = ""; return
        }
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let id = "\(url.path)#\(stamp)"
        guard id != wallID else { return }
        wallID = id; wallTex = nil
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let w = cg.width, h = cg.height, bytes = w * 4
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]; d.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: d) else { return }
        var data = [UInt8](repeating: 0, count: bytes * h)
        data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytes,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: bytes)
        wallTex = tex
    }

    private func ensureTargets(_ s: SIMD2<Int>, backdropBlur: Bool) {
        guard s != size || backdropMipmapped != backdropBlur else { return }
        for _ in 0..<3 { sem.wait() }
        func mk(mipmapped: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                               width: s.x, height: s.y, mipmapped: mipmapped)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        work = (0..<3).map { _ in mk() }; accum = (0..<3).map { _ in mk() }
        // Allocate mip storage only when the user enables blur. Ordinary video
        // exports keep their previous memory footprint and renderer stages.
        backdrop = mk(mipmapped: backdropBlur)
        backdropMipmapped = backdropBlur
        backdropKey = nil
        size = s
        for _ in 0..<3 { sem.signal() }
    }

    // MARK: Entry points

    /// Preview: renders into the layer's next drawable. Never blocks: returns false when all 3 frames are in flight.
    /// `presentAt` lets the caller present on an exact host-clock instant, so a
    /// frame rendered one vsync ahead has a full frame of scheduling slack.
    @discardableResult
    public func draw(_ r: RenderRequest, to layer: CAMetalLayer, presentAt: Double? = nil) -> Bool {
        guard let dr = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return false }
        guard encode(r, output: dr.texture, commandBuffer: cb, wait: false) else { return false }
        let stats = presentStats, expected = 1 / max(r.fps, 1)
        dr.addPresentedHandler { d in stats.record(d.presentedTime, expected: expected) }
        if let t = presentAt, t > CACurrentMediaTime() { cb.present(dr, atTime: t) } else { cb.present(dr) }
        cb.commit(); return true
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
        let tl = r.timeline
        ensureTargets(cs, backdropBlur: tl.style.zoomBackgroundBlur)
        if wait { sem.wait() } else if sem.wait(timeout: .now()) != .success { return false }
        let s = slot; slot = (slot + 1) % 3
        let g = Geometry(canvas: cs, src: SIMD2(Double(r.screen.texture.width), Double(r.screen.texture.height)), style: tl.style)

        guard let srcTex = screenMip.texture(for: r.screen, device: device, cb: cb), let bd = backdrop else { sem.signal(); return false }
        var webTex: MTLTexture?
        if tl.webcam != nil, let w = r.webcam { webTex = webMip.texture(for: w, device: device, cb: cb) }
        // Cache a bounded, timestamped pair of Vision mask textures per Metal
        // in-flight slot. Both preview and export traverse this same path.
        var matte: PersonMatteSequence.Pair?
        if tl.webcam != nil, let info = tl.derived?.personMask,
           let dir = r.personMaskDirectory {
            let url = dir.appendingPathComponent(info.file)
            if personMatte?.url != url || personMatte?.info != info {
                personMatte = PersonMatteSequence(url: url, info: info)
            }
            matte = personMatte?.sample(at: tl.timeMap.source(atOutput: r.t), slot: s, device: device)
        } else {
            personMatte = nil
        }
        if atlas == nil || atlasPack != tl.cursor.pack {
            atlas = CursorAtlas(device: device, queue: queue, pack: tl.cursor.pack, customs: customs); atlasPack = tl.cursor.pack
        }
        let canvasF = SIMD2<Float>(Float(g.canvas.x), Float(g.canvas.y))

        // 1. backdrop cache (style or size change only)
        if tl.style.background == .wallpaper || tl.webcam?.backdrop == .wallpaper { loadWallpaperIfNeeded() }
        if tl.webcam?.backdrop == .image { loadCameraBackgroundIfNeeded(tl.webcam?.backdropImagePath) }
        let patterned = tl.style.background == .wave || tl.style.background == .field
        let backgroundTime = patterned ? (r.quality == .export ? r.t : r.uiTime)
            : (tl.style.background == .dither && r.quality == .preview ? r.uiTime : 0)
        let pointer = tl.style.background == .wave && r.quality == .preview ? r.pointer : .zero
        let key = BackdropKey(style: tl.style, size: cs, wall: tl.style.background == .wallpaper ? wallID : "",
                              phase: backgroundTime, pointer: pointer)
        let needsBackdrop = !r.transparent && !r.cursorOnly
        if needsBackdrop && backdropKey != key {
            backdropKey = key
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = bd; pd.colorAttachments[0].loadAction = .dontCare; pd.colorAttachments[0].storeAction = .store
            if let e = cb.makeRenderCommandEncoder(descriptor: pd) {
                e.setRenderPipelineState(pBackdrop)
                quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
                let st = tl.style
                var cols = st.colors.isEmpty ? [SIMD4<Float>(0, 0, 0, 1)] : st.colors.map(\.simd)
                if cols.count < 6 { cols += [SIMD4<Float>](repeating: cols[0], count: 6 - cols.count) }
                let kind: Int32 = switch st.background {
                case .gradient: 0
                case .mesh: 1
                case .dither: 3
                case .wallpaper: 4
                case .canvas: 5
                case .solid: 2
                case .wave: 6
                case .field: 7
                }
                if st.background == .wallpaper, let wallTex { e.setFragmentTexture(wallTex, index: 0) }
                frag(e, BackdropU(content: SIMD4<Float>(g.content), canvas: canvasF, angle: Float(st.gradientAngle * .pi / 180),
                                  count: Int32(max(st.colors.count, 1)), kind: kind,
                                  radius: Float(g.radius), shadow: Float(st.shadow), scale: Float(g.ui * 1.33),
                                  cell: Float(max(2, st.ditherCell * g.ui)), density: Float(st.ditherDensity),
                                  hasWall: st.background == .wallpaper && wallTex != nil ? 1 : 0,
                                  time: Float(backgroundTime), pointer: pointer))
                cols.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                e.endEncoding()
            }
            if tl.style.zoomBackgroundBlur, let blit = cb.makeBlitCommandEncoder() {
                // Generate the full mip pyramid only after the backdrop
                // itself changed. Screen content never enters these mipmaps.
                blit.generateMipmaps(for: bd)
                blit.endEncoding()
            }
        }

        // 2. sub-frames (motion blur): scene over transparent, accumulated, resolved over the backdrop
        let K = sampleCount(r, g)
        let dt = 1 / max(r.fps, 1)
        for i in 0..<K {
            let off = ((Double(i) + 0.5) / Double(K) - 0.5) * tl.camera.shutter * dt
            var st = r.live ?? tl.evaluate(at: r.t + off)
            if r.live == nil, tl.derived == nil { st.cameraCenter = SIMD2<Float>(Float(g.src.x / 2), Float(g.src.y / 2)) }
            scene(cb, into: work[s], st: st, r: r, g: g, src: srcTex, web: webTex, matte: matte)
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
            let zoom = r.live?.cameraScale ?? tl.evaluate(at: r.t).cameraScale
            frag(e, ResU(levels: fmt == .bgr10a2Unorm ? 1023 : 255,
                         seed: UInt32(truncatingIfNeeded: Int(r.t * 1000)),
                         blur: BackdropBlur.mipLevel(enabled: tl.style.zoomBackgroundBlur,
                                                     cameraScale: zoom),
                         alpha: r.transparent || r.cursorOnly ? 0 : 1))
            e.setFragmentTexture(K > 1 ? accum[s] : work[s], index: 0); e.setFragmentTexture(bd, index: 1)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); e.endEncoding()
        }
        let sem = self.sem, keep = Keep(o: (r.screen, r.webcam)), cost = perSample, samples = Double(K)
        cb.addCompletedHandler { b in
            withExtendedLifetime(keep) {}
            let gpu = b.gpuEndTime - b.gpuStartTime
            if gpu > 0 { cost.withLock { $0 = $0 == 0 ? gpu / samples : $0 * 0.9 + 0.1 * gpu / samples } }
            sem.signal()
        }
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
        var cap = tl.camera.maxSamples
        if r.quality == .preview {
            // Spend at most half of the frame budget on blur samples. Once
            // the GPU cost is measured, this can rise above 2 on fast Macs
            // and falls back to 2 before the first measurement.
            let per = perSample.withLock { $0 }
            let budget = per > 0 ? min(max(Int(0.5 / max(r.fps, 1) / per), 1), 4) : 2
            cap = min(budget, tl.camera.maxSamples)
        }
        return min(max(n, 1), cap)
    }

    private func scene(_ cb: MTLCommandBuffer, into tex: MTLTexture, st: FrameState, r: RenderRequest, g: Geometry,
                       src: MTLTexture, web: MTLTexture?, matte: PersonMatteSequence.Pair?) {
        let tl = r.timeline
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = tex; pd.colorAttachments[0].loadAction = .clear; pd.colorAttachments[0].storeAction = .store
        pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let e = cb.makeRenderCommandEncoder(descriptor: pd) else { return }
        let canvasF = SIMD2<Float>(Float(g.canvas.x), Float(g.canvas.y)), content = SIMD4<Float>(g.content)
        let sc = max(Double(st.cameraScale), 1)
        let cam = ZoomTransform.clamp(SIMD2<Double>(Double(st.cameraCenter.x), Double(st.cameraCenter.y)), source: g.src, scale: sc)
        let pxPerSrc = g.content.z / g.src.x
        func draw() { e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4) }

        // content
        e.setRenderPipelineState(pContent); quad(e, content, canvasF)
        frag(e, ContentU(content: content, src: SIMD2<Float>(g.src), cam: SIMD2<Float>(cam), scale: Float(sc),
                         radius: Float(g.radius), border: tl.style.innerBorder ? 1 : 0, p: 0))
        e.setFragmentTexture(src, index: 0); draw()

        // Every privacy mask is anchored to SOURCE pixels and transformed by
        // the exact same zoom camera as content. Mask before drawing cursor
        // and webcam, never by stamping a static canvas rectangle afterward.
        if !st.emphasis.masks.isEmpty {
            e.setRenderPipelineState(pPrivacy)
            let sourceSize = SIMD2<Float>(Float(g.src.x), Float(g.src.y))
            for mask in st.emphasis.masks {
                guard let projected = PrivacyMaskGeometry.canvasRect(mask.rect, geometry: g,
                                                                      camera: cam, scale: sc),
                      projected.z > 0.2, projected.w > 0.2 else { continue }
                let safe = PrivacyMaskGeometry.outsideSample(mask.rect, sourceSize: sourceSize)
                let requested: Int32 = switch mask.mode {
                case .blur: 0
                case .pixelate: 1
                case .solid: 2
                case .blend: 3
                }
                // If no region outside the mask exists, Blend falls back to
                // an opaque solid instead of sampling protected pixels.
                let mode: Int32 = requested == 3 && safe == nil ? 2 : requested
                quad(e, projected, canvasF)
                frag(e, PrivacyU(content: content, sourceRect: mask.rect,
                                 sourceSize: sourceSize, safeSample: safe ?? .zero,
                                 radius: Float(g.radius), mode: mode, block: 20, pad: 0))
                e.setFragmentTexture(src, index: 0)
                draw()
            }
        }

        // Highlight geometry follows the exact source-pixel camera transform.
        // Dimmer is drawn AFTER privacy redaction and never resamples raw pixels.
        if !st.emphasis.highlights.isEmpty {
            e.setRenderPipelineState(pHighlight)
            for mark in st.emphasis.highlights where mark.opacity > 0.001 {
                let start = g.toCanvas(SIMD2(Double(mark.rect.x), Double(mark.rect.y)), cam: cam, scale: sc)
                let end = g.toCanvas(SIMD2(Double(mark.rect.x + mark.rect.z),
                                            Double(mark.rect.y + mark.rect.w)), cam: cam, scale: sc)
                let bounds = SIMD4<Float>(Float(min(start.x, end.x)), Float(min(start.y, end.y)),
                                           Float(abs(end.x - start.x)), Float(abs(end.y - start.y)))
                let mode: Int32 = switch mark.style {
                case .dim: 0
                case .outline: 1
                case .glow: 2
                }
                quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
                frag(e, HighlightU(rect: bounds, content: content, opacity: mark.opacity,
                                    strength: mark.dim, mode: mode))
                draw()
            }
        }

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
            let S = 32 * r.backingScale * tl.cursor.size * pxPerSrc * pow(sc, 1 - tl.cursor.effectiveCompensation) * Double(cs.press)
            let c = g.toCanvas(SIMD2<Double>(Double(cs.position.x), Double(cs.position.y)), cam: cam, scale: sc)
            e.setRenderPipelineState(pCursor)
            quad(e, SIMD4<Float>(Float(c.x - ent.hot.x * S), Float(c.y - ent.hot.y * S), Float(S), Float(S)), canvasF)
            frag(e, CursorU(content: content, radius: Float(g.radius), opacity: cs.opacity, layer: UInt32(ent.layer), p: 0))
            e.setFragmentTexture(atlas.texture, index: 0); draw()
        }

        // Webcam placement is solved by the Director at output time. Never
        // replace its animated position with a hard-coded corner.
        if let wl = tl.webcam, let web {
            let settings = tl.layoutSettings[st.layoutKind]
            let rect = st.layout.cameraRect
            let opacity = tl.derived == nil ? 1 : max(0, min(st.layout.cameraOpacity, 1))
            let m = g.canvas.x * 0.03, legacySize = g.canvas.x * wl.size
            let legacyX = (wl.corner == .topLeft || wl.corner == .bottomLeft) ? m : g.canvas.x - m - legacySize
            let legacyY = (wl.corner == .topLeft || wl.corner == .topRight) ? m : g.canvas.y - m - legacySize
            let x = tl.derived == nil ? legacyX : Double(rect.x) * g.canvas.x
            let y = tl.derived == nil ? legacyY : Double(rect.y) * g.canvas.y
            let width = tl.derived == nil ? legacySize : Double(rect.z) * g.canvas.x
            let height = tl.derived == nil ? legacySize : Double(rect.w) * g.canvas.y
            if opacity > 0.001, width > 1, height > 1 {
                let margin = 24 * g.ui
                let crop = st.webcamCrop, ww = Double(web.width)
                let region = SIMD4<Float>(Float(x), Float(y), Float(width), Float(height))
                let cutout = st.layout.cutoutBlend > 0.5 && wl.backdrop == .original
                var maskMode: Float = switch wl.backdrop {
                case .original: cutout ? 1 : 0
                case .transparent: 1
                case .wallpaper: wallTex == nil ? 3 : 2
                case .canvas: 3
                case .image: cameraBackground == nil ? 3 : 2
                }
                if matte == nil { maskMode = 0 } // Never simulate a missing AI mask.
                let color = tl.style.colors.first?.simd ?? SIMD4<Float>(0.1, 0.1, 0.1, 1)
                let detail: Float = wl.enhancement == .crisp ? Float(min(max(wl.detailAmount, 0), 1)) : 0
                e.setRenderPipelineState(pWeb)
                quad(e, SIMD4<Float>(Float(x - margin), Float(y - margin),
                                    Float(width + 2 * margin), Float(height + 2 * margin)), canvasF)
                frag(e, WebU(crop: crop, bubble: region, radius: Float(min(width, height) * Double(st.layout.cameraRadius)),
                             shape: st.layout.cameraRadius > 0.4 ? 0 : 1, mirror: settings.mirror ? 1 : 0,
                             border: settings.border && maskMode == 0 ? 1 : 0,
                             shadow: settings.shadow && maskMode == 0 ? 1 : 0,
                             bw: Float(3 * g.ui), minif: Float(Double(crop.z) * ww / max(width, 1)),
                             margin: Float(margin), opacity: opacity, maskMode: maskMode,
                             matteMix: matte?.fraction ?? 0, detail: detail, canvasColor: color))
                e.setFragmentTexture(web, index: 0)
                if let matte {
                    e.setFragmentTexture(matte.previous, index: 1)
                    e.setFragmentTexture(matte.next, index: 2)
                }
                if maskMode == 2 {
                    let background = wl.backdrop == .image ? cameraBackground : wallTex
                    if let background { e.setFragmentTexture(background, index: 3) }
                }
                draw()
            }
        }

        // Caption and manual text share this pass in both live preview and offline exports.
        // Both are source-time anchored; rasterization is cached by actual text/style,
        // with a different cache entry only when the highlighted word changes.
        var sprites: [TextOverlaySprite] = []
        if let caption = st.caption, tl.captions.enabled,
           let sprite = textCache.caption(caption, style: tl.captions.style,
                                          time: r.t, canvas: r.canvas, device: device) {
            sprites.append(sprite)
        }
        for manual in st.emphasis.texts {
            if let sprite = textCache.manual(manual, canvas: r.canvas, device: device) {
                sprites.append(sprite)
            }
        }
        if !sprites.isEmpty {
            e.setRenderPipelineState(pTextSprite)
            for sprite in sprites where sprite.opacity > 0.001 {
                let w = Float(sprite.texture.width), h = Float(sprite.texture.height)
                quad(e, SIMD4<Float>(sprite.center.x - w / 2, sprite.center.y - h / 2, w, h), canvasF)
                frag(e, TextSpriteU(opacity: sprite.opacity))
                e.setFragmentTexture(sprite.texture, index: 0)
                draw()
            }
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
