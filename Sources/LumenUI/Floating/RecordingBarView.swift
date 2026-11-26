import SwiftUI
import AppKit
import LumenCapture

/// Which secondary panel the bar should open, and where its trigger sits in
/// the bar window's coordinate space.
struct BarAnchor: Equatable {
    var id: String
    var rect: CGRect
}

private struct AnchorKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The floating recorder. One white glass bar, three capture modes on the
/// left, the three inputs in the middle, settings on the right, record last.
struct FloatingBarView: View {
    let app: AppModel
    var onOptions: (BarAnchor) -> Void
    var onRecord: () -> Void
    var onStop: () -> Void
    var onPause: () -> Void
    var onDiscard: () -> Void
    var onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .animation(reduceMotion ? nil : Motion.floatingTransition, value: app.phase)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(SizeReader())
            .onPreferenceChange(BarSizeKey.self) { size in
                // SwiftUI can deliver a preference from a non-main thread; the
                // window is main-actor only, and touching its geometry off main
                // raises. Hop, always.
                Task { @MainActor in FloatingBarController.current?.resizeBar(size) }
            }
            .fixedSize()
    }

    @ViewBuilder private var content: some View {
        switch app.phase {
        case .idle: idleBar.transition(.opacity)
        case .preparing: busyBar("Getting ready").transition(.opacity)
        case .countdown: countdownBar.transition(.opacity)
        case .recording: recordingBar.transition(.opacity)
        case .finishing: busyBar(app.finalizeProgress > 0 ? "Saving \(Int(app.finalizeProgress * 100))%" : "Saving").transition(.opacity)
        }
    }

    // MARK: Idle

    private var idleBar: some View {
        HStack(spacing: 3) {
            BarItem(id: "screen", icon: "display", title: "Screen",
                    active: app.kind == .display) { select(.display) }
            BarItem(id: "window", icon: "macwindow", title: "Window",
                    active: app.kind == .window) { select(.window) }
            BarItem(id: "area", icon: "rectangle.dashed", title: "Area",
                    active: app.kind == .region,
                    options: { anchor in onOptions(anchor) }) { select(.region) }

            gap

            BarItem(id: "camera", icon: app.webcam ? "video" : "video.slash", title: "Camera",
                    active: app.webcam, options: { anchor in onOptions(anchor) }) { app.webcam.toggle() }
            BarItem(id: "microphone", icon: app.mic ? "mic" : "mic.slash", title: "Mic",
                    active: app.mic, options: { anchor in onOptions(anchor) }) { app.mic.toggle() }
            BarItem(id: "system-audio", icon: "speaker.wave.2", title: "System",
                    active: app.system) { app.system.toggle() }

            gap

            BarItem(id: "settings", icon: "gearshape", title: "Settings", panel: { anchor in
                onOptions(anchor)
            })

            Spacer(minLength: 6)

            RecordButton(action: onRecord)
        }
    }

    private var gap: some View { Color.clear.frame(width: 10, height: 1) }

    private func select(_ kind: AppModel.SourceKind) {
        guard app.kind != kind else { return }
        app.kind = kind
        switch kind {
        case .window: FloatingBarController.current?.present(options: "window", in: app)
        case .region: FloatingBarController.current?.selectArea(openPicker: app.lastArea == nil)
        case .display: break
        }
    }

    // MARK: Recording

    private var recordingBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle()
                    .fill(app.paused ? Tok.text2 : Tok.accent)
                    .frame(width: 8, height: 8)
                Text(time(app.stats?.elapsed ?? 0))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(Tok.text)
                    .frame(width: 54, alignment: .leading)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.2), value: Int(app.stats?.elapsed ?? 0))
            }
            LevelTape(meter: app.recordingMeter, paused: app.paused)
            RecorderAction(title: app.paused ? "Resume" : "Pause",
                           icon: app.paused ? "play.fill" : "pause.fill",
                           accessibilityLabel: app.paused ? "Resume recording" : "Pause recording",
                           action: onPause)
            RecorderAction(title: "Stop", icon: "stop.fill",
                           accessibilityLabel: "Stop recording", action: onStop)
            DiscardButton(action: onDiscard)
        }
    }

    private var countdownBar: some View {
        HStack(spacing: 10) {
            Text("Starting in \(number)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tok.text)
            Spacer(minLength: 4)
            QuietPill(title: "Cancel", action: onCancel)
        }
        .frame(width: 218)
    }

    private var number: Int {
        if case .countdown(let n) = app.phase { return n }
        return 0
    }
    private func busyBar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tok.text)
            Spacer(minLength: 4)
            QuietPill(title: "Cancel", action: onCancel)
        }
        .frame(width: 218)
    }

    private func time(_ value: Double) -> String {
        let seconds = value.isFinite ? max(Int(value), 0) : 0
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Bar size plumbing

private struct BarSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 { value = next }
    }
}

private struct SizeReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: BarSizeKey.self, value: proxy.size)
        }
    }
}

// MARK: - Items

