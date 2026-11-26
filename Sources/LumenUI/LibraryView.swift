import SwiftUI
import AppKit
import AVFoundation
import LumenAudio
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
            app.onShowLibrary = { openWindow(id: "library") }
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
                    WhereYouRecord(app: app)
                }
                .padding(Metrics.pagePad)
                .frame(maxWidth: Metrics.wide)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tok.bg)
        .overlay { if showRecord { recordDialog.transition(.opacity) } }
        .onDisappear { app.stopMicrophoneTest() }
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
        HStack(alignment: .center, spacing: Space.s4) {
            PageTitle(text: "Library")
            Spacer(minLength: Space.s4)
            if app.phase == .idle {
                LButton(title: "Import", icon: "square.and.arrow.down", kind: .quiet) { app.importSharedProject() }
            }
            primaryAction
        }
        .padding(.leading, 108)
        .padding(.trailing, Metrics.pagePad)
        .frame(height: Metrics.pageBar + 8, alignment: .center)
    }

    @ViewBuilder private var primaryAction: some View {
        switch app.phase {
        case .idle:
            LButton(title: "Record", icon: "record.circle", kind: permissionNotice == nil ? .primary : .secondary) {
                app.showRecordingControls()
            }
        case .recording:
            // No live clock here: the bar owns the timer. Reading `stats` in
            // this body made the hidden Library re-render at the poll rate for
            // text nobody could see.
            HStack(spacing: Space.s3) {
                PixelStop(cell: 2)
                LButton(title: "Stop", icon: "stop.fill", kind: .primary) { app.toggle() }
            }
        case .preparing:
            HStack(spacing: Space.s2) { PixelWait(); Text("Preparing…").font(AppType.body).foregroundStyle(Tok.text2) }
        case .countdown:
            EmptyView()
        case .finishing:
            HStack(spacing: Space.s2) { PixelWait(); Text(app.recordingStatus).font(AppType.body).foregroundStyle(Tok.text2) }
        }
    }

    private var subtitle: some View {
        Text("\(Int(app.recordedToday / 60)) min recorded today. Raw footage stays on this Mac.")
            .font(AppType.body).tracking(-0.1).foregroundStyle(Tok.text2)
    }

    // MARK: Permission and failure rows

    private var permissionNotice: (text: String, action: () -> Void)? {
        if !app.permissions.screen {
            return ("Screen recording is off.", { Permissions.requestScreen(); Permissions.open("ScreenCapture") })
        }
        if !app.permissions.input {
            return ("Input Monitoring is off.", { Permissions.requestInput(); Permissions.open("ListenEvent") })
        }
        if app.mic && !app.permissions.mic {
            return ("Microphone is off.", { Task { await Permissions.requestMedia() }; Permissions.open("Microphone") })
        }
        return nil
    }

    private func notice(_ text: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: Space.s3) {
            PixelSymbol("exclamationmark.triangle", size: 14).foregroundStyle(Tok.text2)
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
            PixelSymbol("clock.arrow.circlepath", size: 14).foregroundStyle(Tok.activity)
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
                Tok.modalScrim.ignoresSafeArea().onTapGesture { showRecord = false }
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(alignment: .top, spacing: 12) {
                        PixelSymbol("record.circle", size: 18).foregroundStyle(Tok.accent).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("New recording").font(AppType.title).tracking(-0.2).foregroundStyle(Tok.text)
                            Text("Choose what to capture.").font(AppType.caption).foregroundStyle(Tok.text2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 16)

                    // Tab control (fixed)
                    LSegmented(sel: $recordTab, items: RecordTab.allCases.map { ($0, tabTitle($0)) })
                        .frame(height: 32)
                        .fixedSize(horizontal: false, vertical: true)
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
                        .padding(.top, 2)
                    }
                    .scrollIndicators(.hidden)
                    .contentMargins(.top, 0)
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
                .frame(width: min(480, max(320, geo.size.width - 48)))
                .frame(height: min(480, max(280, geo.size.height - 32)))
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
        switch t { case .capture: "Capture"; case .audio: "Inputs" }
    }

    private var captureTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            LSegmented(sel: Bindable(app).kind,
                       items: AppModel.SourceKind.allCases.map { ($0, label($0)) },
                       track: Tok.control, thumb: Tok.controlPressed)
                .frame(height: 32)
                .fixedSize(horizontal: false, vertical: true)
            switch app.kind {
            case .display:
                field("Display", icon: "display") {
                    LDropdown(sel: Bindable(app).displayID,
                              options: app.displays.map { ($0.id, $0.name, "display") })
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .window:
                field("Window", icon: "macwindow") {
                    LDropdown(sel: Bindable(app).windowID,
                              options: app.windows.map { ($0.id, $0.name, "macwindow") })
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .region:
                Text("Drag to choose an area after you press Record.").font(AppType.caption).foregroundStyle(Tok.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Row(label: "Frame rate", icon: "speedometer") {
                LSegmented(sel: Bindable(app).fps, items: app.supportedFPS.map { ($0, "\($0)") },
                           track: Tok.control, thumb: Tok.controlPressed)
                    .frame(width: 180)
            }
            Row(label: "Resolution", icon: "rectangle.ratio.16.to.9") {
                LDropdown(sel: Bindable(app).captureResolution,
                          options: RecordingConfig.Resolution.allCases.map { ($0, resolutionTitle($0), resolutionIcon($0)) })
                    .frame(width: 180)
            }
            Text(resolutionReadout).font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
                .contentTransition(.numericText())
            Row(label: "Quality", icon: "dial.high") {
                LDropdown(sel: Bindable(app).captureQuality,
                          options: RecordingConfig.Quality.offered.map { ($0, qualityTitle($0), qualityIcon($0)) })
                    .frame(width: 180)
            }
            Text(qualityReadout).font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
                .contentTransition(.numericText())
            Text(preview).font(AppType.caption).foregroundStyle(Tok.text2)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Capture copy and estimates, in real numbers

    private func resolutionTitle(_ r: RecordingConfig.Resolution) -> String {
        switch r {
        case .native: "Native"
        case .eightK: "8K"
        case .ultraHD: "4K"
        case .twoK: "2K"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }

    private func resolutionIcon(_ r: RecordingConfig.Resolution) -> String {
        switch r {
        case .native: "display"
        case .eightK, .ultraHD: "4k.tv"
        case .twoK, .p1080, .p720: "tv"
        }
    }

    private func qualityTitle(_ q: RecordingConfig.Quality) -> String {
        switch q {
        case .standard: "Standard"
        case .high: "High"
        case .ultraHD: "Ultra HD"
        case .bluray: "Blu-ray"
        case .custom: "Custom"
        }
    }

    private func qualityIcon(_ q: RecordingConfig.Quality) -> String {
        switch q {
        case .standard: "dial.low"
        case .high: "dial.medium"
        case .ultraHD: "dial.high"
        case .bluray: "dial.high.fill"
        case .custom: "slider.horizontal.3"
        }
    }

    /// Native pixels of the capture source, capped by the chosen preset.
    private var capturePixels: (w: Int, h: Int) {
        let did = app.displayID
        let dw = max(Int(CGDisplayPixelsWide(did)), 64)
        let dh = max(Int(CGDisplayPixelsHigh(did)), 64)
        let cap = app.captureResolution.resolutionHeight
        guard dh > cap else { return (dw & ~1, dh & ~1) }
        let s = Double(cap) / Double(dh)
        return (max(Int((Double(dw) * s).rounded()) & ~1, 64), cap & ~1)
    }

    private var resolutionReadout: String {
        if app.kind == .window { return "The window's native pixels, capped at \(resolutionTitle(app.captureResolution))." }
        let p = capturePixels
        let mp = Double(p.w * p.h) / 1_000_000
        let isCapped = Int(CGDisplayPixelsHigh(app.displayID)) > app.captureResolution.resolutionHeight
        let under4K = app.captureResolution == .ultraHD && p.h < 2160
        let detail = under4K ? " · native source below 4K" : (isCapped ? " · source capped" : " · native")
        return "\(p.w) × \(p.h) · \(String(format: "%.1f", mp)) MP" + detail
    }

    private var qualityReadout: String {
        let bpp = app.captureQuality.bitsPerPixel
        if app.kind == .window { return "HEVC · bitrate follows the window size." }
        guard bpp > 0 else { return "HEVC · \(Int(app.captureMbps)) Mbps" }
        let p = capturePixels
        let mbps = min(Double(p.w * p.h) * Double(app.fps) * bpp, 250_000_000) / 1_000_000
        return "HEVC · ≈ \(Int(mbps.rounded())) Mbps at \(app.fps) fps"
    }

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            compactToggle("Microphone", icon: "mic", Bindable(app).mic)
            compactToggle("System audio", icon: "speaker.wave.2", Bindable(app).system)
            compactToggle("Webcam", icon: "video", Bindable(app).webcam)
            if app.webcam {
                HStack(spacing: Space.s4) {
                    PixelSymbolLabel("Webcam quality", symbol: "camera.aperture")
                        .font(AppType.label).foregroundStyle(Tok.text)
                    Spacer(minLength: Space.s4)
                    LSegmented(sel: Bindable(app).webcamQuality, items: WebcamQuality.allCases.map { ($0, $0.title) },
                               track: Tok.control, thumb: Tok.controlHover)
                        .frame(width: 220)
                }
                .frame(height: 48)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private func compactToggle(_ label: String, icon: String, _ on: Binding<Bool>) -> some View {
        HStack(spacing: Space.s4) {
            PixelSymbolLabel(label, symbol: icon).font(AppType.label).foregroundStyle(Tok.text)
            Spacer(minLength: Space.s4)
            LToggle(on: on, label: label)
        }
        .frame(height: 48)
    }

    private func field<C: View>(_ label: String, icon: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            PixelSymbolLabel(label, symbol: icon).font(AppType.caption).foregroundStyle(Tok.text2)
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
