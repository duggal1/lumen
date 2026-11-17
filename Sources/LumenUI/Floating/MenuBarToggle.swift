import AppKit

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
        let glyph = NSImage(systemSymbolName: "slider.horizontal.3",
                            accessibilityDescription: "Lumen recording controls")
        glyph?.isTemplate = true
        status.button?.image = glyph
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
