import SwiftUI
import AVFoundation
import LumenCapture

public struct LibraryRoot: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    public init(_ app: AppModel) { self.app = app }

    public var body: some View {
        MenuRoot {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(text: "Lumen").padding(.horizontal, 32).frame(height: 52, alignment: .center)
                HStack(alignment: .top, spacing: 32) {
                    VStack(spacing: 16) { permissions; record }.frame(width: 340)
                    projectList
                }.padding(32)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Tok.bg)
        }
        .frame(minWidth: 880, minHeight: 560)
        .onAppear { app.onFinished = { openWindow(value: $0) } }
    }

    private var record: some View {
        VStack(alignment: .leading, spacing: 0) {
            if app.phase != .idle {
                Text(app.recordingStatus).font(AppType.title).foregroundStyle(Tok.text).padding(.bottom, 16)
                if app.phase == .recording {
                    LButton(title: "Show recording controls", icon: "rectangle.on.rectangle", kind: .secondary) {
                        app.showRecordingControls()
                    }.padding(.bottom, 16)
                }
            }
            LSegmented(sel: Bindable(app).kind, items: AppModel.SourceKind.allCases.map { ($0, $0.rawValue.capitalized) }).padding(.bottom, 8)
            switch app.kind {
            case .display:
                Row(label: "Display", icon: "display") { LDropdown(sel: Bindable(app).displayID, options: app.displays.map { ($0.id, $0.name, "display") }).frame(width: 160) }
            case .window:
                Row(label: "Window", icon: "macwindow") { LDropdown(sel: Bindable(app).windowID, options: app.windows.map { ($0.id, $0.name, "macwindow") }).frame(width: 160) }
            case .region:
                Row(label: "Region", icon: "viewfinder") { Text("Drag after Record").font(AppType.caption).foregroundStyle(Tok.text2) }
            }
            Row(label: "Frame rate", icon: "speedometer") { LSegmented(sel: Bindable(app).fps, items: [(30, "30"), (60, "60"), (120, "120")]).frame(width: 140) }
            Row(label: "Microphone", icon: "mic") { LToggle(on: Bindable(app).mic, label: "Microphone") }
            Row(label: "System audio", icon: "speaker.wave.2") { LToggle(on: Bindable(app).system, label: "System audio") }
            Row(label: "Webcam", icon: "camera") { LToggle(on: Bindable(app).webcam, label: "Webcam") }
            Row(label: "Live preview", icon: "bolt") { LToggle(on: Bindable(app).livePreview, label: "Live preview") }
            LButton(title: app.phase == .idle ? "Record" : "Stop", icon: app.phase == .idle ? "record.circle" : "stop.fill", kind: .primary, height: 32) { app.toggle() }
                .padding(.top, 8).disabled(app.phase != .idle && app.phase != .recording)
            if let e = app.error {
                HStack { Text(e).font(AppType.caption).foregroundStyle(Tok.statusBad); Spacer(); LButton(title: "Retry", kind: .quiet) { app.toggle() } }.padding(.top, 8)
            }
        }.card()
    }

    private var permissions: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let rows: [(String, Bool, () -> Void, String)] = [
                ("Screen Recording", Permissions.screen, { Permissions.requestScreen(); Permissions.open("ScreenCapture") }, "ScreenCapture"),
                ("Input Monitoring", Permissions.input, { Permissions.requestInput(); Permissions.open("ListenEvent") }, "ListenEvent"),
                ("Microphone", Permissions.mic, { Task { await Permissions.requestMedia() } }, "Microphone"),
                ("Accessibility (optional)", Permissions.accessibility, { Permissions.requestAccessibility(); Permissions.open("Accessibility") }, "Accessibility"),
            ]
            if rows.contains(where: { !$0.1 }) {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.0) { r in
                        HStack(spacing: 12) {
                            PixelBitmap(rows: r.1 ? Bitmap.check : Bitmap.bang, cell: 2, color: r.1 ? Tok.statusOK : Tok.text2).frame(width: 20)
                            Text(r.0).font(AppType.label); Spacer()
                            if !r.1 { LButton(title: "Grant", kind: .secondary, height: 24, action: r.2) }
                        }.frame(minHeight: 40)
                    }
                }.card()
            }
        }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recordings").font(AppType.title)
            if app.projects.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    PixelStop(cell: 4)
                    Text("Nothing here yet. Press ⌘⇧R to record.").font(AppType.body).foregroundStyle(Tok.text2)
                }.padding(.top, 24)
            } else {
                ScrollView { VStack(spacing: 2) { ForEach(app.projects) { p in ProjectRowView(p: p) { openWindow(value: p.url) } } } }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ProjectRowView: View {
    let p: AppModel.ProjectRow; let open: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: open) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(AppType.label).foregroundStyle(Tok.text)
                    Text(p.size).font(AppType.caption).foregroundStyle(Tok.text2)
                }
                Spacer()
                Text(p.date.formatted(.dateTime.hour().minute())).font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
            }.padding(.horizontal, 12).frame(height: 56).background(RoundedRectangle(cornerRadius: 12).fill(hover ? Tok.control : .clear))
        }.buttonStyle(.plain).onHover { hover = $0 }.pointerStyle(.link)
    }
}

public struct MenuBarContent: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    public init(_ app: AppModel) { self.app = app }
    public var body: some View {
        if app.phase != .idle {
            Text(app.recordingStatus)
            Button("Show recording controls") { app.showRecordingControls() }
        }
        Button(app.phase == .recording ? "Stop recording" : "Start recording") { app.toggle() }.keyboardShortcut("r", modifiers: [.command, .shift])
        Button("Open Lumen") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Quit Lumen") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}