import Foundation
import Metal
import MetalKit
import AppKit
import CoreVideo
import QuartzCore
import ImageIO
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
    /// Preview clock for generated backdrops; export uses the timeline clock for deterministic motion.
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
    /// Per-corner radii in canvas px, ordered top-left, top-right, bottom-right,
    /// bottom-left. Equal values mean the uniform squircle path.
    public var radii: SIMD4<Double>
    public init(canvas c: SIMD2<Int>, src: SIMD2<Double>, style: Style) {
        let transform = ZoomTransform(canvas: c, source: src, style: style)
        canvas = transform.canvas; self.src = src
        content = transform.videoRect
        ui = canvas.x / 1440; radius = style.cornerRadius * ui
        let r = style.radii
        radii = SIMD4(r.tl, r.tr, r.br, r.bl) * ui
    }

    func positioned(in layout: ResolvedLayout, contentScale: Double) -> Geometry {
        let rect = SIMD4<Double>(layout.screenRect)
        guard rect.z > 0, rect.w > 0, rect.x.isFinite, rect.y.isFinite, rect.z.isFinite, rect.w.isFinite else { return self }
        let scale = min(max(contentScale, 0.3), 2)
        let size = SIMD2(rect.z * canvas.x, rect.w * canvas.y) * scale
        let center = SIMD2((rect.x + rect.z / 2) * canvas.x, (rect.y + rect.w / 2) * canvas.y)
        var result = self
        result.content = SIMD4(center.x - size.x / 2, center.y - size.y / 2, size.x, size.y)
        return result
    }
    /// Contained camera centre: the sampled view (`baseView / scale`, where the
    /// base view is the largest rect of `aspect` inside the crop) stays inside
    /// the crop — and therefore inside the source. A no-op for a feasible
    /// camera; the single safety net for a hostile one. This is the render-side
    /// twin of `CropSpace.visible`'s centre clamp, sharing its per-crop logic,
    /// with the caller choosing the base-view aspect.
    static func containedCenter(_ cam: SIMD2<Double>, crop: PxRect, aspect: Double, scale: Double) -> SIMD2<Double> {
        let base = CropSpace.baseView(crop: crop, aspect: aspect)
        let s = scale.isFinite ? max(scale, 1) : 1
        let vw = max(base.w / s, 1), vh = max(base.h / s, 1)
        func axis(_ v: Double, _ lo: Double, _ hi: Double, _ span: Double) -> Double {
            let a = lo + span / 2, b = hi - span / 2
            // Hostile centre (NaN/Inf) snaps to the crop centre — the same
            // fallback ZoomTransform.clamp and the rest of the layer use.
            guard v.isFinite, a.isFinite, b.isFinite else { return (lo + hi) / 2 }
            if b >= a { return min(max(v, a), b) }
            return (lo + hi) / 2
        }
        let x = axis(cam.x, crop.x, crop.x + crop.w, vw)
        let y = axis(cam.y, crop.y, crop.y + crop.h, vh)
        guard x.isFinite, y.isFinite else { return SIMD2(crop.x + crop.w / 2, crop.y + crop.h / 2) }
        return SIMD2(x, y)
    }

    /// Source px -> canvas px for a given camera.
    public func toCanvas(_ p: SIMD2<Double>, cam: SIMD2<Double>, scale: Double,
                         crop: CGRect? = nil, tilt: SIMD2<Float> = .zero) -> SIMD2<Double> {
        // The sampled view keeps the DRAWN rect's aspect, exactly as contentFS
        // draws it: one rule, one result, for the image and for the overlays.
        let bounds = crop ?? CGRect(x: 0, y: 0, width: src.x, height: src.y)
        let cropPx = PxRect(x: bounds.minX, y: bounds.minY, w: bounds.width, h: bounds.height)
        let s = scale.isFinite ? max(scale, 1) : 1
        let aspect = content.w > 1 ? content.z / content.w : 1
        let center = Geometry.containedCenter(cam, crop: cropPx, aspect: aspect, scale: s)
        let base = CropSpace.baseView(crop: cropPx, aspect: aspect)
        let view: SIMD2<Double> = SIMD2(base.w / s, base.h / s)
        let origin = center - view / 2
        let srcN = SIMD2<Float>(Float((p.x - origin.x) / view.x - 0.5),
                               Float((p.y - origin.y) / view.y - 0.5))
        // contentFS warps the canvas quad with the homography, so a source
        // point is drawn where the INVERSE warp puts it. Applying the same
        // inverse here keeps click rings and the cursor on their source pixels.
        let n = CameraTilt.inverseHomography(srcN, tiltDeg: tilt)
        return SIMD2(content.x + (Double(n.x) + 0.5) * content.z,
                     content.y + (Double(n.y) + 0.5) * content.w)
    }
}

private struct QuadU { var rect: SIMD4<Float>; var canvas: SIMD2<Float> }
private struct BackdropU { var content: SIMD4<Float>; var canvas: SIMD2<Float>; var angle: Float; var count: Int32; var kind: Int32
                           var canvasStyle: Int32; var radius: Float; var shadow: Float; var scale: Float; var cell: Float; var density: Float; var hasWall: Int32
                           var time: Float; var pointer: SIMD4<Float>; var wallBlur: Float; var imgAlpha: Float; var imgContrast: Float; var imgBright: Float
                           var saturation: Float; var canvasCenter: SIMD2<Float>; var canvasGround: SIMD4<Float> }
private struct ContentU {
    var content: SIMD4<Float>; var src: SIMD2<Float>; var cam: SIMD2<Float>
    var cropSize: SIMD2<Float>
    var scale: Float; var radius: Float; var border: Float
    var tilt: SIMD2<Float>; var radii: SIMD4<Float>
    var upRegion: SIMD4<Float>; var upTexSize: SIMD2<Float>; var upFactor: Float; var upBlend: Float; var opacity: Float
}
private struct CursorU { var content: SIMD4<Float>; var radius: Float; var opacity: Float; var layer: UInt32; var p: Float }
private struct RingU { var content: SIMD4<Float>; var color: SIMD4<Float>; var center: SIMD2<Float>; var radius: Float; var progress: Float; var fade: Float; var cr: Float; var mode: Int32; var cam: SIMD2<Float>; var scale: Float; var srcSize: SIMD2<Float> }
private struct SourceMaskGPU { var rect: SIMD4<Float>; var block: SIMD4<Float> }
private struct WebU {
    var crop: SIMD4<Float>; var bubble: SIMD4<Float>
    var radius: Float; var shape: Float; var mirror: Float; var border: Float
    var shadow: Float; var bw: Float; var minif: Float; var margin: Float
    var opacity: Float; var maskMode: Float; var matteMix: Float; var detail: Float
    var canvasColor: SIMD4<Float>
}
private struct AccU { var weight: Float }
private struct ResU { var levels: Float; var seed: UInt32; var alpha: Float }
private struct TextSpriteU {
    var opacity: Float; var blur: Float; var pad0: Float; var pad1: Float
    init(opacity: Float, blur: Float = 0) { self.opacity = opacity; self.blur = blur; pad0 = 0; pad1 = 0 }
}
private struct CaptionCardU {
    var rect: SIMD4<Float>; var tint: SIMD4<Float>; var canvas: SIMD2<Float>; var radius: Float; var opacity: Float
}
private struct BlurU { var dir: SIMD2<Float>; var sigma: Float; var pad0: Float; var pad1: Float }
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
private struct BackdropKey: Equatable {
    var style: Style; var size: SIMD2<Int>; var wall: String; var phase: Double; var pointer: SIMD4<Float>
    var shadowRect: SIMD4<Double>; var shadowOpacity: Float
}
private struct Keep: @unchecked Sendable { let o: Any }

/// BGRA source -> mip-mapped copy, regenerated only when a NEW source frame arrives (sample-and-hold reuses the chain).
/// SMOOTHNESS: the chain is only as deep as the frame actually needs, and a
/// small LRU keeps the allocations alive across frames: the next frame never
/// overwrites a texture that an earlier command buffer still reads.
private final class MipCache {
    private struct Entry { let tex: MTLTexture; var id: UInt64; var used: UInt64 }
    private var entries: [Entry] = []
    private var tick: UInt64 = 0
    private let capacity = 4

