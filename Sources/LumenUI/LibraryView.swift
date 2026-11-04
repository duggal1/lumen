import SwiftUI
import AppKit
import AVFoundation
import LumenCapture

public struct LibraryRoot: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    public init(_ app: AppModel) { self.app = app }

    public var body: some View {
        MenuRoot {
            LumenShell(app)
        }
        .onAppear {
            Appearance.apply()
            app.onFinished = { openWindow(value: $0) }
        }
    }
}

struct LibrarySurface: View {
    let app: AppModel
    @Environment(MenuHost.self) private var menu
    @Environment(\.openWindow) private var openWindow
    @State private var showRecord = false
    @State private var undo: PendingDelete?
    @State private var undoTask: Task<Void, Never>?

    private struct PendingDelete: Identifiable {
        let id = UUID()
        let row: AppModel.ProjectRow
        let trashURL: URL
    }

    var body: some View {
        VStack(spacing: 0) {
            pageBar
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    subtitle
                    if let problem = permissionNotice { notice(problem.text, action: problem.action) }
                    if let error = app.error { failure(error) }
                    LedgerCard(app: app)
                    ActivityCard(app: app)
                    RecentRecordings(app: app, open: open, reveal: reveal, delete: delete)
                    WhereYouRecord()
                }
                .padding(Metrics.pagePad)
                .frame(maxWidth: Metrics.wide, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tok.bg)
        .overlay { if showRecord { recordDialog.transition(.opacity) } }
        .overlay(alignment: .bottom) {
            if let undo {
                UndoToast(text: "Deleted \(undo.row.name).", actionTitle: "Undo") { restore(undo) }
                    .padding(.bottom, Space.s6)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: undo?.id)
    }

    // MARK: Page bar

    private var pageBar: some View {
        HStack(alignment: .bottom, spacing: Space.s4) {
            PageTitle(text: "Library")
            Spacer(minLength: Space.s4)
            primaryAction
        }
        .padding(.horizontal, Metrics.pagePad)
        .frame(height: Metrics.pageBar, alignment: .bottom)
    }

    @ViewBuilder private var primaryAction: some View {
        switch app.phase {
        case .idle:
            LButton(title: "Record", icon: "record.circle", kind: permissionNotice == nil ? .primary : .secondary) {
                showRecord = true
            }
        case .recording:
            HStack(spacing: Space.s3) {
                PixelStop(cell: 2)
                Text(time(app.stats?.elapsed ?? 0)).font(AppType.label.monospacedDigit()).foregroundStyle(Tok.text)
                LButton(title: "Stop", icon: "stop.fill", kind: .primary) { app.toggle() }
            }
        case .preparing:
            HStack(spacing: Space.s2) { PixelWait(); Text("Preparing…").font(AppType.body).foregroundStyle(Tok.text2) }
        case .countdown(let n):
            Text("Starting in \(n)").font(AppType.label).foregroundStyle(Tok.text)
        case .finishing:
            HStack(spacing: Space.s2) { PixelWait(); Text("Saving…").font(AppType.body).foregroundStyle(Tok.text2) }
        }
    }

    private var subtitle: some View {
        Text("\(Int(app.recordedToday / 60)) min recorded today. Raw footage stays on this Mac.")
            .font(AppType.body).tracking(-0.1).foregroundStyle(Tok.text2)
    }

    // MARK: Permission and failure rows

    private var permissionNotice: (text: String, action: () -> Void)? {
        if !Permissions.screen {
            return ("Screen recording is off.", { Permissions.requestScreen(); Permissions.open("ScreenCapture") })
        }
        if !Permissions.input {
            return ("Input Monitoring is off.", { Permissions.requestInput(); Permissions.open("ListenEvent") })
        }
        if app.mic && !Permissions.mic {
            return ("Microphone is off.", { Task { await Permissions.requestMedia() }; Permissions.open("Microphone") })
        }
        return nil
    }

    private func notice(_ text: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 14)).foregroundStyle(Tok.text2)
            Text(text).font(AppType.label).foregroundStyle(Tok.text)
            Spacer(minLength: Space.s4)
            LButton(title: "Open Settings", kind: .primary, height: 24, action: action)
        }
        .padding(.horizontal, Space.s3)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Radius.nested).fill(Tok.control))
    }

    private func failure(_ error: String) -> some View {
        HStack(spacing: Space.s3) {
            PixelBitmap(rows: Bitmap.failed, cell: 2, color: Tok.statusBad)
            Text(error).font(AppType.body).foregroundStyle(Tok.statusBad).lineLimit(2)
            Spacer(minLength: Space.s4)
            LButton(title: "Retry", kind: .quiet, height: 24) { app.error = nil; app.toggle() }
        }
        .padding(.horizontal, Space.s3)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: Radius.nested).fill(Tok.control))
    }

    // MARK: Record dialog

    private var recordDialog: some View {
        LDialog(title: "New recording", subtitle: "Choose what to capture.", confirmTitle: "Record",
                confirmEnabled: canRecord, cancel: { showRecord = false },
                confirm: { showRecord = false; app.toggle() }) {
            LSegmented(sel: Bindable(app).kind,
                       items: AppModel.SourceKind.allCases.map { ($0, label($0)) },
                       track: Tok.control, thumb: Tok.controlHover)
            switch app.kind {
            case .display:
                field("Display") {
                    LDropdown(sel: Bindable(app).displayID,
                              options: app.displays.map { ($0.id, $0.name, "display") })
                }
            case .window:
                field("Window") {
                    LDropdown(sel: Bindable(app).windowID,
                              options: app.windows.map { ($0.id, $0.name, "macwindow") })
                }
            case .region:
                Text("Drag to choose an area after you press Record.").font(AppType.caption).foregroundStyle(Tok.text2)
            }
            HStack(spacing: Space.s4) {
                Text("Frame rate").font(AppType.label).foregroundStyle(Tok.text)
                Spacer(minLength: Space.s4)
                LSegmented(sel: Bindable(app).fps, items: [(30, "30"), (60, "60"), (120, "120")],
                           track: Tok.control, thumb: Tok.controlHover)
                    .frame(width: 180)
            }
            .frame(height: 32)
            compactToggle("Microphone", Bindable(app).mic)
            compactToggle("System audio", Bindable(app).system)
            compactToggle("Webcam", Bindable(app).webcam)
            Text(preview).font(AppType.caption).foregroundStyle(Tok.text2)
                .contentTransition(.opacity)
        }
        .onAppear { menu.close() }
    }

    private func compactToggle(_ label: String, _ on: Binding<Bool>) -> some View {
        HStack(spacing: Space.s4) {
            Text(label).font(AppType.label).foregroundStyle(Tok.text)
            Spacer(minLength: Space.s4)
            LToggle(on: on, label: label)
        }
        .frame(height: 32)
    }

    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(label).font(AppType.caption).foregroundStyle(Tok.text2)
            content()
        }
    }

    private var canRecord: Bool {
        app.kind != .window || app.windowID != 0
    }

    private var preview: String {
        switch app.kind {
        case .display: return "Full display at \(app.fps) fps."
        case .window: return "The selected window at \(app.fps) fps."
        case .region: return "Drag to choose an area after you press Record."
        }
    }

    private func label(_ kind: AppModel.SourceKind) -> String {
        switch kind { case .display: "Display"; case .window: "Window"; case .region: "Area" }
    }

    // MARK: Actions

    private func open(_ url: URL) {
        openWindow(value: url)
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func delete(_ row: AppModel.ProjectRow) {
        guard let trashURL = app.trash(row) else { return }
        let pending = PendingDelete(row: row, trashURL: trashURL)
        undo = pending
        undoTask?.cancel()
        undoTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, undo?.id == pending.id else { return }
            undo = nil
        }
    }

    private func restore(_ pending: PendingDelete) {
        undoTask?.cancel()
        app.restore(pending.row, from: pending.trashURL)
        undo = nil
    }

    private func time(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
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
        Button(app.phase == .recording ? "Stop recording" : "Start recording") { app.toggle() }
            .keyboardShortcut("r", modifiers: [.option, .command])
        Button("Open Lumen") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit Lumen") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
