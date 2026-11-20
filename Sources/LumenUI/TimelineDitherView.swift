import AppKit
import QuartzCore
import SwiftUI

/// The Clove dither instrument, hosted behind the timeline's labels and
/// overlays. The view owns the display schedule: it runs while the timeline is
/// playing or while cells are still warm, and stops at rest. Hover, pan, zoom
/// and data changes wake it again.
struct TimelineDitherView: NSViewRepresentable {
    let snapshot: TimelineDitherRenderer.Frame

    func makeNSView(context: Context) -> TimelineDitherNSView {
        let view = TimelineDitherNSView()
        view.snapshot = self.snapshot
        return view
    }

    func updateNSView(_ view: TimelineDitherNSView, context: Context) {
        view.snapshot = snapshot
        view.wake()
    }

    static func dismantleNSView(_ view: TimelineDitherNSView, coordinator: ()) { view.stop() }
}

final class TimelineDitherNSView: NSView {
    var snapshot = TimelineDitherRenderer.Frame(spans: Array(repeating: [], count: 5), peaks: [], clicks: [], head: -1,
                                             playing: false, reduced: false, dt: 0, t: 0)

    private let glowLayer = CALayer()
    private let cellsLayer = CALayer()
    private let overlayLayer = CALayer()
    private var renderer: TimelineDitherRenderer?
    private var link: CADisplayLink?
    private var occlusion: NSObjectProtocol?
    private var last: CFTimeInterval = 0
    private var clock: Double = 0
    private var settled = 0
    private var started = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        glowLayer.magnificationFilter = .linear
        glowLayer.opacity = 0.7
        cellsLayer.magnificationFilter = .nearest
        overlayLayer.magnificationFilter = .nearest
        for l in [glowLayer, cellsLayer, overlayLayer] {
            l.contentsGravity = .resize
            l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(l)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        glowLayer.magnificationFilter = .linear
        glowLayer.opacity = 0.3
        cellsLayer.magnificationFilter = .nearest
        overlayLayer.magnificationFilter = .nearest
        for l in [glowLayer, cellsLayer, overlayLayer] {
            l.contentsGravity = .resize
            l.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(l)
        }
        setAccessibilityElement(false)
    }

    /// Never let a CALayer keep an image produced by a renderer we are about
    /// to drop. The images now own their bytes, but clearing first also stops
    /// a stale frame from flashing during an appearance or backing change.
    private func releaseRenderer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.contents = nil
        cellsLayer.contents = nil
        overlayLayer.contents = nil
        CATransaction.commit()
        renderer = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        if let window {
            occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let w = self.window else { return }
                    if w.occlusionState.contains(.visible) { self.wake() } else { self.stop() }
                }
            }
        }
        if window == nil { stop() } else { wake() }
    }

    override func layout() {
        super.layout()
        rebuildIfNeeded()
        wake()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        releaseRenderer()
        rebuildIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        releaseRenderer()
        rebuildIfNeeded()
    }

    private func rebuildIfNeeded() {
        let w = bounds.width
        guard w > 40 else { return }
        let scale = min(2, max(1, window?.backingScaleFactor ?? 2))
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if let r = renderer, r.width == w.rounded(.down), r.height == bounds.height.rounded(.down),
           r.scale == scale, r.isDark == dark { return }
        releaseRenderer()
        renderer = TimelineDitherRenderer(width: w, height: bounds.height, scale: scale, isDark: dark)
        glowLayer.opacity = dark ? 0.3 : 0.2
        let pad = CGFloat(TimelineDitherRenderer.glowPad) * TimelineDitherRenderer.pitch
        let cols = max(1, Int((w - 2 * TimelineDitherRenderer.inset) / TimelineDitherRenderer.pitch))
        let glowW = CGFloat(cols + TimelineDitherRenderer.glowPad * 2) * TimelineDitherRenderer.pitch
        let glowH = CGFloat(TimelineDitherRenderer.lanes * 10 + TimelineDitherRenderer.glowPad * 2) * TimelineDitherRenderer.pitch
        let cellRect = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        cellsLayer.frame = cellRect
        overlayLayer.frame = cellRect
        glowLayer.frame = CGRect(x: TimelineDitherRenderer.inset - pad,
                                 y: TimelineDitherRenderer.pitch - pad,
                                 width: glowW, height: glowH)
        wake()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func wake() {
        settled = 0
        guard let window, window.occlusionState.contains(.visible) else { return }
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            last = 0
        }
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = last == 0 ? 1.0 / 60 : min(0.05, max(1.0 / 240, now - last))
        last = now
        clock += snapshot.reduced ? 0 : dt
        guard let renderer else { rebuildIfNeeded(); return }
        var f = snapshot
        f.dt = dt
        f.t = clock
        if !started { f.reduced = true; started = true } // first frame is the finished state
        let out = renderer.draw(f)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowLayer.contents = out.glow
        cellsLayer.contents = out.cells
        overlayLayer.contents = out.overlay
        CATransaction.commit()

        // A stationary playhead is drawn once; only motion keeps the link alive.
        let busy = out.isWarm || f.playing
        if busy { settled = 0 }
        else {
            settled += 1
            if settled >= 2 { stop() }
        }
    }
}
