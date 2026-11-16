import SwiftUI
import AppKit
import AVFoundation
import LumenCapture

// MARK: - Shared panel pieces

/// A panel header, a row, and chips: the whole vocabulary of the floating
/// panels, so a menu and the settings panel are visibly the same surface.
struct PanelHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tok.text)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Tok.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 3)
    }
}

struct PanelRow: View {
    let icon: String?
    let title: String
    var detail: String?
    var selected = false
    var destructive = false
    let action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(selected ? Tok.text : Tok.text.opacity(0.82))
                        .frame(width: 18, alignment: .center)
                }
                Text(title)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(destructive ? Tok.statusBad : Tok.text.opacity(selected ? 1 : 0.88))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Tok.text2).lineLimit(1)
                }
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Tok.text)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected
                                                              ? (hover || focused ? Tok.floatingSelectedHover : Tok.floatingSelected)
                                                              : (hover || focused) ? Tok.floatingHover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .floatingHandCursor()
        .onHover { inside in
            hover = inside
        }
        .animation(reduceMotion ? nil : Motion.floatingHighlight, value: selected)
        .animation(reduceMotion ? nil : Motion.floatingHighlight, value: hover)
        .animation(reduceMotion ? nil : Motion.floatingHighlight, value: focused)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ChipRow<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { value, title in
                Chip(title: title, active: selection == value) { selection = value }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

struct Chip: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Tok.text : Tok.text.opacity(0.88))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(active
                                           ? (hover || focused ? Tok.floatingSelectedHover : Tok.floatingSelected)
                                           : (hover || focused) ? Tok.floatingHover : Tok.floatingRest))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusEffectDisabled()
        .floatingHandCursor()
        .onHover { inside in
            hover = inside
        }
        .animation(reduceMotion ? nil : Motion.floatingHighlight, value: active)
        .animation(reduceMotion ? nil : Motion.floatingHighlight, value: hover)
        .animation(reduceMotion ? nil : Motion.floatingHighlight, value: focused)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct PanelToggleRow: View {
    let title: String
    @Binding var on: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(Tok.text)
            Spacer(minLength: 8)
            LToggle(on: $on, label: title)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }
}

// MARK: - Windows

struct WindowPickerPanel: View {
    let app: AppModel
    @State private var query = ""

    private var filtered: [(id: CGWindowID, name: String, appID: String, appName: String)] {
        let all = app.windows
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.appName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Tok.text2)
                TextField("Find a window", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Tok.text)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Tok.control))
            .padding(.horizontal, 8)
            .padding(.top, 8)

            if filtered.isEmpty {
                Text(app.windows.isEmpty ? "No windows on screen." : "No window matches.")
                    .font(.system(size: 12)).foregroundStyle(Tok.text2)
                    .padding(.horizontal, 12).padding(.vertical, 14)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(filtered, id: \.id) { window in
                            PanelRow(icon: "macwindow", title: window.name, detail: window.appName,
                                     selected: app.windowID == window.id, action: {
                                app.windowID = window.id
                                app.kind = .window
                                FloatingBarController.current?.closePanels()
                            })
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 246)
            }
        }
        .frame(width: 292)
        .onAppear { Task { await app.refreshWindows() } }
    }
}

// MARK: - Camera

struct CameraPanel: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Camera")
            PanelRow(icon: "video.slash", title: "Don't record camera", selected: !app.webcam) {
                app.webcam = false
            }
            ForEach(app.cameraDevices, id: \.id) { device in
                PanelRow(icon: "video", title: device.name,
                         selected: app.webcam && app.cameraDeviceID == device.id) {
                    app.cameraDeviceID = device.id
                    app.webcam = true
                }
            }
            if app.cameraDevices.isEmpty {
                Text("No camera found.").font(.system(size: 11)).foregroundStyle(Tok.text2)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            DividerlessGap()
            Text("Max resolution").font(.system(size: 10, weight: .medium)).foregroundStyle(Tok.text2)
                .padding(.horizontal, 10).padding(.bottom, 1)
            ChipRow(items: [(WebcamQuality.auto, "Auto"), (.q4k, "4K"), (.q1080, "1080p"), (.q720, "720p")],
                    selection: Binding(get: { app.webcamQuality }, set: { app.webcamQuality = $0 }))
            DividerlessGap()
            PanelToggleRow(title: "Show camera preview", on: Binding(get: { app.showCameraPreview }, set: {
                app.showCameraPreview = $0
                CameraBubbleController.shared.setVisible($0 && app.phase == .recording)
            }))
            .padding(.bottom, 4)
        }
        .frame(width: 268)
    }
}

private struct DividerlessGap: View {
    var body: some View { Color.clear.frame(height: 8) }
}

// MARK: - Microphone

struct MicrophonePanel: View {
    let app: AppModel
    @State private var level: Float = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Microphone")
            PanelRow(icon: "mic.slash", title: "No microphone", selected: !app.mic) { app.mic = false }
            PanelRow(icon: "mic", title: "System default", selected: app.mic && app.micDeviceID.isEmpty) {
                app.micDeviceID = ""
                app.mic = true
            }
            ForEach(app.microphoneDevices, id: \.id) { device in
                PanelRow(icon: "mic", title: device.name, selected: app.mic && app.micDeviceID == device.id) {
                    app.micDeviceID = device.id
                    app.mic = true
                }
            }
            DividerlessGap()
            HStack(spacing: 8) {
                PanelRow(icon: app.micTesting ? "stop.circle" : "waveform",
                         title: app.micTesting ? "Stop test" : "Test microphone") {
                    app.testMicrophone()
                }
                MicTestMeter(level: app.micTesting ? app.micTestLevel : 0)
                    .padding(.trailing, 12)
            }
            .padding(.bottom, 4)
        }
        .frame(width: 268)
        .onDisappear { app.stopMicrophoneTest() }
    }
}

