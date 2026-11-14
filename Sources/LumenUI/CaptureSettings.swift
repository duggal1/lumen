import AppKit
import AVFoundation
import SwiftUI
import LumenCapture

@MainActor final class CaptureSettingsController {
    private let panel: NSPanel

    init(_ app: AppModel) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Capture settings"
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        let content = NSHostingView(rootView: CaptureSettingsView(app: app))
        content.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            content.topAnchor.constraint(equalTo: blur.topAnchor),
            content.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])
        panel.contentView = blur
        panel.center()
    }

    func show() { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
}

private struct CaptureSettingsView: View {
    @Bindable var app: AppModel

    var body: some View {
        Form {
            Picker("Source", selection: $app.kind) {
                Text("Display").tag(AppModel.SourceKind.display)
                Text("Window").tag(AppModel.SourceKind.window)
                Text("Area").tag(AppModel.SourceKind.region)
            }
            if app.kind == .display {
                Picker("Display", selection: $app.displayID) {
                    ForEach(app.displays, id: \.id) { display in Text(display.name).tag(display.id) }
                }
            } else if app.kind == .window {
                Picker("Window", selection: $app.windowID) {
                    ForEach(app.windows, id: \.id) { window in Text(window.name).tag(window.id) }
                }
            } else {
                Text("Choose an area when recording starts.").foregroundStyle(.secondary)
            }
            Picker("Resolution", selection: $app.captureResolution) {
                Text("Native").tag(RecordingConfig.Resolution.native)
                Text("8K").tag(RecordingConfig.Resolution.eightK)
                Text("4K").tag(RecordingConfig.Resolution.ultraHD)
                Text("2K").tag(RecordingConfig.Resolution.twoK)
                Text("1080p").tag(RecordingConfig.Resolution.p1080)
                Text("720p").tag(RecordingConfig.Resolution.p720)
            }
            Picker("Frame rate", selection: $app.fps) {
                ForEach(app.supportedFPS, id: \.self) { Text("\($0) fps").tag($0) }
            }
            Picker("Quality", selection: $app.captureQuality) {
                Text("Standard").tag(RecordingConfig.Quality.standard)
                Text("High").tag(RecordingConfig.Quality.high)
                Text("Ultra HD").tag(RecordingConfig.Quality.ultraHD)
                Text("Blu-ray").tag(RecordingConfig.Quality.bluray)
            }
            Toggle("Microphone", isOn: $app.mic)
            if app.mic {
                Picker("Microphone device", selection: $app.micDeviceID) {
                    Text("System default").tag("")
                    ForEach(AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
            }
            Toggle("System audio", isOn: $app.system)
            Toggle("Webcam", isOn: $app.webcam)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.top, 20)
        .onAppear { app.refresh() }
    }
}
