import SwiftUI
import AppKit
import QuartzCore
import os
import LumenCore
import LumenProject
import LumenRender

private struct Unsafe<T>: @unchecked Sendable { let v: T }

/// Metal preview. Same Renderer.encode as export. Driven by the display link's targetTimestamp; renders only when something changed
/// (playhead, edit, resize); skips frames by time when the GPU is behind, never queues them.
struct PreviewView: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView(model: model) }
    func updateNSView(_ v: PreviewNSView, context: Context) {}
}

@MainActor final class PreviewNSView: NSView {
    private let model: EditorModel, metal = CAMetalLayer()
    private var link: CADisplayLink?
    private let busy = OSAllocatedUnfairLock(initialState: false)
    private var lastKey: (Int, Double, Int, Int) = (-1, -1, 0, 0)

    init(model: EditorModel) {
        self.model = model; super.init(frame: .zero)
        wantsLayer = true; layer = metal
        metal.device = model.renderer.device; metal.pixelFormat = .bgra8Unorm; metal.framebufferOnly = true
        metal.colorspace = CGColorSpace(name: CGColorSpace.displayP3); metal.displaySyncEnabled = true; metal.maximumDrawableCount = 3
        metal.isOpaque = true
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
        let t = model.clock.time(at: l.targetTimestamp)
        if model.clock.playing { model.tick(t) }
        let (tl, ver) = model.box.get(), ds = metal.drawableSize
        let key = (ver, t, Int(ds.width), Int(ds.height))
        guard key != lastKey, ds.width > 2, busy.withLock({ let b = $0; $0 = true; return !b }) else { return }
        lastKey = key
        let renderer = model.renderer, session = model.session, layer = Unsafe(v: metal), busy = busy
        Task.detached(priority: .userInitiated) {
            defer { busy.withLock { $0 = false } }
            let s = tl.timeMap.source(atOutput: t)
            guard let sf = try? await session.screen.frame(atSource: s) else { return }
            let wf = tl.webcam != nil ? try? await session.webcam?.frame(atSource: s) : nil
            let req = RenderRequest(timeline: tl, t: t, screen: sf, webcam: wf, canvas: SIMD2(Int(ds.width), Int(ds.height)), fps: 60,
                                    backingScale: session.meta.source.backingScale, quality: .preview)
            renderer.draw(req, to: layer.v)
        }
    }
    deinit { MainActor.assumeIsolated { link?.invalidate() } }
}

/// Drag a rectangle on the preview to frame the selected zoom segment (maps through the live camera back to source coords).
struct FocusOverlay: View {
    let model: EditorModel
    @State private var a: CGPoint?, b: CGPoint?
    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.clear.contentShape(Rectangle())
                if let a, let b {
                    let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    Rectangle().fill(Tok.accentSoft).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                }
            }
            .gesture(DragGesture(minimumDistance: 4).onChanged { v in a = v.startLocation; b = v.location }
                .onEnded { v in
                    defer { a = nil; b = nil; model.focusEditing = false }
                    let tl = model.timeline, st = tl.evaluate(at: model.playhead)
                    guard let d = tl.derived else { return }
                    let size = SIMD2<Int>(Int(g.size.width), Int(g.size.height)), geo = Geometry(canvas: size, src: d.sourceSize, style: tl.style)
                    func toSrc(_ p: CGPoint) -> CGPoint {
                        let view = d.sourceSize / Double(st.cameraScale), cam = SIMD2<Double>(Double(st.cameraCenter.x), Double(st.cameraCenter.y))
                        let n = SIMD2((p.x - geo.content.x) / geo.content.z, (p.y - geo.content.y) / geo.content.w)
                        let s = (cam - view / 2) + n * view
                        return CGPoint(x: min(max(s.x / d.sourceSize.x, 0), 1), y: min(max(s.y / d.sourceSize.y, 0), 1))
                    }
                    let p0 = toSrc(v.startLocation), p1 = toSrc(v.location)
                    model.setFocus(box: CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p0.x - p1.x), height: abs(p0.y - p1.y)))
                })
        }
    }
}