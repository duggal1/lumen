import SwiftUI
import AppKit

/// Transparent titlebar, floating traffic lights, non-opaque window. Chrome stays 1-bit.
public struct WindowChrome: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { configure(v.window) }
        return v
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: Metrics.minW, height: Metrics.minH)
        window.isMovableByWindowBackground = false
    }
}
