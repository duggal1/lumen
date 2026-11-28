import AppKit
import QuartzCore
import SwiftUI

/// Coalesces changed viewport snapshots to a single display refresh.
struct TimelineDitherView: NSViewRepresentable {
    let snapshot: TimelineDitherRenderer.Frame

    func makeNSView(context: Context) -> TimelineDitherNSView {
        let view = TimelineDitherNSView()
        view.snapshot = self.snapshot
        return view
    }

    func updateNSView(_ view: TimelineDitherNSView, context: Context) {
        view.update(snapshot)
    }

    static func dismantleNSView(_ view: TimelineDitherNSView, coordinator: ()) { view.stop() }
}

final class TimelineDitherNSView: NSView {
    var snapshot = TimelineDitherRenderer.Frame(spans: Array(repeating: [], count: 5), peaks: [], clicks: [], head: -1,
                                             playing: false, reduced: false, dt: 0, t: 0)

    private let cellsLayer = CALayer()
    private let overlayLayer = CALayer()
    private var renderer: TimelineDitherRenderer?
    private var link: CADisplayLink?
    private var occlusion: NSObjectProtocol?
    private var lastDrawn: TimelineDitherRenderer.Frame?

    func update(_ frame: TimelineDitherRenderer.Frame) {
        var next = frame; next.dt = 0; next.t = 0
        guard next != snapshot else { return }
        snapshot = next; wake()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        cellsLayer.magnificationFilter = .nearest
        overlayLayer.magnificationFilter = .nearest
        for l in [cellsLayer, overlayLayer] {
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
        cellsLayer.magnificationFilter = .nearest
        overlayLayer.magnificationFilter = .nearest
        for l in [cellsLayer, overlayLayer] {
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
        cellsLayer.contents = nil
        overlayLayer.contents = nil
        CATransaction.commit()
        renderer = nil; lastDrawn = nil
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
        let cellRect = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        cellsLayer.frame = cellRect
        overlayLayer.frame = cellRect
        wake()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func wake() {
        guard let window, window.occlusionState.contains(.visible) else { return }
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        link?.preferredFrameRateRange = StudioDisplayRate.range(screenMaximum: window.screen?.maximumFramesPerSecond ?? 60)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let renderer else { rebuildIfNeeded(); return }
        guard snapshot != lastDrawn else { stop(); return }
        let out = renderer.draw(snapshot)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cellsLayer.contents = out.cells
        overlayLayer.contents = out.overlay
        CATransaction.commit()
        lastDrawn = snapshot
        stop()
    }
}
