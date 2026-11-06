import SwiftUI
import AppKit
import AVFoundation
import LumenCapture
import LumenProject

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
    private enum RecordTab: Int, CaseIterable, Hashable { case capture, audio }
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
                    ForEach(app.recoverable, id: \.url) { bundle in recovery(bundle) }
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
        .animation(Motion.settle, value: undo?.id)
    }

    // MARK: Page bar

    private var pageBar: some View {
        HStack(alignment: .bottom, spacing: Space.s4) {
            PageTitle(text: "Library")
            Spacer(minLength: Space.s4)
            if app.phase == .idle {
                LButton(title: "Import", icon: "square.and.arrow.down", kind: .quiet) { app.importSharedProject() }
            }
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
        case .countdown:
            EmptyView()
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

    /// A recording that crashed before the project was written. The journal has
    /// the frames on disk; recovery rebuilds the timeline around them.
    private func recovery(_ bundle: ProjectBundle) -> some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).foregroundStyle(Tok.activity)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unfinished recording").font(AppType.label).foregroundStyle(Tok.text)
                Text(bundle.url.deletingPathExtension().lastPathComponent)
                    .font(AppType.caption).foregroundStyle(Tok.text2).lineLimit(1)
            }
            Spacer(minLength: Space.s4)
            LButton(title: "Discard", kind: .quiet, height: 24) { app.discardRecovery(bundle) }
            LButton(title: "Recover", icon: "arrow.clockwise", kind: .primary, height: 24) { app.recover(bundle) }
        }
        .padding(.horizontal, Space.s3)
        .frame(minHeight: 44)
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

    @State private var recordTab: RecordTab = .capture

    private var recordDialog: some View {
        GeometryReader { geo in
            ZStack {
                Tok.modalScrim.ignoresSafeArea().onTapGesture { }
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(alignment: .top, spacing: 12) {
                        PixelLens(cell: 2).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("New recording").font(AppType.title).tracking(-0.2).foregroundStyle(Tok.text)
                            Text("Choose what to capture.").font(AppType.caption).foregroundStyle(Tok.text2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 16)

                    // Tab control (fixed)
                    LSegmented(sel: $recordTab, items: RecordTab.allCases.map { ($0, tabTitle($0)) })
                        .frame(height: 24)
                        .padding(.bottom, 16)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Recording sections")

                    // Only mount the selected tab. Hidden tabs must not impose their height.
                    ScrollView {
                        Group {
                            if recordTab == .capture { captureTab }
                            else { audioTab }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)

                    // Footer pinned
                    HStack(spacing: 8) {
                        Spacer()
                        LButton(title: "Cancel", kind: .secondary, height: 32, action: { showRecord = false })
                        LButton(title: "Record", kind: .primary, height: 32, action: { showRecord = false; app.toggle() })
                            .disabled(!canRecord)
                    }
                    .padding(.top, 16)
                }
                .padding(20)
                .frame(width: min(520, max(320, geo.size.width - 32)))
                .frame(height: min(recordTab == .audio ? 480 : 400, max(280, geo.size.height - 32)))
                .background(RoundedRectangle(cornerRadius: Radius.card).fill(Tok.surface))
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onAppear { recordTab = lastRecordTab }
        .onDisappear { lastRecordTab = recordTab }
        .onKeyPress { press in
            if press.modifiers.contains(.command) {
                if press.key == "1" { recordTab = .capture; return .handled }
                if press.key == "2" { recordTab = .audio; return .handled }
                if press.key == .return { if canRecord { showRecord = false; app.toggle() }; return .handled }
            }
            if press.key == .leftArrow { moveRecordTab(-1); return .handled }
            if press.key == .rightArrow { moveRecordTab(1); return .handled }
            if press.key == .escape { showRecord = false; return .handled }
            return .ignored
        }
        .accessibilityAddTraits(.isModal)
    }

    @State private var lastRecordTab: RecordTab = .capture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func moveRecordTab(_ d: Int) {
        let cases = RecordTab.allCases
        guard let i = cases.firstIndex(of: recordTab) else { return }
        let j = (i + d + cases.count) % cases.count
        recordTab = cases[j]
    }

    private func tabTitle(_ t: RecordTab) -> String {
        switch t { case .capture: "Capture"; case .audio: "Audio" }
    }

    private var captureTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            LSegmented(sel: Bindable(app).kind,
                       items: AppModel.SourceKind.allCases.map { ($0, label($0)) },
                       track: Tok.control, thumb: Tok.controlHover)
            switch app.kind {
            case .display:
                field("Display", icon: "display") {
                    LDropdown(sel: Bindable(app).displayID,
                              options: app.displays.map { ($0.id, $0.name, "display") })
                }
            case .window:
                field("Window", icon: "macwindow") {
                    LDropdown(sel: Bindable(app).windowID,
                              options: app.windows.map { ($0.id, $0.name, "macwindow") })
                }
            case .region:
                Text("Drag to choose an area after you press Record.").font(AppType.caption).foregroundStyle(Tok.text2)
            }
            HStack(spacing: Space.s4) {
                Label("Frame rate", systemImage: "speedometer")
                    .font(AppType.label).foregroundStyle(Tok.text)
                Spacer(minLength: Space.s4)
                LSegmented(sel: Bindable(app).fps, items: [(30, "30"), (60, "60"), (120, "120")],
                           track: Tok.control, thumb: Tok.controlHover)
                    .frame(width: 180)
            }
            .frame(height: 48)
            Text(preview).font(AppType.caption).foregroundStyle(Tok.text2)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            compactToggle("Microphone", icon: "mic", Bindable(app).mic)
            if app.mic {
                ForEach(app.availableAudioInputs, id: \.id) { device in
                    HStack(spacing: Space.s4) {
                        Label(device.name, systemImage: "mic.circle")
                            .font(AppType.label).foregroundStyle(Tok.text).lineLimit(1)
                        Spacer(minLength: Space.s2)
                        LToggle(on: Binding(
                            get: { app.micInputIDs.contains(device.id) },
                            set: { app.selectAudioInput(device.id, enabled: $0) }),
                            label: device.name)
                    }
                    .frame(height: 48)
                }
                Text(app.micInputIDs.isEmpty
                     ? "Using the system default microphone."
                     : app.micInputIDs.count == 1
                        ? "1 microphone selected as the primary voice."
                        : "\(app.micInputIDs.count) microphones captured independently; first is primary.")
                    .font(AppType.caption).foregroundStyle(Tok.text2)
            }
            compactToggle("System audio", icon: "speaker.wave.2", Bindable(app).system)
            compactToggle("Webcam", icon: "video", Bindable(app).webcam)
            if app.webcam {
                HStack(spacing: Space.s4) {
                    Label("Webcam quality", systemImage: "camera.aperture")
                        .font(AppType.label).foregroundStyle(Tok.text)
                    Spacer(minLength: Space.s4)
                    LSegmented(sel: Bindable(app).webcamQuality, items: WebcamQuality.allCases.map { ($0, $0.title) },
                               track: Tok.control, thumb: Tok.controlHover)
                        .frame(width: 220)
                }
                .frame(height: 48)
            }
            HStack(spacing: Space.s4) {
                PixelMic(cell: 2)
                Text("Microphone test").font(AppType.label).foregroundStyle(Tok.text)
                Spacer(minLength: Space.s4)
                LButton(title: app.micTesting ? "Testing…" : "Test", kind: .secondary, height: 24) { app.testMicrophone() }
                    .disabled(app.micTesting)
                PixelMeter(level: app.micTestLevel).frame(width: 80)
            }
            .frame(height: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactToggle(_ label: String, icon: String, _ on: Binding<Bool>) -> some View {
        HStack(spacing: Space.s4) {
            Label(label, systemImage: icon).font(AppType.label).foregroundStyle(Tok.text)
            Spacer(minLength: Space.s4)
            LToggle(on: on, label: label)
        }
        .frame(height: 48)
    }

    private func field<C: View>(_ label: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Label(label, systemImage: icon).font(AppType.caption).foregroundStyle(Tok.text2)
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
        if app.phase == .recording {
            Button(app.paused ? "Resume recording" : "Pause recording") { app.togglePause() }
                .keyboardShortcut("p", modifiers: [.option, .command])
        }
        Button(app.phase == .recording ? "Stop recording" : "Start recording") { app.toggle() }
            .keyboardShortcut("r", modifiers: [.option, .command])
        Button("Open Lumen") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit Lumen") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
