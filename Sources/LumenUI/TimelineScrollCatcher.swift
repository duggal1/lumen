import SwiftUI
import AppKit
import QuartzCore

/// Local scroll monitor: pan and zoom over the strip without stealing clicks.
/// Trackpad deltas arrive at display rate with the system's own momentum, so
/// the strip moves the exact distance the fingers did.
struct TimelineScrollCatcher: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat, Bool) -> Void
    var onMagnify: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = Catcher()
        v.onScroll = onScroll
        v.onMagnify = onMagnify
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let c = v as? Catcher else { return }
        c.onScroll = onScroll
        c.onMagnify = onMagnify
    }

    final class Catcher: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
        var onMagnify: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?
        private var link: CADisplayLink?
        private var remaining: CGFloat = 0
        private var lastTick: CFTimeInterval = 0

        /// Only discrete mouse wheel steps get a short, non-overshooting
        /// settling tail. Precise trackpads already supply native momentum.
        private func enqueue(_ delta: CGFloat) {
            guard delta.isFinite else { return }
            remaining = min(max(remaining + delta, -1200), 1200)
            if link == nil {
                let display = displayLink(target: self, selector: #selector(advanceWheel(_:)))
                lastTick = 0
                display.add(to: .main, forMode: .common)
                link = display
            }
        }

        @objc private func advanceWheel(_ display: CADisplayLink) {
            let now = display.timestamp
            let dt = lastTick > 0 ? min(max(now - lastTick, 0), 0.1) : 1.0 / 60
            lastTick = now
            let amount = abs(remaining) < 0.5 ? remaining : remaining * CGFloat(1 - exp(-dt * 28))
            remaining -= amount
            onScroll?(amount, 0, false)
            if abs(remaining) < 0.001 { stopWheel() }
        }

        private func stopWheel() {
            link?.invalidate()
            link = nil
            remaining = 0
            lastTick = 0
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { removeMonitor() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let w = self.window, event.window === w else { return event }
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    self.stopWheel()
                    return event
                }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                switch event.type {
                case .scrollWheel:
                    let command = event.modifierFlags.contains(.command)
                    if command || event.hasPreciseScrollingDeltas || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        self.stopWheel()
                        self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, command)
                    } else {
                        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
                        self.enqueue((abs(dx) >= abs(dy) ? dx : dy) * 12)
                    }
                    return nil
                case .magnify:
                    self.stopWheel()
                    self.onMagnify?(event.magnification, p.x)
                    return nil
                default:
                    return event
                }
            }
        }

        private func removeMonitor() {
            stopWheel()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
