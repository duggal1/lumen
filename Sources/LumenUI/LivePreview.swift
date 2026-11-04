import AppKit
import QuartzCore
import CoreVideo
import os
import LumenCore
import LumenProject
import LumenDirector
import LumenRender

private struct LayerBox: @unchecked Sendable { let v: CAMetalLayer }

final class LiveHub: @unchecked Sendable {
    let source: LiveFrameSource
    private let cam = OSAllocatedUnfairLock<LiveCamera?>(initialState: nil)
    init(source: LiveFrameSource) { self.source = source }
    func frame(_ pb: CVPixelBuffer) {
        source.submit(pb)
        cam.withLock { if $0 == nil { $0 = LiveCamera(source: SIMD2(Double(CVPixelBufferGetWidth(pb)), Double(CVPixelBufferGetHeight(pb)))) } }
    }
    func event(_ e: InputEvent) { cam.withLock { $0?.ingest(e) } }
    func step(to t: Double) -> FrameState? { cam.withLock { $0?.step(to: t) } }
}

@MainActor final class LivePreviewController {
    let hub: LiveHub
    private var panel: NSPanel?
    init?() {
        guard let r = try? Renderer(), let src = LiveFrameSource(device: r.device) else { return nil }
        r.setCustomCursors([])
        hub = LiveHub(source: src)
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = LivePreviewNSView(renderer: r, hub: hub)
        p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.sharingType = .none; p.hidesOnDeactivate = false; p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let s = NSScreen.main { p.setFrameOrigin(CGPoint(x: s.visibleFrame.maxX - 504, y: s.visibleFrame.minY + 24)) }
        panel = p
    }
    func show() { panel?.orderFrontRegardless() }
    func close() { panel?.orderOut(nil); panel = nil }
}

@MainActor final class LivePreviewNSView: NSView {
    private let renderer: Renderer, hub: LiveHub, metal = CAMetalLayer()
    private let timeline = Timeline(duration: 1)
    private var link: CADisplayLink?
    private let busy = OSAllocatedUnfairLock(initialState: false)
    init(renderer: Renderer, hub: LiveHub) {
        self.renderer = renderer; self.hub = hub; super.init(frame: .zero)
        wantsLayer = true; layer = metal
        metal.device = renderer.device; metal.pixelFormat = .bgra8Unorm; metal.framebufferOnly = true
        metal.colorspace = CGColorSpace(name: CGColorSpace.displayP3); metal.displaySyncEnabled = true; metal.maximumDrawableCount = 3
        metal.isOpaque = false; metal.cornerRadius = 12; metal.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        link?.invalidate(); link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common); link = l
    }
    override func layout() {
        super.layout()
        let s = window?.backingScaleFactor ?? 2
        metal.contentsScale = s
        metal.drawableSize = CGSize(width: max(bounds.width * s, 2).rounded(), height: max(bounds.height * s, 2).rounded())
    }
    @objc private func tick(_ l: CADisplayLink) {
        guard let st = hub.step(to: l.targetTimestamp), let sf = hub.source.current() else { return }
        let ds = metal.drawableSize
        guard ds.width > 2, busy.withLock({ let b = $0; $0 = true; return !b }) else { return }
        let r = renderer, layer = LayerBox(v: metal), busy = busy, tl = timeline, scale = Double(window?.backingScaleFactor ?? 2)
        Task.detached(priority: .userInitiated) {
            defer { busy.withLock { $0 = false } }
            var req = RenderRequest(timeline: tl, t: 0, screen: sf, webcam: nil, canvas: SIMD2(Int(ds.width), Int(ds.height)),
                                    fps: 60, backingScale: scale, quality: .preview)
            req.live = st
            r.draw(req, to: layer.v)
        }
    }
    deinit { MainActor.assumeIsolated { link?.invalidate() } }
}
