import AppKit
import SwiftUI

/// Native semantic material shared by recorder panels. Let AppKit compose
/// the backdrop instead of imposing a black HUD or a large opaque wash.
/// No screen capture permission or private WindowServer API is used.
@MainActor
final class FrostView: NSView {
    private let blur = NSVisualEffectView()
    private let wash = NSView()
    private let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true

        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.isEmphasized = false
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)

        wash.wantsLayer = true
        wash.autoresizingMask = [.width, .height]
        addSubview(wash)
        applyWash()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        blur.frame = bounds
        wash.frame = bounds
    }

    private func applyWash() {
        let workspace = NSWorkspace.shared
        let flat = workspace.accessibilityDisplayShouldReduceTransparency
        blur.isHidden = flat
        // Default is entirely native material. Use an opaque semantic
        // background for accessibility rather than hard-coded black/white.
        let contrast = workspace.accessibilityDisplayShouldIncreaseContrast
        wash.isHidden = !flat && !contrast
        let fill = NSColor.windowBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            wash.layer?.backgroundColor = fill.withAlphaComponent(flat ? 1 : 0.45).cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshMaterial()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyWash()
    }

    /// Re-reads accessibility display settings (Reduce Transparency can flip
    /// while the bar is on screen).
    func refreshMaterial() { applyWash() }
}

private struct HandCursorRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> HandCursorView { HandCursorView() }
    func updateNSView(_ view: HandCursorView, context: Context) {}
}

@MainActor private final class HandCursorView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    func floatingHandCursor() -> some View {
        pointerStyle(.link)
            .overlay { HandCursorRegion().allowsHitTesting(false) }
    }
}

/// Borderless, non-activating, always-on-top panel with a glass body.
@MainActor
class GlassPanel: NSPanel {
    let radius: CGFloat
    private let surface: FrostView
    private(set) var host: NSHostingView<AnyView>?

    init(radius: CGFloat, level: NSWindow.Level = .statusBar) {
        self.radius = radius
        surface = FrostView(radius: radius)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        canHide = false
        isFloatingPanel = true
        self.level = level
        titlebarAppearsTransparent = true
        // Never in a recording, never in Mission Control's window cycle.
        #if DEBUG
        sharingType = ProcessInfo.processInfo.environment["LUMEN_CAPTURE_BAR"] == "1" ? .readOnly : .none
        #else
        sharingType = .none
        #endif
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = surface
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Installs a SwiftUI tree and returns the size it wants.
    @discardableResult
    func install<V: View>(_ view: V) -> CGSize {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        surface.subviews.filter { $0 is NSHostingView<AnyView> }.forEach { $0.removeFromSuperview() }
        surface.addSubview(hosting)
        host = hosting
        let size = hosting.fittingSize
        setContentSize(size)
        hosting.frame = CGRect(origin: .zero, size: size)
        return size
    }

    func setSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        var frame = self.frame
        guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else { return }
        // Keep the top edge and the centre: the bar grows around its anchor.
        frame.origin.x += (frame.width - size.width) / 2
        frame.origin.y += frame.height - size.height
        frame.size = size
        setFrame(frame, display: true)
        host?.frame = CGRect(origin: .zero, size: size)
    }
}
