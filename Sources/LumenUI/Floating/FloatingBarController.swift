import AppKit
import SwiftUI
import AVFoundation
import LumenCapture

/// Owns the floating recorder: the bar itself and the one panel attached to it.
@MainActor final class FloatingBarController {
    static var current: FloatingBarController?

    private let app: AppModel
    private let bar = GlassPanel(radius: 20, level: .statusBar)
    var recordingWindow: NSWindow { bar }
    private var aux: GlassPanel?
    private var lastAnchors: [String: CGRect] = [:]
    private var auxID: String?
    private var monitors: [Any] = []
    private var moveObserver: NSObjectProtocol?
    private var size = CGSize(width: 508, height: 78)
    let countdown = CountdownController()

    init(_ app: AppModel, screen: NSScreen?) {
        self.app = app
        FloatingBarController.current = self
        bar.title = "Lumen recording controls"
        bar.isMovableByWindowBackground = true
        bar.setAccessibilityLabel("Lumen recording controls")
        bar.install(view)
        restorePosition(screen: screen)
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                                              object: bar, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }
    }

    private var view: some View {
        FloatingBarView(app: app,
                        onOptions: { [weak self] anchor in self?.present(anchor) },
                        onRecord: { [weak self] in self?.record() },
                        onStop: { [weak self] in self?.app.toggle() },
                        onPause: { [weak self] in self?.app.togglePause() },
                        onDiscard: { [weak self] in self?.app.discard() },
                        onCancel: { [weak self] in self?.app.cancelStart() },
                        onHide: { [weak self] in self?.app.hideFloatingBar() })
    }

    // MARK: Lifecycle

    func show() {
        if !bar.isVisible {
            bar.alphaValue = 0
            bar.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
                bar.animator().alphaValue = 1
            }
        }
    }

    /// Conforms the panel to the persisted visibility choice. Creating the
    /// controller is cheap and keeps capture exclusion/countdown working even
    /// while the bar itself is hidden by default.
    func applyVisibility() {
        if FloatingBarVisibility.isHidden() { hide() } else { show() }
    }

    /// Hides just the bar. No focus change, no window, no teardown: the menu-bar
    /// toggle can bring the same panel straight back.
    func hide() {
        closePanels()
        bar.orderOut(nil)
    }

    func close() {
        closePanels()
        countdown.hide()
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        bar.orderOut(nil)
        if FloatingBarController.current === self { FloatingBarController.current = nil }
    }

    func resizeBar(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        // Preference delivery can repeat an identical size on every phase
        // change; resizing the window for no change is pure churn.
        guard size != self.size || bar.frame.size != size else { return }
        let before = bar.frame
        bar.setSize(size)
        self.size = size
        clampToScreen()
        if bar.frame != before, !bar.isVisible { clampToScreen() }
    }

    private func restorePosition(screen: NSScreen?) {
        bar.setSize(size)
        if let saved = UserDefaults.standard.object(forKey: "LumenBarOrigin") as? [String: Double],
           let x = saved["x"], let y = saved["y"] {
            bar.setFrameOrigin(CGPoint(x: x, y: y))
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: 40, dy: 0).contains(CGPoint(x: x + size.width / 2, y: y + size.height / 2)) }) { return }
        }
        let target = screen ?? NSScreen.main
        guard let frame = target?.visibleFrame else { return }
        bar.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12))
    }

    private func clampToScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(bar.frame) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = bar.frame
        frame.origin.x = min(max(frame.minX, visible.minX + 8), visible.maxX - frame.width - 8)
        frame.origin.y = min(max(frame.minY, visible.minY + 8), visible.maxY - frame.height - 8)
        if frame != bar.frame { bar.setFrame(frame, display: true) }
    }

    private func savePosition() {
        UserDefaults.standard.set(["x": bar.frame.minX, "y": bar.frame.minY], forKey: "LumenBarOrigin")
    }

    // MARK: Actions

    private func record() {
        closePanels()
        Task { await app.start() }
    }

    /// Area mode is a two-step mode: choose the rectangle, then record it.
    func selectArea(openPicker: Bool) {
        app.kind = .region
        guard openPicker else { return }
        closePanels()
        Task { @MainActor in
            let previous = app.lastArea.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            guard let picked = await AreaSelector.pick(previous: previous) else { return }
            app.setArea(display: picked.displayID, rect: picked.rect)
        }
    }

    // MARK: Panels

    func present(_ anchor: BarAnchor) {
        lastAnchors[anchor.id] = anchor.rect
        if auxID == anchor.id { closePanels(); return }
        presentOptions(for: anchor, in: app)
    }

    /// Opens a panel for an item that was clicked directly (no chevron), reusing
    /// the trigger's last measured position.
    func present(options id: String, in app: AppModel) {
        presentOptions(for: BarAnchor(id: id, rect: lastAnchors[id] ?? .zero), in: app)
    }

    func presentOptions(for anchor: BarAnchor, in app: AppModel) {
        closePanels()
        let id = anchor.id
        let content: AnyView
        switch id {
        case "window": content = AnyView(WindowPickerPanel(app: app))
        case "camera": content = AnyView(CameraPanel(app: app))
        case "microphone": content = AnyView(MicrophonePanel(app: app))
        case "area": content = AnyView(AreaPanel(app: app))
        default: content = AnyView(CaptureSettingsPanelView(app: app))
        }
        let panel = GlassPanel(radius: 16, level: .statusBar)
        let size = panel.install(content)
        // Centre under the trigger, below the bar, clamped to the screen.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(bar.frame.origin) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let offset = anchor.rect.width > 0 ? anchor.rect.midX : self.size.width / 2
        let triggerX = bar.frame.minX + offset
        var x = triggerX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        var y = bar.frame.minY - 8 - size.height
        if y < visible.minY + 8 { y = bar.frame.maxY + 8 }
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        panel.orderFrontRegardless()
        if id == "window" { panel.makeKeyAndOrderFront(nil) }
        aux = panel
        auxID = id
        installDismissMonitors()
    }

    func closePanels() {
        aux?.orderOut(nil)
        aux = nil
        auxID = nil
        removeDismissMonitors()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.closePanels(); return nil }
                return event
            }
            let point = NSEvent.mouseLocation
            if let aux = self.aux, aux.frame.contains(point) { return event }
            if self.bar.frame.contains(point) { return event }
            self.closePanels()
            return event
        }, let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanels()
        } {
            monitors = [local, global]
        }
    }

    private func removeDismissMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}
