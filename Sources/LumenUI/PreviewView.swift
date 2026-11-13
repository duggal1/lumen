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

/// The vsync grid, republished on every display-link callback. The render loop
/// re-picks a present instant from it after decode instead of retry-sleeping.
private final class VsyncClock: @unchecked Sendable {
    private let s = OSAllocatedUnfairLock<(anchor: Double, interval: Double)>(initialState: (0, 1.0 / 60))
    func update(anchor: Double, interval: Double) { s.withLock { $0 = (anchor, interval) } }
    func firstVsync(after t: Double) -> Double {
        let (a, i) = s.withLock { $0 }
        guard a > 0, i > 0 else { return t }
        return a + ((t - a) / i).rounded(.up) * i
    }
}

/// Main thread writes; the display-link thread only reads. Nothing on the hot
/// path touches main-actor state, so a busy main thread cannot starve it.
final class PreviewShared: @unchecked Sendable {
    private struct S {
        var pointerTarget = SIMD3<Double>(0.5, 0.5, 0)
        var drawable = CGSize(width: 2, height: 2)
        var exportRunning = false
        var frozen = false
        var reduceMotion = false
    }
    private let s = OSAllocatedUnfairLock(initialState: S())
    var pointerTarget: SIMD3<Double> { get { s.withLock { $0.pointerTarget } } set { s.withLock { $0.pointerTarget = newValue } } }
    var drawable: CGSize { get { s.withLock { $0.drawable } } set { s.withLock { $0.drawable = newValue } } }
    var exportRunning: Bool { get { s.withLock { $0.exportRunning } } set { s.withLock { $0.exportRunning = newValue } } }
    var frozen: Bool { get { s.withLock { $0.frozen } } set { s.withLock { $0.frozen = newValue } } }
    var reduceMotion: Bool { get { s.withLock { $0.reduceMotion } } set { s.withLock { $0.reduceMotion = newValue } } }
}

/// The display-link target. Deliberately NOT main-actor-isolated: it reads only
/// lock-protected state and Sendable references, so it never competes with
/// SwiftUI layout or @Observable invalidation for the main thread.
private final class PreviewDriver: NSObject, @unchecked Sendable {
    private let shared: PreviewShared
    private let vsync: VsyncClock
    private let clock: PlaybackClock
    private let box: TimelineBox
    private let backingScale: Double
    private let maskDirectory: URL
    private let t0 = CACurrentMediaTime()
    private let feed: AsyncStream<Tick>.Continuation
    // Only the display-link thread touches these.
    private var pointer = SIMD3<Double>(0.5, 0.5, 0)
    private var lastPointerTime = 0.0
    private var lastKey = FrameKey(version: -1, t: -1, width: 0, height: 0, phase: 0, px: 0, py: 0, pz: 0)

    init(shared: PreviewShared, vsync: VsyncClock, clock: PlaybackClock, box: TimelineBox,
         backingScale: Double, maskDirectory: URL, feed: AsyncStream<Tick>.Continuation) {
        self.shared = shared; self.vsync = vsync; self.clock = clock; self.box = box
        self.backingScale = backingScale; self.maskDirectory = maskDirectory; self.feed = feed
        super.init()
    }