    func texture(for f: SourceFrame, levels: Int, device: MTLDevice, cb: MTLCommandBuffer) -> MTLTexture? {
        tick &+= 1
        let w = f.texture.width, h = f.texture.height
        func fits(_ t: MTLTexture) -> Bool { t.width == w && t.height == h && t.mipmapLevelCount == levels }
        if let i = entries.firstIndex(where: { $0.id == f.id && fits($0.tex) }) {
            entries[i].used = tick
            return entries[i].tex
        }
        let victim = entries.count < capacity ? nil : entries.indices.min { entries[$0].used < entries[$1].used }
        let tex: MTLTexture
        if let v = victim, fits(entries[v].tex) {
            tex = entries[v].tex
        } else {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: levels > 1)
            d.mipmapLevelCount = levels
            d.usage = [.shaderRead, .renderTarget]; d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { return nil }
            tex = t
        }
        guard let b = cb.makeBlitCommandEncoder() else { return nil }
        b.copy(from: f.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
               sourceSize: MTLSize(width: w, height: h, depth: 1), to: tex, destinationSlice: 0, destinationLevel: 0,
               destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        if levels > 1 { b.generateMipmaps(for: tex) }
        b.endEncoding()
        let entry = Entry(tex: tex, id: f.id, used: tick)
        if let v = victim { entries[v] = entry } else { entries.append(entry) }
        return tex
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
    private let pBackdrop, pContent, pCursor, pRing, pWeb, pAccum: MTLRenderPipelineState
    private let pSourceMask: MTLComputePipelineState
    private var maskedSources: [MTLTexture?] = [nil, nil, nil]
    /// SMOOTHNESS: cache key of the last privacy-mask pass per in-flight slot.
    /// Identical source + masks ⇒ no GPU work at all.
    private var maskKey: [UInt64?] = [nil, nil, nil]
    private let pTextSprite: MTLRenderPipelineState
    private let pCaptionCard: MTLRenderPipelineState
    private let pBlur: MTLRenderPipelineState
    private let pHighlight: MTLRenderPipelineState
    private let pLoupe: MTLRenderPipelineState
    private let textCache = TextOverlayCache()
    private var pResolve: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var personMatte: PersonMatteSequence?
    private let sem = DispatchSemaphore(value: 3)
    /// SMOOTHNESS: preview drawables currently owned by us (cap 2 of the pool's 3).
    private let inFlight = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// One-shot release of an in-flight drawable slot; `presented` normally wins,
    /// the command-buffer completion is the fallback.
    private final class FrameSlot: @unchecked Sendable {
        private let released = OSAllocatedUnfairLock<Bool>(initialState: false)
        private let count: OSAllocatedUnfairLock<Int>
        init(count: OSAllocatedUnfairLock<Int>) { self.count = count }
        func release() {
            let once = released.withLock { s -> Bool in if s { return false }; s = true; return true }
            if once { count.withLock { $0 -= 1 } }
        }
    }
    /// EMA of GPU seconds per motion-blur sample, used to size preview blur.
    private let perSample = OSAllocatedUnfairLock<Double>(initialState: 0)
    /// Preview-only hysteresis state for `sampleCount` (export stays pure).
    private var blurK = 1, blurCooldown = 0
    /// Reused sub-frame scratch, one per in-flight slot. No per-frame array
    /// allocation after warm-up, and no buffer shared between simultaneous frames.
    private var stateBuffers: [[FrameState]] = [[], [], []]
    private var slot = 0
    private var work: [MTLTexture] = [], accum: [MTLTexture] = []
    /// One blurred copy per in-flight slot, allocated only when a caption card
    /// is actually on screen. The caption pass may not sample the render
    /// target it is writing, so the scene is copied before the card is drawn.
    private var captionSrc: [MTLTexture?] = [nil, nil, nil]
    /// Crossfade: the previous frame's finished scene and the blended mix.
    /// `encode` is serial on the render queue, so one pair suffices; encoding
    /// order guarantees the next frame reads what this one published.
    private var fadePrev: MTLTexture?
    private var fadeMix: MTLTexture?
    private var fadeSize = SIMD2<Int>(0, 0)
    private var fadeValid = false
    private var fadeTime = 0.0
    /// Quarter-resolution ping-pong pair for the card's separable Gaussian.
    private var blurA: [MTLTexture?] = [nil, nil, nil]
    private var blurB: [MTLTexture?] = [nil, nil, nil]
    private var backdrop: MTLTexture?
    private var backdropKey: BackdropKey?
    private var size = SIMD2<Int>(0, 0)
    /// SMOOTHNESS: image assets live behind a lock and decode off the render
    /// thread. The frame path only snapshots them, never touches disk/AppKit.
    private struct Assets: Sendable {
        var styleImage: TexBox?
        var wall: TexBox?
        var cameraBackground: TexBox?
        var styleImageID = ""; var styleRequest = ""
        var wallID = ""; var wallRequest = ""; var wallURL: URL?
        var cameraBackgroundID = ""; var cameraBackgroundRequest = ""
    }
    /// SMOOTHNESS: Metal objects are not Sendable; this box lets decoded
    /// textures cross into the lock-protected asset store from a decode task.
    private final class TexBox: @unchecked Sendable {
        let tex: MTLTexture
        init(_ tex: MTLTexture) { self.tex = tex }
    }
    private let assets = OSAllocatedUnfairLock(initialState: Assets())
    private let readyHandler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    private var styleImageSource = "", styleImageCheckedAt = 0.0
    private var cameraBackgroundSource = "", cameraBackgroundCheckedAt = 0.0
    private var wallpaperCheckedAt = 0.0
    private static let primedWallpaper = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private let screenMip = MipCache(), webMip = MipCache()
    private var atlas: CursorAtlas?
    private var atlasPack: CursorPack?
    private var customs: [CustomCursor] = []
    private let outCache: CVMetalTextureCache
    public let fxKernels: FXKernels?
    public let upscaler: Upscaler?

    public init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw RenderError.noDevice }
        let l = try Self.library(d), f = MTLPixelFormat.rgba16Float
        device = d; queue = q; lib = l
        pBackdrop = try Self.pipe(d, l, "backdropFS", f, 0)
        pContent = try Self.pipe(d, l, "contentFS", f, 1)
        pCursor = try Self.pipe(d, l, "cursorFS", f, 1)
        pRing = try Self.pipe(d, l, "ringFS", f, 1)
        guard let maskFunction = l.makeFunction(name: "pixelateMask") else { throw RenderError.pipeline("pixelateMask") }
        pSourceMask = try d.makeComputePipelineState(function: maskFunction)
        pWeb = try Self.pipe(d, l, "webFS", f, 1)
        pAccum = try Self.pipe(d, l, "accumFS", f, 2)
        pTextSprite = try Self.pipe(d, l, "textSpriteFS", f, 1)
        pCaptionCard = try Self.pipe(d, l, "captionCardFS", f, 1)
        pBlur = try Self.pipe(d, l, "gaussFS", f, 0)
        pHighlight = try Self.pipe(d, l, "highlightFS", f, 1)
        pLoupe = try Self.pipe(d, l, "loupeFS", f, 1)
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, d, nil, &c)
        guard let c else { throw RenderError.noDevice }
        outCache = c
        let fk = try? FXKernels(device: d)
        fxKernels = fk
        upscaler = fk.map(Upscaler.init(kernels:))
        // SMOOTHNESS: compile the resolve pipelines up front so the first
        // preview frame never pays a shader compile on the render thread.
        for fmt in [MTLPixelFormat.bgra8Unorm, .bgr10a2Unorm] { pResolve[fmt] = try Self.pipe(d, l, "resolveFS", fmt, 0) }
        // Seed the wallpaper URL that the main thread already resolved.
        let seeded = Self.primedWallpaper.withLock { $0 }
        assets.withLock { $0.wallURL = seeded; $0.wallRequest = seeded?.path ?? "" }
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

    /// Fires when a background-decode task publishes a texture, so the preview
    /// can redraw the frame that previously showed the fallback colour.
    public func setOnAssetReady(_ h: (@Sendable () -> Void)?) { readyHandler.withLock { $0 = h } }
    private func fireAssetReady() { readyHandler.withLock { $0 }?() }

    /// AppKit is main-thread only. The wallpaper URL is resolved there and
    /// handed to whichever renderer draws next (preview and export share it).
    public static func resolveWallpaperURL() -> URL? {
        // NSScreen.main is the screen with the key window; without one (a
        // command-line run) fall back to the first attached display.
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return url
    }
    public static func primeWallpaper(_ url: URL? = nil) {
        let u = url ?? resolveWallpaperURL()
        primedWallpaper.withLock { $0 = u }
    }
    public func refreshWallpaperURL(_ url: URL?) {
        Self.primedWallpaper.withLock { $0 = url }
        assets.withLock { $0.wallURL = url; $0.wallRequest = url?.path ?? "" }
    }

    private func styleImageURL(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let root = AppAssets.directory(bundlePath: "Wallpapers", sourcePaths: ["App/public/assets/wallpapers"])
        let fallback = "paintings/claude-monet/claude-monet_water-lilies-agapanthus_cma-136510.webp"
        let relative = path == "serene-lake.jpg" ? fallback : path
        if let root { return root.appendingPathComponent(relative) }
        return URL(fileURLWithPath: path)
    }

    /// User-selected webcam background. Throttled to one stat per second; the
    /// decode itself runs off the render thread (export decodes inline so its
    /// first frame is already correct and deterministic).
    private func loadCameraBackgroundIfNeeded(_ path: String?, quality: RenderQuality) {
        guard let path, !path.isEmpty else {
            cameraBackgroundSource = ""
            assets.withLock { $0.cameraBackground = nil; $0.cameraBackgroundID = ""; $0.cameraBackgroundRequest = "" }
            return
        }
        let now = CACurrentMediaTime()
        if path == cameraBackgroundSource, now - cameraBackgroundCheckedAt < 1.0 { return }
        cameraBackgroundSource = path; cameraBackgroundCheckedAt = now
        let url = URL(fileURLWithPath: path)
        let version = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let id = "\(url.path)#\(version)"
        let current = assets.withLock { ($0.cameraBackgroundRequest, $0.cameraBackgroundID) }
        guard current.0 != id || current.1 != id else { return }
        assets.withLock { $0.cameraBackgroundRequest = id }
        if quality == .export {
            if let tex = try? MTKTextureLoader(device: device).newTexture(URL: url, options: [.SRGB: false]) {
                let boxed = TexBox(tex)
                assets.withLock { $0.cameraBackground = boxed; $0.cameraBackgroundID = id }
            }
        } else {
            decodeCameraBackground(url: url, id: id)
        }
    }

    /// A user photo or Unsplash download used as the canvas backdrop. Same
    /// throttle/decode split as the webcam background.
    private func loadStyleImageIfNeeded(_ path: String?, quality: RenderQuality) {
        guard let path, !path.isEmpty else {
            styleImageSource = ""
            assets.withLock { $0.styleImage = nil; $0.styleImageID = ""; $0.styleRequest = "" }
            return
        }
        let now = CACurrentMediaTime()
        if path == styleImageSource, now - styleImageCheckedAt < 1.0 { return }
        styleImageSource = path; styleImageCheckedAt = now
        let url = styleImageURL(path)
        let version = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let id = "\(url.path)#\(version)"
        let current = assets.withLock { ($0.styleRequest, $0.styleImageID) }
        guard current.0 != id || current.1 != id else { return }
        assets.withLock { $0.styleRequest = id }
        if quality == .export {
            if let tex = try? MTKTextureLoader(device: device).newTexture(URL: url, options: [.SRGB: false, .generateMipmaps: true]) {
                let boxed = TexBox(tex)
                assets.withLock { $0.styleImage = boxed; $0.styleImageID = id }
            }
        } else {
            decodeStyleImage(url: url, id: id)
        }
    }

    private func decodeStyleImage(url: URL, id: String) {
        let device = self.device
        Task.detached(priority: .utility) { [weak self] in
            guard let tex = try? await MTKTextureLoader(device: device)
                .newTexture(URL: url, options: [.SRGB: false, .generateMipmaps: true]) else { return }
            let boxed = TexBox(tex)
            self?.assets.withLock { if $0.styleRequest == id { $0.styleImage = boxed; $0.styleImageID = id } }
            self?.fireAssetReady()
        }
    }

    private func decodeCameraBackground(url: URL, id: String) {
        let device = self.device
        Task.detached(priority: .utility) { [weak self] in
            guard let tex = try? await MTKTextureLoader(device: device)
                .newTexture(URL: url, options: [.SRGB: false]) else { return }
            let boxed = TexBox(tex)
            self?.assets.withLock { if $0.cameraBackgroundRequest == id { $0.cameraBackground = boxed; $0.cameraBackgroundID = id } }
            self?.fireAssetReady()
        }
    }

    /// The Mac's own desktop picture, loaded once per wallpaper change. The URL
    /// is resolved on the main thread (`refreshWallpaperURL`); this only stats
    /// it, once a second, and decodes off the render thread.
    private func loadWallpaperIfNeeded(quality: RenderQuality) {
        let url = assets.withLock { $0.wallURL }
        guard let url else {
            assets.withLock { $0.wall = nil; $0.wallID = ""; $0.wallRequest = "" }
            return
        }
        let now = CACurrentMediaTime()
        if now - wallpaperCheckedAt < 1.0 { return }
        wallpaperCheckedAt = now
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let id = "\(url.path)#\(stamp)"
        let current = assets.withLock { ($0.wallRequest, $0.wallID) }
        guard current.0 != id || current.1 != id else { return }
        assets.withLock { $0.wallRequest = id }
        if quality == .export {
            if let tex = makeWallpaperTexture(url: url) {
                let boxed = TexBox(tex)
                assets.withLock { $0.wall = boxed; $0.wallID = id }
            }
        } else {
            decodeWallpaper(url: url, id: id)
        }
    }

    private func decodeWallpaper(url: URL, id: String) {
        Task.detached(priority: .utility) { [weak self] in
            guard let tex = self?.makeWallpaperTexture(url: url) else { return }
            let boxed = TexBox(tex)
            self?.assets.withLock { if $0.wallRequest == id { $0.wall = boxed; $0.wallID = id } }
            self?.fireAssetReady()
        }
    }

    /// ImageIO + CoreGraphics, so this is safe off the main thread (unlike NSImage).
    private func makeWallpaperTexture(url: URL) -> MTLTexture? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height, bytes = w * 4
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
        d.usage = [.shaderRead]; d.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
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
        if let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex); blit.endEncoding(); command.commit()
        }
        return tex
    }

    private func ensureTargets(_ s: SIMD2<Int>) {
        guard s != size else { return }
        // SMOOTHNESS: no GPU drain on a size change. Metal keeps every resource
        // an encoded command buffer touches alive until that buffer completes,
        // so the old targets stay valid on their own — waiting for them only
        // stalls the frame that triggered the resize.
        func mk() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                               width: s.x, height: s.y, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        var w: [MTLTexture] = [], a: [MTLTexture] = []
        for _ in 0..<3 {
            guard let t = mk(), let u = mk() else { return }
            w.append(t); a.append(u)
        }
        guard let b = mk() else { return }
        work = w; accum = a; backdrop = b
        backdropKey = nil
        captionSrc = [nil, nil, nil]; blurA = [nil, nil, nil]; blurB = [nil, nil, nil]
        maskedSources = [nil, nil, nil]; maskKey = [nil, nil, nil]
        size = s
        fadePrev = nil; fadeMix = nil; fadeValid = false; fadeSize = s
    }

    // MARK: Entry points

    /// Preview: renders into the layer's next drawable. Never blocks: returns false when the drawable budget is used.
    /// `presentAt` lets the caller present on an exact host-clock instant, so a
    /// frame rendered one vsync ahead has a full frame of scheduling slack.
    @discardableResult
    public func draw(_ r: RenderRequest, to layer: CAMetalLayer, presentAt: Double? = nil) -> Bool {
        // SMOOTHNESS: cap drawables in flight at two. `nextDrawable()` blocks
        // once the pool (3) is exhausted, stalling the render thread behind the
        // window server; dropping the frame is strictly cheaper.
        guard inFlight.withLock({ n -> Bool in if n >= 2 { return false }; n += 1; return true }) else { return false }
        guard let dr = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else {
            inFlight.withLock { $0 -= 1 }
            return false
        }
        // SMOOTHNESS: render at the drawable's real size. The tick's size can be
        // one resize behind the layer by the time the drawable arrives.
        var req = r
        req.canvas = SIMD2(dr.texture.width, dr.texture.height)
        guard encode(req, output: dr.texture, commandBuffer: cb, wait: false) else {
            inFlight.withLock { $0 -= 1 }
            return false
        }
        let stats = presentStats, expected = 1 / max(r.fps, 1)
        let slot = FrameSlot(count: inFlight)
        dr.addPresentedHandler { d in slot.release(); stats.record(d.presentedTime, expected: expected) }
        // Fallback release when presentation is skipped (encoding error, layer
        // torn down mid-flight); the slot itself is one-shot.
        cb.addCompletedHandler { _ in slot.release() }
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
        // A non-finite request time must never reach timeline evaluation or a
        // shader uniform. Holding the frame at t=0 is the honest fallback.
        let t = r.t.isFinite ? r.t : 0
        ensureTargets(cs)
        if wait { sem.wait() } else if sem.wait(timeout: .now()) != .success { return false }
        let s = slot; slot = (slot + 1) % 3
        let g = Geometry(canvas: cs, src: SIMD2(Double(r.screen.texture.width), Double(r.screen.texture.height)), style: tl.style)

        // SMOOTHNESS: the sub-frame states are evaluated once, up front. They
        // decide the mip depth of this frame, and the loop below reuses them
        // instead of re-evaluating the timeline per sample.
        let K = sampleCount(r, g)
        let dt = 1 / max(r.fps, 1)
        let tiltMode = tl.camera.tilt
        stateBuffers[s].removeAll(keepingCapacity: true)
        stateBuffers[s].reserveCapacity(K)
        for i in 0..<K {
            let off = ((Double(i) + 0.5) / Double(K) - 0.5) * tl.camera.shutter * dt
            var st = r.live ?? tl.evaluate(at: t + off)
            if r.live == nil, tl.derived == nil { st.cameraCenter = SIMD2<Float>(Float(g.src.x / 2), Float(g.src.y / 2)) }
            // 3D is content and mode-controlled. Gate EVERY sub-frame here so a
            // leaked or stale tilt can never reach contentFS or the export.
            // Each sub-frame keeps its own evaluated tilt; only the mode-aware
            // clamp is applied, so 60/120/240 fps stay deterministic.
            st.cameraTilt = CameraTilt.effective(st.cameraTilt, mode: tiltMode,
                                                maxYaw: tl.camera.maxYaw,
                                                maxPitch: tl.camera.maxPitch)
            stateBuffers[s].append(st)
        }
        let states = stateBuffers[s]
        // SMOOTHNESS: the mip chain is only read when the source is minified.
        // A zoomed-in frame samples level 0 only, so the whole-frame copy and
        // the mip chain can be skipped and the source texture used directly.
        let sMin = states.map { $0.cameraScale.isFinite ? max(Double($0.cameraScale), 1) : 1 }.min() ?? 1
        let fullLevels = Int(floor(log2(Double(max(r.screen.texture.width, r.screen.texture.height))))) + 1
        let minifAtRest = g.src.x / g.content.z
        let levelsNeeded = minifAtRest <= 1 ? 1 : min(Int(ceil(log2(minifAtRest))) + 1, fullLevels)
        let needMips = levelsNeeded > 1 && (g.src.x / sMin) / g.content.z > 1.0

        guard let bd = backdrop else { sem.signal(); return false }
        let srcTex: MTLTexture? = needMips
            ? screenMip.texture(for: r.screen, levels: levelsNeeded, device: device, cb: cb)
            : r.screen.texture
        guard let srcTex else { sem.signal(); return false }
        var webTex: MTLTexture?
        if tl.webcam != nil, let w = r.webcam {
            let bubbleW = tl.derived == nil
                ? g.canvas.x * (tl.webcam?.size ?? 0.2)
                : (states.map { Double($0.layout.cameraRect.z) * g.canvas.x }.max() ?? 0)
            let webFull = Int(floor(log2(Double(max(w.texture.width, w.texture.height))))) + 1
            let webMinif = Double(w.texture.width) / max(bubbleW, 1)
            let webLevels = webMinif <= 1 ? 1 : min(Int(ceil(log2(webMinif))) + 1, webFull)
            webTex = webMip.texture(for: w, levels: webLevels, device: device, cb: cb)
        }
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
        if tl.style.background == .wallpaper || tl.webcam?.backdrop == .wallpaper { loadWallpaperIfNeeded(quality: r.quality) }
        if tl.style.background == .image { loadStyleImageIfNeeded(tl.style.backgroundImagePath, quality: r.quality) }
        if tl.webcam?.backdrop == .image { loadCameraBackgroundIfNeeded(tl.webcam?.backdropImagePath, quality: r.quality) }
        // SMOOTHNESS: one lock snapshot per frame; the decode tasks publish into
        // this same struct, so the render thread never blocks on disk or AppKit.
        let a = assets.withLock { $0 }
        let animatedBackground = tl.style.background == .dither || tl.style.background == .canvas
        let backgroundTime = animatedBackground ? (r.quality == .export ? t : (r.uiTime.isFinite ? r.uiTime : 0)) * (tl.style.background == .canvas ? tl.style.canvasSpeed : 1) : 0
        let dither = tl.style.background == .dither
        let pointer = dither && r.quality == .preview ? r.pointer : .zero
        let hasLayout = r.live == nil && tl.derived?.layout.samples.isEmpty == false && tl.clipSource(atOutput: t) == nil
        let layout = hasLayout ? states[states.count / 2].layout : nil
        let shadowRect = layout.map { g.positioned(in: $0, contentScale: tl.style.contentScale).content } ?? g.content
        let shadowOpacity = Float(tl.style.shadow) * (layout.map { min(max($0.screenOpacity, 0), 1) } ?? 1)
        let key = BackdropKey(style: tl.style, size: cs,
                              wall: tl.style.background == .wallpaper ? a.wallID : (tl.style.background == .image ? a.styleImageID : ""),
                              phase: backgroundTime, pointer: pointer,
                              shadowRect: shadowOpacity > 0 ? shadowRect : .zero, shadowOpacity: shadowOpacity)
        let needsBackdrop = !r.transparent && !r.cursorOnly
        if needsBackdrop && backdropKey != key {
            backdropKey = key
            let pd = MTLRenderPassDescriptor()
            pd.colorAttachments[0].texture = bd; pd.colorAttachments[0].loadAction = .dontCare; pd.colorAttachments[0].storeAction = .store
            if let e = cb.makeRenderCommandEncoder(descriptor: pd) {
                e.setRenderPipelineState(pBackdrop)
                quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
                let st = tl.style
                let canvasPreset = CanvasPresets.all.first { $0.id == st.canvasPresetID }
                let colorCount = max(min(st.colors.count, 6), 1)
                var cols = st.colors.prefix(6).map(\.simd)
                if cols.isEmpty { cols = [SIMD4<Float>(0, 0, 0, 1)] }
                if cols.count < 6 { cols += [SIMD4<Float>](repeating: cols[0], count: 6 - cols.count) }
                let meshPoints = canvasPreset?.points ?? CanvasPreset.defaultPoints
                for index in 0..<6 {
                    let point = meshPoints[index % meshPoints.count]
                    cols.append(SIMD4<Float>(Float(point.x), Float(point.y), 0, 0))
                }
                let kind: Int32 = switch st.background {
                case .gradient: 0
                case .mesh: 1
                case .dither: 3
                case .wallpaper: 4
                case .canvas: 5
                case .solid: 2
                case .image: 8
                }
                // AGENT: the Studio preset selects the shader family persisted in Style.
                let canvasStyle: Int32 = switch canvasPreset?.style ?? .mesh {
                case .mesh: 0
                case .fluid: 1
                case .waves: 2
                case .orbs: 3
                case .linear: 4
                case .radial: 5
                case .conic: 6
                }
                let hasStyleImage = st.background == .image && a.styleImage != nil
                if st.background == .wallpaper, let wallTex = a.wall?.tex { e.setFragmentTexture(wallTex, index: 0) }
                if hasStyleImage, let styleImage = a.styleImage?.tex { e.setFragmentTexture(styleImage, index: 0) }
                frag(e, BackdropU(content: SIMD4<Float>(shadowRect), canvas: canvasF, angle: Float(st.gradientAngle * .pi / 180),
                                  count: Int32(colorCount), kind: kind, canvasStyle: canvasStyle,
                                  radius: Float(g.radius), shadow: shadowOpacity, scale: Float(g.ui * 1.33),
                                  cell: Float(max(2, st.ditherCell * g.ui)), density: Float(st.ditherDensity),
                                  hasWall: (st.background == .wallpaper && a.wall != nil) || hasStyleImage ? 1 : 0,
                                  time: Float(backgroundTime), pointer: pointer,
                                  wallBlur: Float(st.wallpaperBlur), imgAlpha: Float(st.imageOpacity),
                                  imgContrast: Float(st.imageContrast), imgBright: Float(st.imageBrightness),
                                  saturation: st.ditherSaturation ? 1 : 0,
                                  canvasCenter: SIMD2<Float>(Float(canvasPreset?.center.x ?? 0.5), Float(canvasPreset?.center.y ?? 0.5)),
                                  canvasGround: (canvasPreset?.groundColor ?? st.colors.first ?? RGBA(0x000000)).simd))
                cols.withUnsafeBytes { e.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
                e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                e.endEncoding()
            }

        }

        // 2. sub-frames (motion blur): scene over transparent, accumulated, resolved over the backdrop
        for i in 0..<K {
            let st = states[i]
            guard let protectedSource = maskedSource(srcTex, sourceID: r.screen.id, masks: st.emphasis.masks,
                                                       pixelSize: Float(tl.overlays.privacy.pixelSize),
                                                       levels: levelsNeeded, slot: s, cb: cb) else {
                sem.signal(); return false
            }
            let frameGeometry = hasLayout ? g.positioned(in: st.layout, contentScale: tl.style.contentScale) : g
            let screenOpacity = hasLayout ? min(max(st.layout.screenOpacity, 0), 1) : 1
            scene(cb, into: work[s], slot: s, st: st, r: r, g: frameGeometry, screenOpacity: screenOpacity,
                  subframes: K, src: protectedSource, web: webTex, matte: matte)
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

        // 2b. clip-join crossfade. Blend the held outgoing scene with this
        // frame's incoming scene BEFORE the backdrop resolve, so both sides are
        // composited once and the dissolve is a real two-sided mix, not a fade
        // to black. `effectiveCrossfade` is the project-wide usable window.
        let currentScene = K > 1 ? accum[s] : work[s]
        var sceneForResolve = currentScene
        let joinWeight = crossfadeWeight(tl, t)
        let frameInterval = 1 / max(r.fps, 1)
        let approachingJoin = joinWeight == nil && crossfadeWeight(tl, t + frameInterval * 1.5) != nil
        if !r.transparent, !r.cursorOnly, (approachingJoin || joinWeight != nil),
           let (prev, mix) = crossfadeTargets(cs) {
            let sequential = fadeValid && t > fadeTime && t - fadeTime <= frameInterval * 1.5
            if sequential, let w = joinWeight, w < 1 {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = mix
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                rp.colorAttachments[0].storeAction = .store
                if let e = cb.makeRenderCommandEncoder(descriptor: rp) {
                    e.setRenderPipelineState(pAccum); quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
                    frag(e, AccU(weight: 1 - w)); e.setFragmentTexture(prev, index: 0)
                    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    frag(e, AccU(weight: w)); e.setFragmentTexture(currentScene, index: 0)
                    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    e.endEncoding()
                    sceneForResolve = mix
                }
            }
            if approachingJoin {
                fadeValid = false
                let hp = MTLRenderPassDescriptor()
                hp.colorAttachments[0].texture = prev
                hp.colorAttachments[0].loadAction = .clear
                hp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                hp.colorAttachments[0].storeAction = .store
                if let e = cb.makeRenderCommandEncoder(descriptor: hp) {
                    e.setRenderPipelineState(pTextSprite); quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
                    frag(e, TextSpriteU(opacity: 1)); e.setFragmentTexture(currentScene, index: 0)
                    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    e.endEncoding()
                    fadeValid = true
                }
            } else if !sequential {
                fadeValid = false
            }
            fadeTime = t
        } else {
            fadeValid = false
        }

        // 3. resolve
        let fmt = output.pixelFormat
        if pResolve[fmt] == nil { pResolve[fmt] = try? Self.pipe(device, lib, "resolveFS", fmt, 0) }
        guard let pr = pResolve[fmt] else { sem.signal(); return false }
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = output; pd.colorAttachments[0].loadAction = .dontCare; pd.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: pd) {
            e.setRenderPipelineState(pr); quad(e, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
            frag(e, ResU(levels: fmt == .bgr10a2Unorm ? 1023 : 255,
                         seed: UInt32(truncatingIfNeeded: Int(min(max(t * 1000, 0), 1e9))),
                         alpha: r.transparent || r.cursorOnly ? 0 : 1))
            e.setFragmentTexture(sceneForResolve, index: 0); e.setFragmentTexture(bd, index: 1)
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

    /// Peak camera travel, in canvas pixels, between two evaluated states.
    /// Shared by the sample-count decision so it measures exactly the states
    /// `encode` will draw, not a different time window.
    private func travelPx(_ a: FrameState, _ b: FrameState, _ r: RenderRequest, _ g: Geometry) -> Double {
        let tl = r.timeline
        let k = g.content.z / g.src.x, sc = b.cameraScale.isFinite ? max(Double(b.cameraScale), 1) : 1
        let cam = Double(simd_length(b.cameraCenter - a.cameraCenter)) * k * sc
        let zb = b.cameraScale.isFinite ? max(Double(b.cameraScale), 1) : 1
        let za = a.cameraScale.isFinite ? max(Double(a.cameraScale), 1) : 1
        let zoom = abs(log(zb / za)) * g.content.z * 0.5
        let cur = Double(simd_length(b.cursor.position - a.cursor.position)) * k * sc
        // Tilt is a moving camera too: a Lean/Float/Reveal change needs the
        // same 180-degree shutter as pan/zoom/cursor. ~0.4% of frame width per
        // degree matches the bounded homography at its 8 degree limit.
        let tiltA = CameraTilt.effective(a.cameraTilt, mode: tl.camera.tilt, maxYaw: tl.camera.maxYaw,
                                         maxPitch: tl.camera.maxPitch)
        let tiltB = CameraTilt.effective(b.cameraTilt, mode: tl.camera.tilt, maxYaw: tl.camera.maxYaw,
                                         maxPitch: tl.camera.maxPitch)
        let tiltDelta = max(abs(Double(tiltB.x - tiltA.x)), abs(Double(tiltB.y - tiltA.y)))
        return max(cam, zoom, cur, tiltDelta * g.content.z * 0.004)
    }

    /// Adaptive shutter sampling; preview stays sharp below a three-pixel streak.
    /// Internal (not private) so tests can prove sub-frame accumulation.
    func sampleCount(_ r: RenderRequest, _ g: Geometry) -> Int {
        let tl = r.timeline
        guard tl.camera.shutter > 0, tl.derived != nil, r.fps > 0 else { return 1 }
        let t = r.t.isFinite ? r.t : 0
        // A live FrameState is sampled and held: `encode` uses the SAME state
        // for every sub-frame. There is no intra-frame camera motion to blur,
        // so accumulating sub-frames only wastes GPU time and can dither the
        // result. This is the Studio preview path — a static surface must
        // never smear there.
        if r.live != nil {
            if r.quality == .preview { blurK = 1; blurCooldown = 0 }
            return 1
        }
        // Evaluate the exact window `encode` renders (sub-frames are spread
        // over +/- shutter/2 * dt), so the estimate cannot disagree with the
        // pixels that are actually drawn.
        let dt = 1 / r.fps, half = 0.5 * tl.camera.shutter * dt
        let a = tl.evaluate(at: t - half), b = tl.evaluate(at: t + half)
        // `half` already spans the shutter duration; do not scale by shutter
        // again or a fast zoom is over-blurred into a long smear.
        let blurPx = travelPx(a, b, r, g)
        guard blurPx.isFinite else {
            if r.quality == .preview { blurK = 1; blurCooldown = 0 }
            return 1
        }
        // ZERO extra sub-frames for a still (or sub-pixel) camera, in export
        // as well as preview. A sub-pixel streak is not visible and averaging
        // identical samples cannot add information — it only risks a
        // double-image ghost on a static surface.
        let stillThreshold = r.quality == .preview ? 3.0 : 1.0
        if blurPx < stillThreshold {
            if r.quality == .preview { blurK = 1; blurCooldown = 0 }
            return 1
        }
        let n = Int(ceil(blurPx))
        var cap = max(1, tl.camera.maxSamples)     // a corrupted maxSamples must never mean "render nothing"
        if r.quality == .preview {
            // P2: live playback must never stall. A fast click zoom can drive
            // the travel-based `n` to the default maxSamples of 12, i.e. 12
            // full render passes in one frame — measured at 85-100 ms. Cap
            // preview motion blur at 2 sub-frames so the 60 fps gate holds;
            // export still uses the full requested sample count.
            let per = perSample.withLock { $0 }
            let budget = per > 0 ? min(max(Int(0.5 / max(r.fps, 1) / per), 1), 2) : 1
            cap = min(max(1, budget), 2)
        }
        let want = min(max(n, 1), max(cap, 1))
        guard r.quality == .preview else { return want }        // export: pure function of the request
        // SMOOTHNESS: sticky sample count. K flipping 1↔2↔3 on consecutive
        // frames changes the ghost structure of the blur and the GPU cost in
        // lockstep. Rise at once, fall one step every 8 frames.
        if want >= blurK { blurK = want; blurCooldown = 0 }
        else {
            blurCooldown += 1
            if blurCooldown >= 8 { blurK -= 1; blurCooldown = 0 }
        }
        return min(blurK, cap)
    }

    private func scene(_ cb: MTLCommandBuffer, into tex: MTLTexture, slot: Int, st: FrameState, r: RenderRequest, g: Geometry,
                       screenOpacity: Float, subframes: Int, src: MTLTexture, web: MTLTexture?, matte: PersonMatteSequence.Pair?) {
        let tl = r.timeline
        let canvasF = SIMD2<Float>(Float(g.canvas.x), Float(g.canvas.y)), content = SIMD4<Float>(g.content)
        let tiltMode = tl.camera.tilt
        let tilt = CameraTilt.effective(st.cameraTilt, mode: tiltMode,
                                        maxYaw: tl.camera.maxYaw,
                                        maxPitch: tl.camera.maxPitch)
        let sc = st.cameraScale.isFinite ? max(Double(st.cameraScale), 1) : 1
        // The camera NEVER scales the content rect. Reveal's 0.92 entrance
        // shrink was removed on purpose: it was the reported "Zoom shrinks"
        // defect (Docs/REBUILD-FORENSICS.md 3.3). The reveal entrance now lives
        // entirely in the tilt track (yaw 12 -> 0 over 0.9 s), which this shader
        // applies through the same homography as Lean. No mode applies a hidden
        // content-scale shrink; preview, sub-frames and export stay identical.
        let contentRect = content
        // Browser-content crop: the dense AXWebArea track is authoritative; a
        // legacy Area crop is the fallback, then the full source. The Director
        // already reconstructs a camera centre feasible for ITS view; the
        // renderer must guarantee the view IT draws stays inside the crop, so
        // every state (live and derived) passes through one containment clamp.
        let cropSrc: PxRect = st.crop.isValid
            ? st.crop
            : (st.cropRect.width > 1 && st.cropRect.height > 1
                ? PxRect(x: Double(st.cropRect.minX), y: Double(st.cropRect.minY),
                         w: Double(st.cropRect.width), h: Double(st.cropRect.height))
                : PxRect(x: 0, y: 0, w: g.src.x, h: g.src.y))
        let cropBounds = CGRect(x: cropSrc.x, y: cropSrc.y, width: cropSrc.w, height: cropSrc.h)
        // Invariant: the sampled source view has the SAME aspect as the drawn
        // content rect (source aspect by construction, never the canvas
        // aspect), so a zoom is a true magnification in both dimensions — not
        // a stretch, squash or crop of the frame.
        let drawAspect = g.content.w > 1 ? g.content.z / g.content.w : 1
        let cam = Geometry.containedCenter(SIMD2<Double>(Double(st.cameraCenter.x), Double(st.cameraCenter.y)),
                                           crop: cropSrc, aspect: drawAspect, scale: sc)
        // contentFS maps view = cropSize / scale. The base view is the zero-zoom
        // view: the largest rect of the drawn rect's aspect inside the crop.
        // Dividing by the scale keeps the aspect, so the sampled view is a true
        // sub-rect of the source at 1:1 aspect — never a resampling axis swap.
        let baseView = CropSpace.baseView(crop: cropSrc, aspect: drawAspect)
        let cropSize = SIMD2<Float>(Float(max(baseView.w, 1)), Float(max(baseView.h, 1)))
        let pxPerSrc = g.content.z / g.src.x
        let drawingContent = !r.cursorOnly
        // Direct source sampling: never allocate or dispatch the legacy upscale chain per frame.
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].texture = tex; pd.colorAttachments[0].loadAction = .clear; pd.colorAttachments[0].storeAction = .store
        pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let e = cb.makeRenderCommandEncoder(descriptor: pd) else { return }
        // After a scene copy the encoder is reopened; `enc` is the live one.
        var enc = e
        func draw() { enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4) }

        // Content uses the original masked source, with no intermediate upscale.
        if drawingContent, screenOpacity > 0.001 {
            enc.setRenderPipelineState(pContent); quad(enc, contentRect, canvasF)
            frag(enc, ContentU(content: contentRect, src: SIMD2<Float>(g.src), cam: SIMD2<Float>(cam),
                             cropSize: cropSize, scale: Float(sc),
                             radius: Float(g.radius), border: tl.style.innerBorder ? 1 : 0,
                             tilt: tilt, radii: SIMD4<Float>(g.radii),
                             upRegion: .zero, upTexSize: .one,
                             upFactor: 1, upBlend: 0, opacity: screenOpacity))
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentTexture(src, index: 1)
            draw()
        }

        // Highlight geometry follows the exact source-pixel camera transform.
        // Dimmer is drawn AFTER privacy redaction and never resamples raw pixels.
        if drawingContent, screenOpacity > 0.001, !st.emphasis.highlights.isEmpty {
            enc.setRenderPipelineState(pHighlight)
            for mark in st.emphasis.highlights where mark.opacity > 0.001 {
                let start = g.toCanvas(SIMD2(Double(mark.rect.x), Double(mark.rect.y)), cam: cam, scale: sc, crop: cropBounds, tilt: tilt)
                let end = g.toCanvas(SIMD2(Double(mark.rect.x + mark.rect.z),
                                            Double(mark.rect.y + mark.rect.w)), cam: cam, scale: sc, crop: cropBounds, tilt: tilt)
                let bounds = SIMD4<Float>(Float(min(start.x, end.x)), Float(min(start.y, end.y)),
                                           Float(abs(end.x - start.x)), Float(abs(end.y - start.y)))
                let mode: Int32 = switch mark.style {
                case .dim: 0
                case .outline: 1
                case .glow: 2
                }
                quad(enc, SIMD4(0, 0, canvasF.x, canvasF.y), canvasF)
                frag(enc, HighlightU(rect: bounds, content: content, opacity: mark.opacity * screenOpacity,
                                    strength: mark.dim, mode: mode))
                draw()
            }
        }

        // Glass loupes: a magnified window over the source. Drawn before the
        // cursor so the pointer stays visible above the glass.
        if drawingContent, screenOpacity > 0.001, !st.emphasis.loupes.isEmpty {
            enc.setRenderPipelineState(pLoupe)
            let sourceSize = SIMD2<Float>(Float(g.src.x), Float(g.src.y))
            for glass in st.emphasis.loupes where glass.opacity > 0.001 {
                // A loupe magnifies RAW source pixels — skip it where an
                // active mask covers its target, or it would re-expose them.
                let coveredByMask = st.emphasis.masks.contains { m in
                    let r = m.rect
                    return r.x < glass.target.x + 16 && r.x + r.z > glass.target.x - 16
                        && r.y < glass.target.y + 16 && r.y + r.w > glass.target.y - 16
                }
                if coveredByMask { continue }
                let R = Float(max(glass.radius, 0.02)) * canvasF.x
                let center = SIMD2<Float>(glass.glass.x * canvasF.x, glass.glass.y * canvasF.y)
                quad(enc, SIMD4<Float>(center.x - R * 1.35, center.y - R * 1.35, R * 2.7, R * 2.7), canvasF)
                frag(enc, LoupeU(glass: SIMD4<Float>(center.x, center.y, R, R * glass.border * 2),
                               source: SIMD4<Float>(glass.target.x, glass.target.y, sourceSize.x, sourceSize.y),
                               zoom: SIMD2<Float>(Float(sc), Float(max(glass.magnification, 1))),
                               opacity: glass.opacity * screenOpacity, round: glass.round ? 1 : 0,
                               radius: R * 0.32))
                enc.setFragmentTexture(src, index: 0)
                draw()
            }
        }

        // Click ripple. It must refract the composited frame, not the raw
        // source: the raw texture still contains masked pixels, so sampling it
        // would displace a secret out from under its mosaic. Copy the scene
        // once per frame (only while a click is on screen) and sample that.
        if screenOpacity > 0.001, tl.cursor.clickRing != nil, !st.clickFX.isEmpty {
            let ringSize = min(max(tl.cursor.clickSize, 0.5), 2.0)
            let R = 70 * g.ui * pow(sc, 0.5) * ringSize
            // A ring at exactly 0 or 1 carries no motion: at 0 it would pop at
            // full strength, at 1 it would leave a hard edge. Both are skipped
            // so the wave always starts and ends on nothing.
            let live = st.clickFX.filter { $0.progress > 0 && $0.progress < 1 }
            let centers = live.map { g.toCanvas(SIMD2(Double($0.position.x), Double($0.position.y)), cam: cam, scale: sc, crop: cropBounds, tilt: tilt) }
            var ringSource: MTLTexture?
            // SMOOTHNESS: copy only the union of the ring quads (plus the wave's
            // displacement), not the whole canvas, once per frame.
            if tl.cursor.clickEffect != .none, !live.isEmpty, let cap = sceneCopyTexture(slot: slot, canvas: r.canvas) {
                let pad = 20.0
                var x0 = Double.greatestFiniteMagnitude, y0 = x0
                var x1 = -Double.greatestFiniteMagnitude, y1 = x1
                for c in centers {
                    x0 = min(x0, c.x - R - pad); y0 = min(y0, c.y - R - pad)
                    x1 = max(x1, c.x + R + pad); y1 = max(y1, c.y + R + pad)
                }
                let cx0 = max(Int(x0.rounded(.down)), 0), cy0 = max(Int(y0.rounded(.down)), 0)
                let cx1 = min(Int(x1.rounded(.up)), tex.width), cy1 = min(Int(y1.rounded(.up)), tex.height)
                if cx1 > cx0, cy1 > cy0 {
                    enc.endEncoding()
                    if let blit = cb.makeBlitCommandEncoder() {
                        // The region is copied to the SAME coordinates, so the
                        // shader keeps sampling the scene in canvas pixels.
                        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                                  sourceOrigin: MTLOrigin(x: cx0, y: cy0, z: 0),
                                  sourceSize: MTLSize(width: cx1 - cx0, height: cy1 - cy0, depth: 1),
                                  to: cap, destinationSlice: 0, destinationLevel: 0,
                                  destinationOrigin: MTLOrigin(x: cx0, y: cy0, z: 0))
                        blit.endEncoding()
                    }
                    let rp = MTLRenderPassDescriptor()
                    rp.colorAttachments[0].texture = tex
                    rp.colorAttachments[0].loadAction = .load
                    rp.colorAttachments[0].storeAction = .store
                    if let reopened = cb.makeRenderCommandEncoder(descriptor: rp) {
                        enc = reopened; ringSource = cap
                    }
                }
            }
            enc.setRenderPipelineState(pRing)
            let ringAlpha = Float(min(max(tl.cursor.clickIntensity, 0), 1.5)) * screenOpacity
            let ringColor = SIMD4<Float>(tl.cursor.clickColor.r, tl.cursor.clickColor.g, tl.cursor.clickColor.b, tl.cursor.clickColor.a * ringAlpha)
            let mode: Int32 = switch tl.cursor.clickEffect {
            case .none, .ripple: 0
            case .pulse: 1
            case .burst: 2
            case .glass: 3
            }
            for (i, ring) in live.enumerated() {
                let c = centers[i]
                quad(enc, SIMD4<Float>(Float(c.x - R), Float(c.y - R), Float(2 * R), Float(2 * R)), canvasF)
                frag(enc, RingU(content: content, color: ringColor, center: SIMD2<Float>(c), radius: Float(R),
                              progress: ring.progress, fade: ClickEnvelope.amplitude(Double(ring.progress)), cr: Float(g.radius), mode: mode,
                              cam: SIMD2<Float>(cam), scale: Float(sc),
                              srcSize: ringSource != nil ? canvasF : SIMD2<Float>(g.src)))
                enc.setFragmentTexture(ringSource ?? src, index: 0)
                draw()
            }
        }

        // cursor. Opacity fades at the crop edge so the pointer never leaves
        // the visible frame while browser chrome is hidden.
        let cs = st.cursor
        let cropFade = CropSpace.cursorVisibility(x: Double(cs.position.x), y: Double(cs.position.y), crop: cropSrc)
        let cursorOpacity = Float(min(max(Double(cs.opacity) * cropFade, 0), 1)) * screenOpacity
        if cursorOpacity > 0.01, let atlas, let ent = atlas.entry(cs.shape) {
            let S = 32 * r.backingScale * tl.cursor.size * pxPerSrc * pow(sc, 1 - tl.cursor.effectiveCompensation) * Double(cs.press)
            let c = g.toCanvas(SIMD2<Double>(Double(cs.position.x), Double(cs.position.y)), cam: cam, scale: sc, crop: cropBounds, tilt: tilt)
            enc.setRenderPipelineState(pCursor)
            quad(enc, SIMD4<Float>(Float(c.x - ent.hot.x * S), Float(c.y - ent.hot.y * S), Float(S), Float(S)), canvasF)
            frag(enc, CursorU(content: content, radius: Float(g.radius), opacity: cursorOpacity, layer: UInt32(ent.layer), p: 0))
            enc.setFragmentTexture(atlas.texture, index: 0); draw()
        }

        // Webcam placement is solved by the Director at output time. Never
        // replace its animated position with a hard-coded corner.
        if drawingContent, let wl = tl.webcam, let web {
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
                // SMOOTHNESS: snapshot the decoded assets once for this webcam block.
                let assetsNow = assets.withLock { $0 }
                var maskMode: Float = switch wl.backdrop {
                case .original: cutout ? 1 : 0
                case .transparent: 1
                case .wallpaper: assetsNow.wall == nil ? 3 : 2
                case .canvas: 3
                case .image: assetsNow.cameraBackground == nil ? 3 : 2
                }
                if matte == nil { maskMode = 0 } // Never simulate a missing AI mask.
                let color = tl.style.colors.first?.simd ?? SIMD4<Float>(0.1, 0.1, 0.1, 1)
                let detail: Float = wl.enhancement == .crisp ? Float(min(max(wl.detailAmount, 0), 1)) : 0
                enc.setRenderPipelineState(pWeb)
                quad(enc, SIMD4<Float>(Float(x - margin), Float(y - margin),
                                    Float(width + 2 * margin), Float(height + 2 * margin)), canvasF)
                frag(enc, WebU(crop: crop, bubble: region, radius: Float(min(width, height) * Double(st.layout.cameraRadius)),
                             shape: st.layout.cameraRadius > 0.4 ? 0 : 1, mirror: settings.mirror ? 1 : 0,
                             border: settings.border && maskMode == 0 ? 1 : 0,
                             shadow: settings.shadow && maskMode == 0 ? 1 : 0,
                             bw: Float(3 * g.ui), minif: Float(Double(crop.z) * ww / max(width, 1)),
                             margin: Float(margin), opacity: opacity, maskMode: maskMode,
                             matteMix: matte?.fraction ?? 0, detail: detail, canvasColor: color))
                enc.setFragmentTexture(web, index: 0)
                if let matte {
                    enc.setFragmentTexture(matte.previous, index: 1)
                    enc.setFragmentTexture(matte.next, index: 2)
                }
                if maskMode == 2 {
                    let background = wl.backdrop == .image ? assetsNow.cameraBackground?.tex : assetsNow.wall?.tex
                    if let background { enc.setFragmentTexture(background, index: 3) }
                }
                draw()
            }
        }

        // Caption and manual text share this pass in both live preview and offline exports.
        // Both are source-time anchored; rasterization is cached by actual text/style,
        // with a different cache entry only when the highlighted word changes.
        var sprites: [TextOverlaySprite] = []
        if drawingContent, let caption = st.caption, tl.captions.enabled,
           let sprite = textCache.caption(caption, style: tl.captions.style,
                                          time: r.t, canvas: r.canvas, videoRect: g.content, device: device) {
            sprites.append(sprite)
        }
        if drawingContent {
            for manual in st.emphasis.texts {
                if let sprite = textCache.manual(manual, canvas: r.canvas, device: device) {
                    sprites.append(sprite)
                }
            }
        }
        if !sprites.isEmpty {
            // A caption card needs the scene behind it, and Metal cannot read
            // the texture it is writing. Copy the finished scene once (only
            // when a card is visible), blur it with a separable Gaussian at
            // quarter resolution, then reopen the pass for card + sharp text.
            // Export and preview share this path.
            let cards = sprites.filter { $0.card != nil && $0.opacity > 0.001 }
            var cardTexture: MTLTexture?
            var encoder = enc
            if let tallest = cards.map({ Float($0.texture.height) * $0.scale }).max() {
                // The blur reads the finished scene directly. It only needs the
                // pass ended first; no full-resolution copy is required because
                // the blur writes to a different (quarter-resolution) target.
                enc.endEncoding()
                // Thin material: a soft frost, not a fog. Tuned by eye against
                // busy pages; the card's tint carries the contrast, not the blur.
                // The caption's blur-in radius rides on top, so the whole block
                // (material included) resolves out of focus.
                let blurIn = cards.map(\.blur).max() ?? 0
                let sigma = min(max(tallest * 0.12 + blurIn, 8), 40)
                cardTexture = blurScene(cb, from: tex, slot: slot, canvas: r.canvas, sigma: sigma)
                let pd = MTLRenderPassDescriptor()
                pd.colorAttachments[0].texture = tex
                pd.colorAttachments[0].loadAction = .load
                pd.colorAttachments[0].storeAction = .store
                guard let reopened = cb.makeRenderCommandEncoder(descriptor: pd) else { return }
                encoder = reopened
            }
            if let cardTexture {
                encoder.setRenderPipelineState(pCaptionCard)
                for sprite in cards {
                    guard let card = sprite.card else { continue }
                    let w = Float(sprite.texture.width) * sprite.scale
                    let h = Float(sprite.texture.height) * sprite.scale
                    let rect = SIMD4<Float>(sprite.center.x - w / 2, sprite.center.y - h / 2, w, h)
                    quad(encoder, rect, canvasF)
                    frag(encoder, CaptionCardU(rect: rect, tint: card.tint, canvas: canvasF,
                                               radius: card.radius * sprite.scale, opacity: sprite.opacity))
                    encoder.setFragmentTexture(cardTexture, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            encoder.setRenderPipelineState(pTextSprite)
            for sprite in sprites where sprite.opacity > 0.001 {
                let w = Float(sprite.texture.width) * sprite.scale
                let h = Float(sprite.texture.height) * sprite.scale
                quad(encoder, SIMD4<Float>(sprite.center.x - w / 2, sprite.center.y - h / 2, w, h), canvasF)
                frag(encoder, TextSpriteU(opacity: sprite.opacity, blur: sprite.blur))
                encoder.setFragmentTexture(sprite.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.endEncoding()
        } else {
            enc.endEncoding()
        }
    }

    private func maskedSource(_ source: MTLTexture, sourceID: UInt64, masks: [MaskFrame], pixelSize: Float,
                              levels: Int, slot: Int, cb: MTLCommandBuffer) -> MTLTexture? {
        guard !masks.isEmpty else { return source }
        guard masks.count <= 128 else { return nil }
        if maskedSources[slot]?.width != source.width || maskedSources[slot]?.height != source.height
            || maskedSources[slot]?.mipmapLevelCount != levels {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: source.width, height: source.height, mipmapped: levels > 1)
            descriptor.mipmapLevelCount = levels
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]; descriptor.storageMode = .private
            maskedSources[slot] = device.makeTexture(descriptor: descriptor)
            maskKey[slot] = nil
        }
        guard let target = maskedSources[slot] else { return nil }
        // SMOOTHNESS: identical source + identical masks ⇒ zero GPU work.
        // The mask pass used to run over the whole frame for every motion-blur
        // sub-frame, even when nothing about it had changed.
        var hasher = Hasher()
        hasher.combine(sourceID); hasher.combine(pixelSize)
        for mask in masks {
            hasher.combine(mask.rect.x); hasher.combine(mask.rect.y)
            hasher.combine(mask.rect.z); hasher.combine(mask.rect.w); hasher.combine(mask.mode)
        }
        let key = UInt64(bitPattern: Int64(hasher.finalize()))
        if maskKey[slot] == key { return target }
        maskKey[slot] = key
        // 1. pure bandwidth copy: the frame outside every mask is unchanged.
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                      to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        // 2. ALU only inside each mask rectangle (plus the blur rim).
        guard let encoder = cb.makeComputeCommandEncoder() else { return nil }
        let regions = masks.prefix(128).map { mask -> SourceMaskGPU in
            let height = mask.rect.w
            let cell = pixelSize > 0 ? pixelSize : PrivacyMaskGeometry.cell(boxHeight: height)
            let mode: Float = switch mask.mode { case .pixelate: 0; case .solid: 1; case .blur: 2 }
            let rect = mask.mode == .pixelate ? PrivacyMaskGeometry.mosaicRegion(mask.rect, cell: cell) : mask.rect
            return SourceMaskGPU(rect: rect, block: SIMD4(cell, mode, height * 0.22, 0))
        }
        var count = UInt32(regions.count)
        encoder.setComputePipelineState(pSourceMask)
        encoder.setTexture(source, index: 0); encoder.setTexture(target, index: 1)
        regions.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        for region in regions {
            let pad: Float = region.block.y > 1.5 ? 10 : 0
            let x0 = max(Int((region.rect.x - pad).rounded(.down)), 0)
            let y0 = max(Int((region.rect.y - pad).rounded(.down)), 0)
            let x1 = min(Int((region.rect.x + region.rect.z + pad).rounded(.up)), source.width)
            let y1 = min(Int((region.rect.y + region.rect.w + pad).rounded(.up)), source.height)
            guard x1 > x0, y1 > y0 else { continue }
            var origin = SIMD2<UInt32>(UInt32(x0), UInt32(y0))
            encoder.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.size, index: 2)
            encoder.dispatchThreads(MTLSize(width: x1 - x0, height: y1 - y0, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        encoder.endEncoding()
        if levels > 1, let blit = cb.makeBlitCommandEncoder() { blit.generateMipmaps(for: target); blit.endEncoding() }
        return target
    }

    /// Separable Gaussian of the finished scene, rendered at quarter resolution.
    /// Two passes (horizontal then vertical); returns the blurred texture, or
    /// nil when the targets cannot be allocated. `sigma` is in canvas pixels.
    private func blurScene(_ cb: MTLCommandBuffer, from source: MTLTexture, slot: Int,
                           canvas: SIMD2<Int>, sigma: Float) -> MTLTexture? {
        guard let a = blurTarget(0, slot: slot, canvas: canvas),
              let b = blurTarget(1, slot: slot, canvas: canvas) else { return nil }
        let quarter = SIMD2<Float>(Float(a.width), Float(a.height))
        let pd = MTLRenderPassDescriptor()
        pd.colorAttachments[0].loadAction = .clear
        pd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pd.colorAttachments[0].storeAction = .store
        for (target, input, dir) in [(a, source, SIMD2<Float>(1, 0)), (b, a, SIMD2<Float>(0, 1))] {
            pd.colorAttachments[0].texture = target
            guard let e = cb.makeRenderCommandEncoder(descriptor: pd) else { return nil }
            e.setRenderPipelineState(pBlur)
            quad(e, SIMD4<Float>(0, 0, quarter.x, quarter.y), quarter)
            frag(e, BlurU(dir: dir, sigma: max(sigma * 0.25, 0.4), pad0: 0, pad1: 0))
            e.setFragmentTexture(input, index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            e.endEncoding()
        }
        return b
    }

    /// Per-in-flight-slot quarter-resolution target for the caption material.
    /// Lazily allocated: recordings without captions pay nothing.
    private func blurTarget(_ index: Int, slot: Int, canvas: SIMD2<Int>) -> MTLTexture? {
        let i = min(max(slot, 0), 2)
        let w = max(1, canvas.x / 4), h = max(1, canvas.y / 4)
        var list = index == 0 ? blurA : blurB
        if let t = list[i], t.width == w, t.height == h { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        list[i] = device.makeTexture(descriptor: d)
        if index == 0 { blurA = list } else { blurB = list }
        return list[i]
    }

    /// Copy of the composited scene, per in-flight slot. Metal cannot sample
    /// the texture it is writing, so the ripple refracts this copy. The caption
    /// material blurs the scene directly instead (it writes to another target).
    private func sceneCopyTexture(slot: Int, canvas: SIMD2<Int>) -> MTLTexture? {
        let index = min(max(slot, 0), 2)
        if let t = captionSrc[index], t.width == canvas.x, t.height == canvas.y { return t }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: canvas.x, height: canvas.y,
                                                           mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        captionSrc[index] = device.makeTexture(descriptor: d)
        return captionSrc[index]
    }

    /// Lazily allocate the two full-canvas scratch targets a clip-join crossfade
    /// needs: the held outgoing scene and the premultiplied blend of both sides.
    private func crossfadeTargets(_ canvas: SIMD2<Int>) -> (MTLTexture, MTLTexture)? {
        if fadeSize != canvas || fadePrev == nil || fadeMix == nil {
            func make() -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                  width: canvas.x, height: canvas.y,
                                                                  mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            fadePrev = make(); fadeMix = make(); fadeValid = false; fadeSize = canvas
        }
        guard let prev = fadePrev, let mix = fadeMix else { return nil }
        return (prev, mix)
    }

    /// Incoming-clip weight inside a join's effective crossfade window. A join
    /// is an output-adjacent pair of clips; `nil` means no dissolve this frame.
    private func crossfadeWeight(_ tl: Timeline, _ t: Double) -> Float? {
        let xf = tl.effectiveCrossfade
        guard xf > 0, tl.clips.count > 1 else { return nil }
        let sorted = tl.clips.sorted { $0.start < $1.start }
        var weight: Float?
        for i in 1..<sorted.count where abs(sorted[i].start - sorted[i - 1].end) < 0.001 {
            let join = sorted[i].start
            if t >= join - 1e-6, t <= join + xf {
                weight = Float(min(max((t - join) / xf, 0), 1))
            }
        }
        return weight
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
