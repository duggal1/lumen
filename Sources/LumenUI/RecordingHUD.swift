import AppKit
import SwiftUI
import Observation

@MainActor @Observable final class RecordingMeter {
    var level: Float = 0
}

@MainActor final class HUDController {
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private let presentation = HUDPresentation()
    private var settings: CaptureSettingsController?

    init(_ app: AppModel, screen: NSScreen?) {
        let width: CGFloat = 390, height: CGFloat = 56
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .aqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = "Lumen recording controls"
        panel.setAccessibilityLabel("Lumen recording controls")

        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = Radius.card
        material.layer?.masksToBounds = true
        let content = NSHostingView(rootView: RecordingHUD(app: app, presentation: presentation, openSettings: { [weak self] in
            guard let self else { return }
            if self.settings == nil { self.settings = CaptureSettingsController(app) }
            self.settings?.show()
        }))
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor)
        ])
        panel.contentView = material
        if let saved = UserDefaults.standard.object(forKey: "LumenHUDOrigin") as? [String: Double],
           let x = saved["x"], let y = saved["y"] {
            panel.setFrameOrigin(CGPoint(x: x, y: y))
        } else if let screen {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - width / 2,
                                         y: screen.visibleFrame.maxY - height - Space.s4))
        }
        self.panel = panel
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: nil) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                let origin = window.frame.origin
                UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: "LumenHUDOrigin")
            }
        }
    }

    func show() {
        guard let panel else { return }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 1
            }
        }
        presentation.visible = true
    }
    func showCountdown() { show() }
    func showControls() { show() }
    func close() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        presentation.visible = false
        if let panel {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
        panel = nil
    }
}

@MainActor private final class HUDPresentation: ObservableObject {
    @Published var visible = false
}

private struct RecordingHUD: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let app: AppModel
    @ObservedObject var presentation: HUDPresentation
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: Space.s2) {
            if app.phase == .idle {
                Button { app.showLibrary() } label: {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable().scaledToFit().frame(width: 24, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("Open Lumen")
                HUDAction(title: "Settings", icon: "slider.horizontal.3", action: openSettings)
                Spacer(minLength: 0)
                HUDAction(title: "Record", icon: "record.circle") { app.toggle() }
            } else if case .countdown(let number) = app.phase {
                PixelWait()
                Text("Starting in \(number)").font(AppType.label).monospacedDigit()
                Spacer(minLength: 0)
            } else if app.phase == .recording {
                Button { app.showLibrary() } label: {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable().interpolation(.high).scaledToFit().frame(width: 24, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("Open Lumen")
                Button(action: openSettings) { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).accessibilityLabel("Capture settings")
                Text(time(app.stats?.elapsed ?? 0))
                    .font(AppType.label).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: time(app.stats?.elapsed ?? 0))
                    .frame(width: 56, alignment: .leading)
                RecordingLevelTape(meter: app.recordingMeter, paused: app.paused)
                Spacer(minLength: 0)
                HUDAction(title: app.paused ? "Resume" : "Pause", icon: app.paused ? "play.fill" : "pause.fill") {
                    app.togglePause()
                }
                HUDAction(title: "Stop", icon: "stop.fill") { app.toggle() }
            } else {
                PixelWait()
                Text(app.phase == .finishing ? "Saving…" : "Preparing…").font(AppType.label)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(Tok.text)
        .padding(.horizontal, Space.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .blur(radius: reduceMotion || presentation.visible ? 0 : 6)
        .opacity(presentation.visible ? 1 : 0)
        .animation(reduceMotion ? nil : Motion.route, value: presentation.visible)
        .id(sceneKey)
        .transition(reduceMotion ? .opacity : .modifier(active: HUDFade(blur: 6, opacity: 0),
                                                         identity: HUDFade(blur: 0, opacity: 1)))
        .animation(reduceMotion ? nil : Motion.route, value: sceneKey)
    }

    private var sceneKey: String {
        switch app.phase {
        case .idle: "idle"
        case .preparing: "preparing"
        case .countdown(let number): "countdown-\(number)"
        case .recording: "recording"
        case .finishing: "finishing"
        }
    }

    private func time(_ value: Double) -> String {
        let seconds = value.isFinite ? max(Int(value), 0) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct HUDFade: ViewModifier {
    let blur: CGFloat
    let opacity: Double
    func body(content: Content) -> some View { content.blur(radius: blur).opacity(opacity) }
}

private struct HUDAction: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s1) {
                Image(systemName: icon)
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(AppType.label)
            .foregroundStyle(Tok.text)
            .padding(.horizontal, Space.s2)
            .frame(height: Space.s8)
            .background(Capsule().fill(hovered ? Tok.surface : Tok.washStrong))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside
            if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .pointerStyle(.link)
        .animation(reduceMotion ? nil : (hovered ? Motion.hoverIn : Motion.hoverOut), value: hovered)
        .accessibilityLabel(title)
    }
}

private struct RecordingLevelTape: View {
    let meter: RecordingMeter
    let paused: Bool
    @State private var history: [Int] = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
        Canvas { context, size in
            let columns = 24, cell: CGFloat = 2, pitch: CGFloat = 3
            let values = paused ? [] : history
            let offset = columns - values.count
            for column in 0..<columns {
                let magnitude = column >= offset ? values[column - offset] : 0
                for row in 0..<7 {
                    let active = magnitude > 0 && abs(row - 3) <= magnitude
                    let rect = CGRect(x: CGFloat(column) * pitch, y: CGFloat(row) * pitch, width: cell, height: cell)
                    if active || row == 3 {
                        context.fill(Path(rect), with: .color(active ? Tok.accent : Tok.controlPressed),
                                     style: FillStyle(antialiased: false))
                    }
                }
            }
        }
        .frame(width: 72, height: 20)
        .onChange(of: timeline.date) { _, date in
            let value = meter.level
            let db = value > 0 && value.isFinite ? 20 * log10(Double(value)) : -100
            let magnitude = db <= -54 ? (Int(date.timeIntervalSinceReferenceDate * 10) % 4 == 0 ? 1 : 0) : min(3, max(1, Int(((db + 54) / 48 * 3).rounded(.up))))
            history = Array((history + [magnitude]).suffix(24))
        }
        }
        .accessibilityElement()
        .accessibilityLabel("Audio level")
        .accessibilityValue(paused ? "Paused" : meter.level > 0.002 ? "Sound detected" : "Quiet")
    }
}
