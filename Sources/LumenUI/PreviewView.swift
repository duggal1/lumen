import SwiftUI
import AppKit
import QuartzCore
import os
import LumenCore
import LumenProject
import LumenRender

private struct Unsafe<T>: @unchecked Sendable { let v: T }

/// One render request. Latest wins: the stream keeps only the newest value,
/// so a slow GPU skips frames by time instead of building a queue.
private struct Tick: Sendable {
    var timeline: Timeline
    var t: Double
    var size: SIMD2<Int>
    var present: Double
    var fps: Double
    var uiTime: Double
    var pointer: SIMD4<Float>
    var backingScale: Double
    var maskDirectory: URL?
}

private struct FrameKey: Equatable {
    var version: Int, t: Double, width: Int, height: Int, phase: Int
    var px: Int, py: Int, pz: Int
}

/// Metal preview. Same Renderer.encode as export. One long-lived render loop;
/// content is evaluated for the vsync AFTER the next one and presented at
/// exactly that time, so every frame has a full vsync of scheduling slack.
struct PreviewView: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> PreviewNSView { PreviewNSView(model: model) }
    func updateNSView(_ v: PreviewNSView, context: Context) {}
}

@MainActor final class PreviewNSView: NSView {
    private let model: EditorModel
    private let metal: CAMetalLayer
    private var link: CADisplayLink?
    private var lastKey = FrameKey(version: -1, t: -1, width: 0, height: 0, phase: 0, px: 0, py: 0, pz: 0)
    private let t0 = CACurrentMediaTime()
    private var pointer = SIMD3<Double>(0.5, 0.5, 0)
    private var pointerTarget = SIMD3<Double>(0.5, 0.5, 0)
    private var lastPointerTime = 0.0
    private var pointerTrackingArea: NSTrackingArea?
    private let feed: AsyncStream<Tick>.Continuation
    private let loop: Task<Void, Never>

    init(model: EditorModel) {
        self.model = model
        let ml = CAMetalLayer(); metal = ml
        let (stream, continuation) = AsyncStream<Tick>.makeStream(bufferingPolicy: .bufferingNewest(1))
        feed = continuation
        let renderer = model.renderer, session = model.session, metalLayer = Unsafe(v: ml)
        loop = Task.detached(priority: .userInitiated) {
            for await tick in stream {
                if Task.isCancelled { break }
                guard let (screen, webcam) = try? await session.frames(atOutput: tick.t, timeline: tick.timeline) else { continue }
                let request = RenderRequest(timeline: tick.timeline, t: tick.t, screen: screen, webcam: webcam,
                                            canvas: tick.size, fps: tick.fps, backingScale: tick.backingScale,
                                            quality: .preview, uiTime: tick.uiTime, pointer: tick.pointer,
                                            personMaskDirectory: tick.maskDirectory)
                var tries = 0
                while !renderer.draw(request, to: metalLayer.v, presentAt: tick.present), tries < 4 {
                    tries += 1
                    try? await Task.sleep(for: .milliseconds(6))
                }
            }
        }
        super.init(frame: .zero)
        wantsLayer = true; layer = ml
        ml.device = renderer.device; ml.pixelFormat = .bgra8Unorm; ml.framebufferOnly = true
        ml.colorspace = CGColorSpace(name: CGColorSpace.displayP3); ml.displaySyncEnabled = true
        ml.maximumDrawableCount = 3
        ml.isOpaque = true
        ml.masksToBounds = true
        ml.cornerRadius = Radius.card
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
        // The export owns the GPU until encoding finishes. The paused editor
        // does not compete for frames or media engine bandwidth.
        if case .running = model.exportState { return }
        let interval = max(l.targetTimestamp - l.timestamp, 1.0 / 240)
        let present = l.targetTimestamp + interval          // the vsync after next
        let now = l.targetTimestamp
        if model.clock.playing { model.tick(model.clock.time(at: now)) }
        let (tl, version) = model.box.get(), ds = metal.drawableSize
        let animated = (tl.style.background == .dither || tl.style.background == .wave || tl.style.background == .field)
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let dt = lastPointerTime > 0 ? min(max(now - lastPointerTime, 0), 0.1) : 0
        lastPointerTime = now
        pointer += (pointerTarget - pointer) * (1 - exp(-dt * 7))
        let t = model.clock.time(at: present)
        let uiTime = animated ? (model.clock.playing ? t : now - t0) : 0
        let phase = animated ? Int(uiTime * 240) : 0
        let key = FrameKey(version: version, t: t, width: Int(ds.width), height: Int(ds.height), phase: phase,
                           px: Int(pointer.x * 1000), py: Int(pointer.y * 1000), pz: Int(pointer.z * 1000))
        guard key != lastKey, ds.width > 2 else { return }
        lastKey = key
        feed.yield(Tick(timeline: tl, t: t, size: SIMD2(Int(ds.width), Int(ds.height)), present: present,
                        fps: 1 / interval, uiTime: uiTime,
                        pointer: animated ? SIMD4(Float(pointer.x), Float(pointer.y), Float(pointer.z), 0) : .zero,
                        backingScale: model.session.meta.source.backingScale,
                        maskDirectory: model.session.bundle.cacheURL.appendingPathComponent("analysis", isDirectory: true)))
    }
    deinit {
        feed.finish()
        loop.cancel()
        // AppKit tears views down on the main thread; the guard keeps a
        // non-main release from trapping in assumeIsolated.
        if Thread.isMainThread { MainActor.assumeIsolated { link?.invalidate() } }
    }
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