    @objc func tick(_ l: CADisplayLink) {
        // The export owns the GPU until encoding finishes. A live resize keeps
        // the last frame stretched; reallocating targets per pixel of drag is
        // what made resizing hitch.
        if shared.exportRunning || shared.frozen { return }
        let interval = max(l.targetTimestamp - l.timestamp, 1.0 / 240)
        vsync.update(anchor: l.targetTimestamp, interval: interval)
        let present = l.targetTimestamp + interval          // the vsync after next
        let now = l.targetTimestamp
        let (tl, version) = box.get()
        let ds = shared.drawable
        let animated = tl.style.background == .dither && !shared.reduceMotion
        let dt = lastPointerTime > 0 ? min(max(now - lastPointerTime, 0), 0.1) : 0
        lastPointerTime = now
        pointer += (shared.pointerTarget - pointer) * (1 - exp(-dt * 7))
        let playing = clock.playing
        let t = clock.time(at: present)
        let uiTime = animated ? (playing ? t : now - t0) : 0
        // SMOOTHNESS: a paused animated backdrop only needs 30 Hz phase; 240 Hz
        // re-renders an otherwise static frame every tick.
        let phase = animated ? Int(uiTime * (playing ? 240 : 30)) : 0
        // SMOOTHNESS: the pointer only reaches the Dither shader,
        // so it must not invalidate the frame key (and re-render) otherwise.
        let dither = animated && tl.style.background == .dither
        let key = FrameKey(version: version, t: t, width: Int(ds.width), height: Int(ds.height), phase: phase,
                           px: dither ? Int(pointer.x * 1000) : 0,
                           py: dither ? Int(pointer.y * 1000) : 0,
                           pz: dither ? Int(pointer.z * 1000) : 0)
        guard key != lastKey, ds.width > 2 else { return }
        lastKey = key
        feed.yield(Tick(timeline: tl, t: t, size: SIMD2(Int(ds.width), Int(ds.height)), present: present,
                        fps: 1 / interval, uiTime: uiTime,
                        pointer: dither ? SIMD4(Float(pointer.x), Float(pointer.y), Float(pointer.z), 0) : .zero,
                        backingScale: backingScale, maskDirectory: maskDirectory))
    }
}

