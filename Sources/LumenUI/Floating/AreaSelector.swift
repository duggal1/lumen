import SwiftUI
import AppKit
import LumenCapture

/// Free-form area selection. Dim the screen, cut the hole, mark the corners
/// with brackets, and float the same white glass HUD as everything else while
/// the drag runs: live width × height and the display position.
@MainActor enum AreaSelector {
    struct Selection {
        var displayID: CGDirectDisplayID
        /// Display-relative, top-left origin (what ScreenCaptureKit wants).
        var rect: CGRect
    }

    static func pick(previous: CGRect? = nil) async -> Selection? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        let scale = screen.backingScaleFactor
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Selection?, Never>) in
            let window = AreaWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = AreaView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let hud = AreaHUDController(screen: screen)
            view.onChange = { rect in hud.update(rect: rect, screen: screen) }
            view.finish = { rect in
                hud.close()
                window.orderOut(nil)
                NSCursor.arrow.set()
                guard let rect, rect.width >= 16, rect.height >= 16 else { continuation.resume(returning: nil); return }
                // AppKit (bottom-left, points) -> ScreenCaptureKit (top-left,
                // display relative). Snap to whole device pixels at this
                // display's backing scale, not to whole points.
                let flipped = CGRect(x: snap(rect.minX), y: snap(screen.frame.height - rect.maxY),
                                     width: snap(rect.width), height: snap(rect.height))
                continuation.resume(returning: Selection(displayID: displayID, rect: flipped))
            }
            view.previous = previous.map { CGRect(x: $0.minX, y: screen.frame.height - $0.maxY,
                                                  width: $0.width, height: $0.height) }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSCursor.crosshair.set()
            hud.show()
            if let rect = view.previous { view.onChange?(rect) }
        }
    }
}

private final class AreaWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class AreaView: NSView {
    var finish: ((CGRect?) -> Void)?
    var onChange: ((CGRect) -> Void)?
    var previous: CGRect?
    private var selection = CGRect.zero
    private var anchor = CGPoint.zero
    private var dragOrigin = CGRect.zero
    private var mode: Mode = .create

