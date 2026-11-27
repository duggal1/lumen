import SwiftUI
import LumenCore
import LumenProject

public struct EditorRoot: View {
    let url: URL
    @State private var model: EditorModel?
    @State private var failure: String?
    @State private var detail: String?
    @State private var attempt = 0
    public init(url: URL) { self.url = url }
    public var body: some View {
        MenuRoot {
            Group {
                if let model { EditorView(model: model) }
                else if failure != nil {
                    VStack(spacing: Space.s4) {
                        PixelSymbol("exclamationmark.circle", size: 32).foregroundStyle(Tok.text2)
                        Text("This recording can’t be opened")
                            .font(AppType.title).foregroundStyle(Tok.text)
                        Text("The video file wasn’t finished writing, so it can’t be played.")
                            .font(AppType.body).foregroundStyle(Tok.text2)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 8) {
                            LButton(title: "Back to Library", kind: .secondary, height: 32) { dismiss() }
                            LButton(title: "Reveal in Finder", kind: .secondary, height: 32) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            LButton(title: "Remove recording", kind: .quiet, height: 32) {
                                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                                dismiss()
                            }
                        }
                        DisclosureGroup("Show details") {
                            detailView
                        }
                    }
                    .frame(maxWidth: 480)
                    .padding(32)
                } else { PixelWait() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tok.bg)
            .background(WindowChrome())
        }
        .frame(minWidth: Metrics.minW, minHeight: Metrics.minH)
        .task(id: attempt) { do { model = try await EditorModel.open(url: url) } catch { failure = friendlyError(error, url: url); detail = "\(error)" } }
    }

    private var detailView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail ?? "").font(AppType.mono).foregroundStyle(Tok.text2)
                .textSelection(.enabled)
            LButton(title: "Copy", kind: .quiet, height: 24) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(detail ?? "", forType: .string)
            }
        }
    }

    private func dismiss() {
        NSApp.keyWindow?.close()
    }

    /// Plain-language copy without the raw NSError dump or the local path.
    private func friendlyError(_ error: Error, url: URL) -> String {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("damaged") || lower.contains("cannot open") || lower.contains("-11829") || lower.contains("-12848") {
            return "The video file wasn’t finished writing, so it can’t be played."
        }
        return "This recording can’t be opened right now."
    }
}

struct EditorView: View {
    let model: EditorModel
    @State private var inspectorTab: Inspector.Tab = .studio
    @State private var showsInspector = true
    @State private var showsNarration = false

