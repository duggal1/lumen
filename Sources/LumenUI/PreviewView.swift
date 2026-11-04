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
    private var lastKey: (Int, Double, Int, Int, Int) = (-1, -1, 0, 0, 0)
    private let t0 = CACurrentMediaTime()
    private var pointer = SIMD3<Double>(0.5, 0.5, 0)
    private var pointerTarget = SIMD3<Double>(0.5, 0.5, 0)
    private var lastPointerTime = 0.0
    private var pointerTrackingArea: NSTrackingArea?

    init(model: EditorModel) {
        self.model = model; super.init(frame: .zero)
        wantsLayer = true; layer = metal
        metal.device = model.renderer.device; metal.pixelFormat = .bgra8Unorm; metal.framebufferOnly = true
        metal.colorspace = CGColorSpace(name: CGColorSpace.displayP3); metal.displaySyncEnabled = true; metal.maximumDrawableCount = 3
        metal.isOpaque = true
        metal.masksToBounds = true
        metal.cornerRadius = Radius.card
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        link?.invalidate(); link = nil
        guard window != nil else { return }
        window?.acceptsMouseMovedEvents = true
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common); link = l
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area); pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { pointerTarget.z = 0 }
    override func mouseMoved(with event: NSEvent) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointerTarget = SIMD3(Double(min(max(point.x / bounds.width, 0), 1)),
                              Double(min(max(1 - point.y / bounds.height, 0), 1)), 1)
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
        // The dither field is a living surface: redraw every display tick. Static backgrounds stay cache-stable.
        let animated = (tl.style.background == .dither || tl.style.background == .wave || tl.style.background == .field)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let dt = lastPointerTime > 0 ? min(max(l.targetTimestamp - lastPointerTime, 0), 0.1) : 0
        lastPointerTime = l.targetTimestamp
        pointer += (pointerTarget - pointer) * (1 - exp(-dt * 7))
        let uiTime = animated ? (model.clock.playing ? t : l.targetTimestamp - t0) : 0
        let phase = animated ? Int(uiTime * 240) : 0
        let key = (ver, t, Int(ds.width), Int(ds.height), phase)
        guard key != lastKey, ds.width > 2, busy.withLock({ let b = $0; $0 = true; return !b }) else { return }
        lastKey = key
        let renderer = model.renderer, session = model.session, layer = Unsafe(v: metal), busy = busy
        let pointerValue = animated ? SIMD4(Float(pointer.x), Float(pointer.y), Float(pointer.z), 0) : .zero
        Task.detached(priority: .userInitiated) {
            defer { busy.withLock { $0 = false } }
            let s = tl.timeMap.source(atOutput: t)
            guard let sf = try? await session.screen.frame(atSource: s) else { return }
            let wf = tl.webcam != nil ? try? await session.webcam?.frame(atSource: s) : nil
            let req = RenderRequest(timeline: tl, t: t, screen: sf, webcam: wf, canvas: SIMD2(Int(ds.width), Int(ds.height)), fps: 60,
                                    backingScale: session.meta.source.backingScale, quality: .preview, uiTime: uiTime,
                                    pointer: pointerValue)
            renderer.draw(req, to: layer.v)
        }
    }
    deinit { MainActor.assumeIsolated { link?.invalidate() } }
}

/// Drag a rectangle on the preview to frame the selected zoom segment (maps through the live camera back to source coords).
struct FocusOverlay: View {
    let model: EditorModel
    @State private var a: CGPoint?
    @State private var b: CGPoint?
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
                    let size = SIMD2<Int>(Int(g.size.width), Int(g.size.height))
                    let transform = ZoomTransform(canvas: size, source: d.sourceSize, style: tl.style,
                                                  cameraCenter: SIMD2<Double>(Double(st.cameraCenter.x), Double(st.cameraCenter.y)),
                                                  scale: Double(st.cameraScale))
                    func toSrc(_ p: CGPoint) -> CGPoint {
                        let s = transform.sourceNormalized(transform.canvasToSource(SIMD2(Double(p.x), Double(p.y))))
                        return CGPoint(x: min(max(s.x, 0), 1), y: min(max(s.y, 0), 1))
                    }
                    let p0 = toSrc(v.startLocation), p1 = toSrc(v.location)
                    model.setFocus(box: CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p0.x - p1.x), height: abs(p0.y - p1.y)))
                })
        }
    }
}