    private enum Mode { case create, move, resizeX, resizeY, resizeBoth }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let previous { selection = previous; onChange?(previous) }
    }

    private func handleZones(_ point: CGPoint) -> Mode {
        guard selection.width > 1 else { return .create }
        let edge: CGFloat = 14
        let nearLeft = abs(point.x - selection.minX) < edge
        let nearRight = abs(point.x - selection.maxX) < edge
        let nearTop = abs(point.y - selection.maxY) < edge
        let nearBottom = abs(point.y - selection.minY) < edge
        if (nearLeft || nearRight) && (nearTop || nearBottom) { return .resizeBoth }
        if nearLeft || nearRight { return .resizeX }
        if nearTop || nearBottom { return .resizeY }
        if selection.contains(point) { return .move }
        return .create
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        anchor = point
        mode = handleZones(point)
        dragOrigin = selection
        if mode == .create {
            selection = CGRect(origin: point, size: .zero)
            onChange?(selection)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch mode {
        case .create:
            selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                               width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        case .move:
            let dx = point.x - anchor.x, dy = point.y - anchor.y
            var rect = dragOrigin.offsetBy(dx: dx, dy: dy)
            rect.origin.x = min(max(rect.origin.x, 0), bounds.width - rect.width)
            rect.origin.y = min(max(rect.origin.y, 0), bounds.height - rect.height)
            selection = rect
        case .resizeX, .resizeY, .resizeBoth:
            var rect = dragOrigin
            if mode != .resizeY {
                if abs(point.x - dragOrigin.minX) < abs(point.x - dragOrigin.maxX) {
                    rect.origin.x = min(point.x, dragOrigin.maxX - 24)
                    rect.size.width = dragOrigin.maxX - rect.origin.x
                } else {
                    rect.size.width = max(point.x - dragOrigin.minX, 24)
                }
            }
            if mode != .resizeX {
                if abs(point.y - dragOrigin.minY) < abs(point.y - dragOrigin.maxY) {
                    rect.origin.y = min(point.y, dragOrigin.maxY - 24)
                    rect.size.height = dragOrigin.maxY - rect.origin.y
                } else {
                    rect.size.height = max(point.y - dragOrigin.minY, 24)
                }
            }
            selection = rect.intersection(bounds)
        }
        onChange?(selection)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onChange?(selection)
        NSCursor.crosshair.set()
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 53: // esc
            finish?(nil)
        case 36, 76: // return
            confirm()
        case 123: nudge(dx: -step); case 124: nudge(dx: step)
        case 125: nudge(dy: -step); case 126: nudge(dy: step)
        default: break
        }
    }

    private func nudge(dx: CGFloat = 0, dy: CGFloat = 0) {
        guard selection.width > 0 else { return }
        selection = selection.offsetBy(dx: dx, dy: dy).intersection(bounds)
        onChange?(selection)
        needsDisplay = true
    }

    private func confirm() {
        guard selection.width >= 16, selection.height >= 16 else { return }
        finish?(selection)
    }

    override func rightMouseDown(with event: NSEvent) { finish?(nil) }

    override func draw(_ dirty: NSRect) {
        // One dim, one hole, four brackets. No borders, no glow.
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()
        guard selection.width > 1 else { return }
        NSColor.clear.setFill()
        selection.fill(using: .copy)

        AppKitToken.accent.setFill()
        let arm: CGFloat = 8, thick: CGFloat = 2
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: selection.minX, y: selection.maxY), 1, -1),
            (CGPoint(x: selection.maxX, y: selection.maxY), -1, -1),
            (CGPoint(x: selection.minX, y: selection.minY), 1, 1),
            (CGPoint(x: selection.maxX, y: selection.minY), -1, 1),
        ]
        for (corner, sx, sy) in corners {
            let x = sx > 0 ? corner.x : corner.x - arm
            let horizontal = CGRect(x: x, y: sy > 0 ? corner.y - thick : corner.y, width: arm, height: thick)
            let vertical = CGRect(x: sx > 0 ? corner.x : corner.x - thick,
                                  y: sy > 0 ? corner.y - arm : corner.y, width: thick, height: arm)
            horizontal.fill(); vertical.fill()
        }

    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

// MARK: - Live HUD

@MainActor private final class AreaHUDController {
    private let screen: NSScreen
    private var panel: GlassPanel?
    private let state = AreaHUDState()

    init(screen: NSScreen) { self.screen = screen }

    func show() {
        let panel = GlassPanel(radius: 14, level: .screenSaver)
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.install(AreaHUD(state: state))
        panel.setContentSize(CGSize(width: 168, height: 52))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func update(rect: CGRect, screen: NSScreen) {
        guard let panel else { return }
        let width = max(Int(rect.width.rounded()), 0)
        let height = max(Int(rect.height.rounded()), 0)
        // Position in the display's own top-left space, the way ScreenCaptureKit
        // and every screen recording tool reports it.
        let x = Int(rect.minX.rounded())
        let y = Int((screen.frame.height - rect.maxY).rounded())
        state.size = "\(width) × \(height)"
        state.position = "\(x), \(y)"
        let originX = screen.frame.minX + rect.minX
        let originY = screen.frame.minY + rect.maxY + 10
        let clampedX = min(max(originX, screen.frame.minX + 8), screen.frame.maxX - 176)
        let clampedY = min(max(originY, screen.frame.minY + 8), screen.frame.maxY - 60)
        panel.setFrameOrigin(CGPoint(x: clampedX, y: clampedY))
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor @Observable private final class AreaHUDState {
    var size = "0 × 0"
    var position = "0, 0"
}

private struct AreaHUD: View {
    let state: AreaHUDState

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(state.size)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Tok.text)
                Text("\(state.position)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Tok.text2)
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text("Return").font(.system(size: 10, weight: .medium)).foregroundStyle(Tok.text2)
                Text("Esc").font(.system(size: 10, weight: .medium)).foregroundStyle(Tok.text2)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 168, height: 52)
    }
}
