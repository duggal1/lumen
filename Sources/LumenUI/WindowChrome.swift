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
        }
    }
}