private struct MicTestMeter: View {
    let level: Float
    var body: some View {
        Canvas { context, size in
            let columns = 12, pitch: CGFloat = 4, bar: CGFloat = 2
            let lit = Int(Double(min(max(level * 4, 0), 1)) * Double(columns))
            for column in 0..<columns {
                let rect = CGRect(x: CGFloat(column) * pitch, y: (size.height - 6) / 2, width: bar, height: 6)
                context.fill(Path(rect), with: .color(column < lit ? Tok.accent : Tok.controlPressed),
                             style: FillStyle(antialiased: false))
            }
        }
        .frame(width: 46, height: 12)
        .accessibilityLabel("Microphone level")
    }
}

// MARK: - Areas

struct AreaPanel: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Area")
            PanelToggleRow(title: "Intelligent crop", on: Binding(get: { app.smartCrop.enabled },
                                                                  set: { app.smartCrop.enabled = $0 }))
            Text("Frames the page, reveals chrome while you type.").font(.system(size: 10))
                .foregroundStyle(Tok.text2).padding(.horizontal, 10).padding(.bottom, 4)
            if app.smartCrop.enabled {
                Text("Raw footage keeps the full display.").font(.system(size: 10))
                    .foregroundStyle(Tok.text2).padding(.horizontal, 10).padding(.bottom, 4)
            }
            PanelRow(icon: "rectangle.dashed", title: app.lastArea == nil ? "Select an area…" : "Select a new area…") {
                FloatingBarController.current?.selectArea(openPicker: true)
            }
            if !app.areaPresets.isEmpty {
                DividerlessGap()
                Text("Saved").font(.system(size: 10, weight: .medium)).foregroundStyle(Tok.text2)
                    .padding(.horizontal, 10).padding(.bottom, 1)
                ForEach(app.areaPresets) { preset in
                    PanelRow(icon: "rectangle", title: preset.name, detail: preset.sizeLabel,
                             selected: app.lastArea?.id == preset.id) {
                        app.lastArea = preset
                        app.kind = .region
                        FloatingBarController.current?.closePanels()
                    }
                    .contextMenu {
                        Button("Forget this area") { app.removeAreaPreset(preset.id) }
                    }
                }
            }
            DividerlessGap()
        }
        .frame(width: 268)
    }
}

// MARK: - Settings

struct CaptureSettingsPanelView: View {
    let app: AppModel
    @State private var bitrate: Double = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Capture")
            Text("Frame rate").font(.system(size: 10, weight: .medium)).foregroundStyle(Tok.text2)
                .padding(.horizontal, 10)
            ChipRow(items: [(24, "24"), (30, "30"), (60, "60"), (120, "120")],
                    selection: Binding(get: { app.fps }, set: { app.fps = $0 }))
            Text("Resolution").font(.system(size: 10, weight: .medium)).foregroundStyle(Tok.text2)
                .padding(.horizontal, 10).padding(.top, 10)
            ChipRow(items: [(RecordingConfig.Resolution.native, "Native"), (.ultraHD, "4K"),
                            (.twoK, "2K"), (.p1080, "1080p"), (.p720, "720p")],
                    selection: Binding(get: { app.captureResolution }, set: { app.captureResolution = $0 }))
            Text("Quality").font(.system(size: 10, weight: .medium)).foregroundStyle(Tok.text2)
                .padding(.horizontal, 10).padding(.top, 10)
            ChipRow(items: [(RecordingConfig.Quality.standard, "Standard"), (.high, "High"),
                            (.ultraHD, "Ultra"), (.bluray, "Blu-ray")],
                    selection: Binding(get: { app.captureQuality }, set: { app.captureQuality = $0 }))
            HStack(spacing: 10) {
                Text("Bitrate").font(.system(size: 10, weight: .medium)).foregroundStyle(Tok.text2)
                LSlider(value: Binding(get: { app.captureMbps }, set: {
                    app.captureMbps = $0
                    app.captureQuality = .custom
                }), range: 5...120, step: 1, width: 150)
                Text("\(Int(app.captureMbps)) Mbps")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Tok.text2)
            }
            .padding(.horizontal, 10).padding(.top, 10)

            DividerlessGap()
            PanelToggleRow(title: "3 second countdown",
                           on: Binding(get: { app.countdownSeconds > 0 },
                                       set: { app.countdownSeconds = $0 ? 3 : 0 }))
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Tok.text2)
                Text(app.library.lastPathComponent).font(.system(size: 11)).foregroundStyle(Tok.text).lineLimit(1)
                Spacer(minLength: 8)
                Button("Choose…") { app.chooseLibrary() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Tok.accentText)
                    .floatingHandCursor()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .padding(.bottom, 6)
        }
        .frame(width: 300)
    }
}
