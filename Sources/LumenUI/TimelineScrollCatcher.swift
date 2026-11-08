import SwiftUI
import AppKit

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

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { removeMonitor() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let w = self.window, event.window === w else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                switch event.type {
                case .scrollWheel:
                    self.onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, event.modifierFlags.contains(.command))
                    return nil
                case .magnify:
                    self.onMagnify?(event.magnification, p.x)
                    return nil
                default:
                    return event
                }
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