    var body: some View {
        VStack(spacing: 0) {
            PageBar(title: "Lumen Studio") {
                HStack(spacing: 8) {
                    LIconButton(icon: "waveform.and.mic", label: "Generate narration") { showsNarration = true }
                    LIconButton(icon: "cursorarrow", label: "Choose cursor skins") { showsInspector = true; inspectorTab = .cursor }
                    LIconButton(icon: "sidebar.right", label: showsInspector ? "Hide inspector" : "Show inspector") {
                        showsInspector.toggle()
                    }
                    LButton(title: "Export", icon: "square.and.arrow.up",
                            kind: model.exportPanelActive ? .secondary : .primary) { model.openExportPanel() }
                        .layoutPriority(1)
                }
            }
            // A recording without an event sidecar can never produce an
            // automatic zoom. Say so instead of showing an empty timeline.
            if model.session.input.events.isEmpty {
                PixelSymbolLabel("No input events were recorded. Automatic zoom cannot be generated for this clip.", symbol: "exclamationmark.triangle")
                    .font(AppType.caption).foregroundStyle(Tok.accentText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
            HStack(spacing: 0) {
                VStack(spacing: 8) {
                    GeometryReader { area in
                        // Use aspectRatio (customAspect-aware), not canvas.ratio:
                        // custom 1:1 / 9:16 exports were previewed at 16:9.
                        let ratio = CGFloat(max(model.timeline.style.aspectRatio, 0.1))
                        let w = min(area.size.width, area.size.height * ratio)
                        let h = min(area.size.height, area.size.width / ratio)
                        PreviewView(model: model)
                            .overlay { if model.focusEditing { FocusOverlay(model: model) } }
                            .overlay { if model.maskEditing { ManualMaskOverlay(model: model) } }
                            .overlay { if model.zoomDebug { ZoomDebugOverlay(model: model) } }
                            .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                            .frame(width: w, height: h)
                            .position(x: area.size.width / 2, y: area.size.height / 2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    transport
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                if showsInspector {
                    Inspector(model: model, tab: $inspectorTab, width: 360)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            TimelineStrip(model: model)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
        .background(StudioInk.rail)
        .sheet(isPresented: $showsNarration) { NarrationPanel(model: model) }
        .onChange(of: model.exportPanelRequest) { _, _ in showsInspector = true; inspectorTab = .export }
        .focusable().focusEffectDisabled()
        .onKeyPress(.space) { model.togglePlay(); return .handled }
        .onKeyPress(.delete) {
            if model.pendingCut != nil { model.commitPendingCut() } else { model.deleteSelected() }
            return .handled
        }
        .onKeyPress(.escape) {
            if model.pendingCut != nil { model.discardPendingCut() }
            else { model.selection = nil }
            return .handled
        }
        .onKeyPress { press in
            let hasCmd = press.modifiers.contains(.command)
            let hasShift = press.modifiers.contains(.shift)
            if press.key == .leftArrow {
                if hasCmd { return .ignored }
                if model.pendingCut != nil {
                    model.nudgePendingHandle(model.pendingCut?.focused ?? .end, hasShift ? -1 : -model.frameDuration)
                    return .handled
                }
                model.seek(model.playhead - (hasShift ? 1 : 1.0 / 30.0)); return .handled
            }
            if press.key == .rightArrow {
                if hasCmd { return .ignored }
                if model.pendingCut != nil {
                    model.nudgePendingHandle(model.pendingCut?.focused ?? .end, hasShift ? 1 : model.frameDuration)
                    return .handled
                }
                model.seek(model.playhead + (hasShift ? 1 : 1.0 / 30.0)); return .handled
            }
            if hasCmd {
                switch press.key {
                case .init("z"): if hasShift { model.redo() } else { model.undo() }; return .handled
                case .init("b"): model.splitAtPlayhead(); return .handled
                case .init("c"): model.copySelectedClip(); return .handled
                case .init("x"): model.cutSelectedClip(); return .handled
                case .init("v"): model.pasteClipAtPlayhead(); return .handled
                case .init("d"): model.duplicateSelected(); return .handled
                case .init("j"): model.joinSelectedClips(); return .handled
                default: break
                }
                return .ignored
            }
            switch press.key {
            case .init("b"), .init("s"): model.splitAtPlayhead(); return .handled
            case .init("c"): model.cutAtPlayhead(); return .handled
            case .init("i"): model.setRangeIn(); return .handled
            case .init("o"): model.setRangeOut(); return .handled
            case .init("n"): model.snapEnabled.toggle(); return .handled
            case .init("f"): model.timelineFitRequest += 1; return .handled
            default: return .ignored
            }
        }
    }
    // One table drives both the keys and the shortcut list so they cannot drift.
    static let shortcuts: [(String, String)] = [
        ("Space", "Play / pause"), ("← / →", "Step one frame (Shift: 1s / handle)"),
        ("B / S", "Split at playhead"), ("Cmd-B", "Split at playhead"),
        ("C", "Cut — start a range"), ("Backspace", "Commit cut / Delete selection"),
        ("I / O", "Set range start / end"), ("Esc", "Discard range / clear selection"),
        ("Cmd-C", "Copy clip"), ("Cmd-X", "Cut clip to clipboard"), ("Cmd-V", "Paste at playhead"), ("Cmd-D", "Duplicate"),
        ("Cmd-J", "Join with next"), ("Cmd-Z", "Undo"), ("Shift-Cmd-Z", "Redo"),
        ("N", "Toggle snapping"), ("F", "Fit timeline"), ("[ / ]", "Step to click"),
    ]

    private var transport: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                LButton(title: model.clock.playing ? "Pause" : "Play", icon: model.clock.playing ? "pause.fill" : "play.fill", kind: .secondary) { model.togglePlay() }
                Text("\(fmt(model.playhead)) / \(fmt(model.duration))").font(AppType.body.monospacedDigit()).foregroundStyle(Tok.text2)
                Spacer()
                LButton(title: "Add zoom", icon: "plus.magnifyingglass", kind: .quiet) { model.addZoom() }
                LButton(title: "Tools", icon: "slider.horizontal.3", kind: .secondary) { openTools() }
            }
            HStack(spacing: 12) {
                // One control per action beside the readout line. The timeline
                // is full at 184pt (ruler + 4 lanes), so there is no toolbar.
                HStack(spacing: 4) {
                    LIconButton(icon: "square.split.2x1", label: "Split at playhead (B)") { model.splitAtPlayhead() }
                    LIconButton(icon: "scissors", label: model.pendingCut != nil ? "Cut now (Backspace)" : "Cut range (C)") { model.cutAtPlayhead() }
                    LIconButton(icon: "trash", label: "Delete selection (Backspace)") { model.deleteSelected() }
                        .disabled(model.selection == nil)
                    LIconButton(icon: model.snapEnabled ? "magnet.fill" : "magnet", label: model.snapEnabled ? "Snapping on (N)" : "Snapping off (N)") { model.snapEnabled.toggle() }
                    LIconButton(icon: "arrow.uturn.backward", label: "Undo (Cmd-Z)") { model.undo() }.disabled(!model.canUndo)
                    LIconButton(icon: "arrow.uturn.forward", label: "Redo (Shift-Cmd-Z)") { model.redo() }.disabled(!model.canRedo)
                }
                Text(readout)
                    .font(AppType.body.monospacedDigit()).foregroundStyle(Tok.text2)
                    .lineLimit(1)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(readout)
        }
    }

    /// The readout line: what is selected and what the next key will do.
    var readout: String {
        if let p = model.pendingCut {
            if model.pendingWouldRemoveEverything { return "That range would remove the whole recording." }
            return "Cut \(fmt(p.start)) to \(fmt(p.end)) — \(String(format: "%.1fs", p.length)). Release to cut, Backspace cuts now, Esc discards."
        }
        if let issue = model.editIssue { return issue }
        if model.isProvisionalAudio { return "Preview audio · Studio processing not yet ready" }
        if let id = model.selection {
            if let z = model.timeline.zoom.first(where: { $0.id == id }) {
                return "Zoom \(String(format: "%.1f×", z.scale)) selected. Drag edges or body. Delete removes."
            }
            if let clip = model.timeline.clips.first(where: { $0.id == id }) {
                return "Clip \(clip.name) selected. Backspace ripples it out."
            }
            return "Selected. Backspace deletes."
        }
        return model.snapEnabled ? "Ready. Snap on: playhead, clip edges, cuts, clicks." : "Ready. Snap off."
    }
    private func openTools() {
        showsInspector = true
        inspectorTab = .tools
    }
    private func fmt(_ t: Double) -> String { String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
}