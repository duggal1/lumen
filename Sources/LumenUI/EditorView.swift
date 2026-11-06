import SwiftUI
import LumenCore
import LumenProject

public struct EditorRoot: View {
    let url: URL
    @State private var model: EditorModel?
    @State private var failure: String?
    @State private var attempt = 0
    public init(url: URL) { self.url = url }
    public var body: some View {
        MenuRoot {
            Group {
                if let model { EditorView(model: model) }
                else if let failure {
                    VStack(spacing: 12) {
                        Text(failure).font(AppType.body).foregroundStyle(Tok.statusBad).textSelection(.enabled)
                        LButton(title: "Retry", kind: .primary) { self.failure = nil; attempt += 1 }
                    }.padding(32)
                } else { PixelWait() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Tok.bg)
            .background(WindowChrome())
        }
        .frame(minWidth: Metrics.minW, minHeight: Metrics.minH)
        .task(id: attempt) { do { model = try await EditorModel.open(url: url) } catch { failure = "Couldn't open this project. \(error)" } }
    }
}

struct EditorView: View {
    let model: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            PageBar(title: AppModel.displayName(model.session.meta.name)) {
                HStack(spacing: 8) {
                    LIconButton(icon: "arrow.uturn.backward", label: "Undo") { model.undo() }.disabled(!model.canUndo)
                    LIconButton(icon: "arrow.uturn.forward", label: "Redo") { model.redo() }.disabled(!model.canRedo)
                    LIconButton(icon: "person.2.badge.plus", label: "Share project") { model.shareProject() }
                    LButton(title: "Export", icon: "square.and.arrow.up",
                            kind: model.exportPanelActive ? .secondary : .primary) { model.openExportPanel() }
                }
            }
            HStack(spacing: 0) {
                VStack(spacing: 16) {
                    PreviewView(model: model)
                        .aspectRatio(model.timeline.style.canvas.ratio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                        .overlay { if model.focusEditing { FocusOverlay(model: model) } }
                        .overlay { if model.maskEditing { ManualMaskOverlay(model: model) } }
                        .overlay(alignment: .bottom) { CaptionMonitor(model: model).padding(.bottom, 16).padding(.horizontal, 16).allowsHitTesting(false) }
                        .overlay { if model.zoomDebug { ZoomDebugOverlay(model: model) } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    transport
                    TimelineStrip(model: model)
                }.padding(.horizontal, 32).padding(.bottom, 24)
                Inspector(model: model)
            }
        }
        .background(Tok.bg)
        .focusable().focusEffectDisabled()
        .onKeyPress(.space) { model.togglePlay(); return .handled }
        .onKeyPress(.delete) { model.deleteSelected(); return .handled }
        .onKeyPress(.leftArrow) { model.seek(model.playhead - 1); return .handled }
        .onKeyPress(.rightArrow) { model.seek(model.playhead + 1); return .handled }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            LButton(title: model.clock.playing ? "Pause" : "Play", icon: model.clock.playing ? "pause.fill" : "play.fill", kind: .secondary) { model.togglePlay() }
            Text("\(fmt(model.playhead)) / \(fmt(model.duration))").font(AppType.body.monospacedDigit()).foregroundStyle(Tok.text2)
#if DEBUG
            Text({ let s = model.renderer.presentStats.snapshot; return "late \(s.late)/\(s.frames) · worst \(Int(s.worstMs)) ms" }())
                .font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2)
#endif
            Spacer()
            LButton(title: "Cut", icon: "scissors", kind: .quiet) { model.cutAtPlayhead() }
            LButton(title: "Add zoom", icon: "plus.magnifyingglass", kind: .quiet) { model.addZoom() }
            LButton(title: "Loupe", icon: "magnifyingglass.circle", kind: .quiet) { model.addLoupe() }
            LButton(title: "Tap", icon: "cursorarrow.click", kind: .quiet) { model.addTapAtPlayhead() }
            LButton(title: "Import clip", icon: "film", kind: .quiet) { model.importClips() }
            LButton(title: "Frame it", icon: "viewfinder", kind: .quiet) { if model.selection != nil { model.focusEditing.toggle() } }
            LButton(title: "Title", icon: "textformat", kind: .quiet) { model.addManualTitle() }
            LButton(title: "Highlight", icon: "highlighter", kind: .quiet) { model.addManualHighlight() }
            LButton(title: "Delete", icon: "trash", kind: .quiet) { model.deleteSelected() }.disabled(model.selection == nil)
        }
    }
    private func fmt(_ t: Double) -> String { String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
}