private struct BarItem: View {
    let id: String
    let icon: String
    let title: String
    var active = false
    var options: ((BarAnchor) -> Void)?
    let action: () -> Void
    /// Items whose click is a plain action (settings) pass the anchor directly.
    var directAnchor = false
    @State private var hover = false
    @FocusState private var focused: Bool
    @State private var anchor = CGRect.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(id: String, icon: String, title: String, active: Bool = false,
         options: ((BarAnchor) -> Void)? = nil, action: @escaping () -> Void) {
        self.id = id; self.icon = icon; self.title = title; self.active = active
        self.options = options; self.action = action
    }

    /// Settings-style item: the whole button opens a panel.
    init(id: String, icon: String, title: String, panel: @escaping (BarAnchor) -> Void) {
        self.id = id; self.icon = icon; self.title = title
        self.active = false
        self.options = panel
        self.action = {}
        self.directAnchor = true
    }

    var body: some View {
        Button {
            if directAnchor, let options { options(BarAnchor(id: id, rect: anchor)) }
            else { action() }
        } label: {
            VStack(spacing: 5) {
                PixelSymbol(icon, size: 17)
                    .foregroundStyle(active ? Tok.text : Tok.text.opacity(0.88))
                    .frame(height: 19)
                Text(title)
                    .font(.system(size: 10.5, weight: active ? .medium : .regular))
                    .tracking(0.1)
                    .lineLimit(1)
                    .foregroundStyle(active ? Tok.text : Tok.text.opacity(0.88))
            }
            .frame(width: 58, height: 54)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(active
                          ? ((hover || focused) ? Tok.floatingSelectedHover : Tok.floatingSelected)
                          : (hover || focused) ? Tok.floatingHover : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .floatingHandCursor()
        .onHover { inside in
            hover = inside
        }
        .overlay(alignment: .topTrailing) {
            if let options, !directAnchor {
                Button {
                    options(BarAnchor(id: id, rect: anchor))
                } label: {
                    PixelSymbol("chevron.down", size: 8)
                        .foregroundStyle(Tok.text2)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .floatingHandCursor()
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
                .accessibilityLabel("\(title) options")
                .animation(reduceMotion ? nil : Motion.floatingHighlight, value: hover)
                .offset(x: 1, y: -1)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: AnchorKey.self, value: [id: proxy.frame(in: .global)])
            }
        )
        .onPreferenceChange(AnchorKey.self) { if let r = $0[id] { anchor = r } }
        .animation(reduceMotion ? nil : Motion.floatingHighlight, value: active)
        .animation(reduceMotion ? nil : Motion.floatingHighlight, value: hover)
        .animation(reduceMotion ? nil : Motion.floatingHighlight, value: focused)
        .accessibilityLabel(title)
        .accessibilityValue(active ? "On" : "Off")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct RecordButton: View {
    let action: () -> Void

    var body: some View {
        RecorderAction(title: "Record", icon: "record.circle",
                       accessibilityLabel: "Start recording", emphasized: true, action: action)
    }
}

/// The recorder's compact transport action. This keeps the labeled capsule
/// used by the original HUD in both idle and recording states.
private struct RecorderAction: View {
    let title: String
    let icon: String
    let accessibilityLabel: String
    var emphasized = false
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s1) {
                PixelSymbol(icon, size: 14)
                Text(title)
                    .font(AppType.label)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(Tok.text)
            .padding(.horizontal, Space.s2)
            .frame(height: Space.s8)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .floatingHandCursor()
        .onHover { inside in
            hovered = inside
        }
        .animation(reduceMotion ? nil : Motion.floatingHighlight, value: hovered)
        .animation(reduceMotion ? nil : Motion.floatingHighlight, value: focused)
        .accessibilityLabel(accessibilityLabel)
    }

    private var background: Color {
        if emphasized {
            return hovered || focused ? Tok.floatingSelectedHover : Tok.floatingSelected
        }
        return hovered || focused ? Tok.floatingHover : Tok.floatingRest
    }
}

private struct DiscardButton: View {
    let action: () -> Void
    @State private var armed = false
    @State private var hover = false
    var body: some View {
        Button {
            if armed { action() } else {
                armed = true
                Task { try? await Task.sleep(for: .seconds(3)); armed = false }
            }
        } label: {
            Group {
                if armed {
                    Text("Discard").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Tok.statusBad)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Tok.washStrong))
                } else {
                    PixelSymbol("trash", size: 13)
                        .foregroundStyle(hover ? Tok.text : Tok.text2)
                        .frame(width: 26, height: 26)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .floatingHandCursor()
        .onHover { inside in
            hover = inside
        }
        .accessibilityLabel(armed ? "Confirm discard" : "Discard recording")
    }
}

private struct QuietPill: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hover ? Tok.text : Tok.text2)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(hover ? Tok.washStrong : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .floatingHandCursor()
        .onHover { inside in
            hover = inside
        }
        .accessibilityLabel(title)
    }
}
