import SwiftUI
import AppKit

/// Transparent titlebar, floating traffic lights, non-opaque window. Chrome stays 1-bit.
public struct WindowChrome: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView { ChromeView() }
    public func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ChromeView)?.apply() }

    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.minSize = NSSize(width: Metrics.minW, height: Metrics.minH)
            window.isMovableByWindowBackground = false
            clampToVisibleFrameIfNeeded()
        }

        private var clamped = false
        private func clampToVisibleFrameIfNeeded() {
            guard !clamped, let window else { return }
            clamped = true
            // Only re-place on first appearance if the restored frame is not
            // fully visible on its screen; otherwise keep the saved frame.
            let frame = window.frame
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
                ?? NSScreen.main ?? NSScreen.screens.first
            guard let visible = screen?.visibleFrame else { return }
            let fullyVisible = frame.minX >= visible.minX - 1 && frame.minY >= visible.minY - 1
                && frame.maxX <= visible.maxX + 1 && frame.maxY <= visible.maxY + 1
            if fullyVisible { return }
            // Center at ~82% of the visible frame, sensible minimum, with margin.
            var size = frame.size
            let targetW = min(max(size.width, Metrics.minW), visible.width * 0.82)
            let targetH = min(max(size.height, Metrics.minH), visible.height * 0.82)
            size = CGSize(width: targetW, height: targetH)
            let origin = CGPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2)
            window.setFrame(NSRect(origin: origin, size: size), display: true)
        }
    }
}