/// Owns the secondary runloop the display link lives on, so the thread exits
/// when the preview view goes away instead of sleeping forever.
private final class LinkRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopped = false
    /// Called on the link thread; returns false if `stop()` already ran.
    func install() -> Bool {
        lock.lock(); defer { lock.unlock() }
        runLoop = CFRunLoopGetCurrent()
        stopped = false
        return true
    }
    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    func stop() {
        lock.lock(); let rl = runLoop; stopped = true; lock.unlock()
        if let rl { CFRunLoopStop(rl) }
    }
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
    private let shared: PreviewShared
    private let vsync: VsyncClock
    private let driver: PreviewDriver
    private let linkRunner = LinkRunner()
    private var link: CADisplayLink?
    private var playheadTimer: Timer?
    private var pointerTrackingArea: NSTrackingArea?
    private let feed: AsyncStream<Tick>.Continuation
    private let loop: Task<Void, Never>

    init(model: EditorModel) {
        self.model = model
        let ml = CAMetalLayer(); metal = ml
        // The shared state is owned by the model: the export flag is written
        // there, the pointer and the drawable size here.
        let sh = model.previewShared, vc = VsyncClock()
        shared = sh; vsync = vc
        let (stream, continuation) = AsyncStream<Tick>.makeStream(bufferingPolicy: .bufferingNewest(1))
        feed = continuation
        let renderer = model.renderer, session = model.session, metalLayer = Unsafe(v: ml)
        let clock = model.clock, box = model.box
        let backingScale = session.meta.source.backingScale
        let maskDirectory = session.bundle.cacheURL.appendingPathComponent("analysis", isDirectory: true)
        driver = PreviewDriver(shared: sh, vsync: vc, clock: clock, box: box,
                               backingScale: backingScale, maskDirectory: maskDirectory, feed: continuation)
        loop = Task.detached(priority: .userInitiated) {
            for await tick in stream {
                if Task.isCancelled { break }
                let frames: (screen: SourceFrame, webcam: SourceFrame?)
                do { frames = try await session.frames(atOutput: tick.t, timeline: tick.timeline) } catch { continue }
                // SMOOTHNESS: decode can eat the scheduling slack. Re-pick the
                // vsync and recompute content time from the same clock together,
                // so a late frame is never shown with content for a passed vsync.
                var present = tick.present, t = tick.t
                let now = CACurrentMediaTime(), slack = 0.003
                if present - now < slack {
                    present = vc.firstVsync(after: now + slack)
                    t = clock.time(at: present)
                }
                let request = RenderRequest(timeline: tick.timeline, t: t, screen: frames.screen, webcam: frames.webcam,
                                            canvas: tick.size, fps: tick.fps, backingScale: tick.backingScale,
                                            quality: .preview, uiTime: tick.uiTime, pointer: tick.pointer,
                                            personMaskDirectory: tick.maskDirectory)
                // false → drop; a newer tick is already queued (bufferingNewest(1)).
                _ = renderer.draw(request, to: metalLayer.v, presentAt: present)
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
        link?.invalidate(); link = nil; playheadTimer?.invalidate(); playheadTimer = nil
        linkRunner.stop()
        guard window != nil else { return }
        window?.acceptsMouseMovedEvents = true
        shared.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // The link lives on its own runloop so SwiftUI layout and 12 Hz playhead
        // publishes cannot starve vsync callbacks.
        let l = displayLink(target: driver, selector: #selector(PreviewDriver.tick(_:)))
        let box = Unsafe(v: l)
        let runner = linkRunner
        let th = Thread {
            guard runner.install() else { return }
            box.v.add(to: .current, forMode: .common)
            guard runner.isLive else { return }
            RunLoop.current.run()
        }
        th.name = "lumen.preview.displaylink"; th.qualityOfService = .userInteractive; th.start()
        link = l

        // Playhead echo for SwiftUI only. The renderer never reads this.
        playheadTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let m = self.model
                self.shared.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.shared.exportRunning = if case .running = m.exportState { true } else { false }
                guard m.clock.playing else { return }
                m.tick(m.clock.time(at: HostClock.now()))
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved], owner: self)
        addTrackingArea(area); pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { shared.pointerTarget.z = 0 }
    override func mouseMoved(with event: NSEvent) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        shared.pointerTarget = SIMD3(Double(min(max(point.x / bounds.width, 0), 1)),
                                     Double(min(max(1 - point.y / bounds.height, 0), 1)), 1)
    }
    override func mouseDown(with event: NSEvent) {
        guard model.placingTool != nil, bounds.width > 0, bounds.height > 0 else {
            super.mouseDown(with: event)
            return
        }
        let source = model.session.meta.source
        guard source.width > 0, source.height > 0 else { return }
        let canvas = metal.drawableSize
        let point = convert(event.locationInWindow, from: nil)
        let pixel = SIMD2(Double(point.x / bounds.width) * Double(canvas.width),
                          Double(1 - point.y / bounds.height) * Double(canvas.height))
        let tl = model.timeline
        let frame = tl.evaluate(at: model.playhead)
        let size = SIMD2(Double(source.width), Double(source.height))
        let camera = tl.derived == nil ? size / 2 :
            SIMD2(Double(frame.cameraCenter.x), Double(frame.cameraCenter.y))
        let transform = ZoomTransform(canvas: SIMD2(Int(canvas.width), Int(canvas.height)),
                                      source: size, style: tl.style,
                                      cameraCenter: camera, scale: tl.derived == nil ? 1 : Double(frame.cameraScale))
        let rect = transform.videoRect
        guard pixel.x >= rect.x, pixel.y >= rect.y,
              pixel.x <= rect.x + rect.z, pixel.y <= rect.y + rect.w else { return }
        model.placeSelectedTool(at: transform.canvasToSource(pixel))
    }
    override func layout() {
        super.layout()
        // SMOOTHNESS: during a live resize the layer stretches the last frame.
        // Reallocating ~8 full-size RGBA16F targets per pixel of drag is a stall.
        guard !inLiveResize else { return }
        let s = window?.backingScaleFactor ?? 2
        metal.contentsScale = s
        let size = CGSize(width: max(bounds.width * s, 2).rounded(), height: max(bounds.height * s, 2).rounded())
        metal.drawableSize = size
        shared.drawable = size
    }
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        shared.frozen = true
        metal.contentsGravity = .resize
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        shared.frozen = false
        needsLayout = true
    }

    deinit {
        feed.finish()
        loop.cancel()
        // AppKit tears views down on the main thread; the guard keeps a
        // non-main release from trapping in assumeIsolated.
        if Thread.isMainThread { MainActor.assumeIsolated { link?.invalidate(); playheadTimer?.invalidate() } }
        linkRunner.stop()
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
