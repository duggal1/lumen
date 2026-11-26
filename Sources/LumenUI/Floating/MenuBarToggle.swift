import AppKit

/// The Lumen mark as a menu-bar template glyph.
///
/// The status item is a 1-bit surface: the pixelated blue mark collapses to
/// mush at 18 pt, and a template image must be a single ink so the system can
/// tint it for a light or dark menu bar. So the status item carries the mark's
/// silhouette only. The full-color mark belongs on tiles and icons.
enum MenuBarMark {
    /// Each run of the staircase in the master artwork's 32-unit grid:
    /// (x, y, width). Every run is one cell tall.
    private static let runs: [(CGFloat, CGFloat, CGFloat)] = [
        (288, 224, 32), (288, 256, 64), (288, 288, 96), (288, 320, 128),
        (288, 352, 160), (288, 384, 192), (288, 416, 224), (288, 448, 256),
        (288, 480, 288), (288, 512, 320), (288, 544, 352), (288, 576, 384),
        (288, 608, 416), (288, 640, 256), (288, 672, 128), (448, 672, 128),
        (288, 704, 96), (480, 704, 96), (288, 736, 64), (480, 736, 128),
        (288, 768, 32), (512, 768, 96), (512, 800, 128), (544, 832, 32),
    ]
    private static let cell: CGFloat = 32
    private static let originX: CGFloat = 288
    private static let originY: CGFloat = 224
    private static let markW: CGFloat = 416
    private static let markH: CGFloat = 640

    static func image(height: CGFloat = 16) -> NSImage {
        let scale = height / markH
        let size = NSSize(width: (markW * scale).rounded(), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            let ox = (size.width - markW * scale) / 2
            // One path, one fill: 24 stacked runs would otherwise seam along
            // their shared edges at fractional point sizes.
            let path = NSBezierPath()
            for (x, y, runW) in runs {
                // The master's y grows downward; this context grows upward.
                let top = (y - originY) * scale
                path.appendRect(NSRect(x: ox + (x - originX) * scale,
                                       y: size.height - top - cell * scale,
                                       width: runW * scale,
                                       height: cell * scale))
            }
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A single menu-bar status item that shows or hides the floating recorder.
///
/// It is a borderless template glyph with a direct target/action: no menu, no
/// window and no `NSApp.activate`, so clicking it cannot steal focus. The item
/// is installed only after the app finishes launching, which keeps `swift test`
/// completely headless.
@MainActor
final class FloatingBarMenuBarToggle: NSObject {
    static let shared = FloatingBarMenuBarToggle()

    /// Set by tests that intentionally construct an AppModel. The real app
    /// never touches it; it prevents a status item from appearing in a test run.
    static var autoInstallEnabled = true

    private var item: NSStatusItem?
    private weak var app: AppModel?

    func install(app: AppModel) {
        self.app = app
        guard item == nil, Self.autoInstallEnabled, !(app.headless) else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = MenuBarMark.image()
        status.button?.target = self
        status.button?.action = #selector(toggle(_:))
        item = status
        syncAccessibility()
    }

    /// Reflects the current state in the status item's accessible name, so the
    /// toggle reads correctly with VoiceOver without any extra UI.
    func syncAccessibility() {
        let hidden = FloatingBarVisibility.isHidden()
        item?.button?.setAccessibilityLabel("Lumen recording controls")
        item?.button?.setAccessibilityValue(hidden ? "Hidden" : "Shown")
        item?.button?.toolTip = hidden
            ? "Show Lumen recording controls"
            : "Hide Lumen recording controls"
    }

    @objc private func toggle(_ sender: Any?) {
        app?.toggleFloatingBar()
    }
}
