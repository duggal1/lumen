import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenSpeech

enum CaptionKeys {
    static let enabled = "lumen.live.enabled", theme = "lumen.caption.theme", metrics = "lumen.caption.metrics", monitor = "lumen.caption.monitor"
}

enum CaptionTheme: String, CaseIterable, Hashable, Sendable {
    case glass, lumen
    var font: Font { .system(size: self == .glass ? 26 : 24, weight: .semibold) }
    var tracking: CGFloat { self == .glass ? 0 : -0.2 }
    var radius: CGFloat { self == .glass ? 22 : 16 }
    func palette(monitor: Bool) -> CaptionPalette {
        switch (self, monitor) {
        case (.glass, false): CaptionPalette(stable: .white, pending: Color.white.opacity(0.55), active: .white, activeBG: nil)
        case (.glass, true): CaptionPalette(stable: Color.white.opacity(0.92), pending: Color.white.opacity(0.42), active: .white, activeBG: Color.white.opacity(0.22))
        case (.lumen, false): CaptionPalette(stable: Tok.text, pending: Tok.accentText, active: Tok.text, activeBG: nil)
        case (.lumen, true): CaptionPalette(stable: Tok.text, pending: Tok.text2, active: Tok.accentText, activeBG: nil)
        }
    }
}

struct CaptionPalette { var stable: Color, pending: Color, active: Color, activeBG: Color? }
enum Tone { case stable, pending, active }
struct CWord: Equatable { var text: String; var tone: Tone }
struct CLine { var id: UInt64; var words: [CWord] }
struct CRow: Identifiable, Equatable {
    var id: UInt64; var words: [CWord]
    func attributed(_ p: CaptionPalette, _ font: Font) -> AttributedString {
        var out = AttributedString()
        for (i, w) in words.enumerated() {
            if i > 0 { var sp = AttributedString(" "); sp.foregroundColor = p.stable; out.append(sp) }
            var a = AttributedString(w.text)
            switch w.tone {
            case .stable: a.foregroundColor = p.stable
            case .pending: a.foregroundColor = p.pending
            case .active: a.foregroundColor = p.active; if let bg = p.activeBG { a.backgroundColor = bg }
            }
            out.append(a)
        }
        out.font = font
        return out
    }
}

enum CaptionLayout {
    /// Each runtime line starts a new row and wraps on its own, so rows never reflow as older lines scroll away.
    static func allRows(_ line: CLine, perLine: Int) -> [CRow] {
        var rows: [CRow] = [], cur: [CWord] = [], n = 0
        func flush() { if !cur.isEmpty { rows.append(CRow(id: line.id &* 64 &+ UInt64(rows.count), words: cur)); cur = []; n = 0 } }
        for w in line.words {
            let add = w.text.count + (cur.isEmpty ? 0 : 1)
            if n + add > perLine { flush() }
            cur.append(w); n += w.text.count + (cur.count > 1 ? 1 : 0)
        }
        flush()
        return rows
    }
    static func rows(_ lines: [CLine], perLine: Int, maxRows: Int = 2) -> [CRow] {
        Array(lines.flatMap { allRows($0, perLine: perLine) }.suffix(maxRows))
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active
        v.appearance = NSAppearance(named: .vibrantDark)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct CaptionSurface<C: View>: View {
    let theme: CaptionTheme
    @ViewBuilder var content: C
    var body: some View {
        content.padding(.horizontal, 20).padding(.vertical, 14)
            .background {
                switch theme {
                case .glass: RoundedRectangle(cornerRadius: theme.radius).fill(.regularMaterial)
                case .lumen: Tok.surface
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
    }
}

struct CaptionBlock: View {
    let rows: [CRow]; let palette: CaptionPalette; let font: Font; let tracking: CGFloat; let reduce: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(rows) { r in
                Text(r.attributed(palette, font)).tracking(tracking).lineLimit(1).minimumScaleFactor(0.9)
                    .opacity(r.id == rows.last?.id ? 1 : 0.5)
                    .transition(reduce ? .identity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .animation(reduce ? nil : .smooth(duration: 0.16), value: rows.map(\.id))
        .clipped()
    }
}

// MARK: Live model

@MainActor @Observable final class LiveCaptionModel {
    private(set) var lines: [LiveLine] = []
    private(set) var state = LiveState.idle
    private(set) var lagMs = 0.0
    @ObservationIgnored private var task: Task<Void, Never>?

    func attach(_ t: LiveTranscriber) {
        task?.cancel(); lines = []; state = .loading; lagMs = 0
        task = Task { @MainActor [weak self] in
            for await u in t.updates { self?.apply(u) }
        }
    }
    func detach() { task?.cancel(); task = nil; lines = []; state = .idle }
    private func apply(_ u: LiveUpdate) {
        lines = u.lines; state = u.state
        if !u.lines.isEmpty { lagMs = lagMs == 0 ? u.lagMs : 0.7 * lagMs + 0.3 * u.lagMs }
    }
}

private enum StatusText {
    static func text(_ s: LiveState) -> String {
        switch s {
        case .idle: ""
        case .loading: "Loading speech model…"
        case .listening: "Listening…"
        case .notInstalled: "Moonshine model not installed."
        case .degraded(let m), .failed(let m): m
        }
    }
}

private struct StatusMark: View {
    let theme: CaptionTheme; let state: LiveState; let level: Float
    var body: some View {
        switch theme {
        case .glass:
            Image(systemName: { switch state { case .loading: "ellipsis"; case .failed, .notInstalled, .degraded: "exclamationmark.triangle"; default: "waveform" } }())
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.white.opacity(0.6)).frame(width: 18, height: 26)
        case .lumen:
            VStack(alignment: .leading, spacing: 8) {
                switch state {
                case .loading: PixelWait()
                case .failed, .notInstalled: PixelBitmap(rows: Bitmap.failed, cell: 2, color: Tok.statusBad)
                case .degraded: PixelBitmap(rows: Bitmap.bang, cell: 2, color: Tok.text2)
                default: PixelWait(); PixelMeter(level: level)
                }
            }.frame(width: 48, alignment: .leading)
        }
    }
}

/// Live caption panel shown while recording (floating, click-through, excluded from capture).
struct LiveCaptionView: View {
    let model: LiveCaptionModel
    let app: AppModel
    @AppStorage(CaptionKeys.theme) private var theme: CaptionTheme = .glass
    @AppStorage(CaptionKeys.metrics) private var metrics = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let pal = theme.palette(monitor: false)
        let lines = model.lines.map { l in CLine(id: l.id, words: l.words.map { CWord(text: $0.text, tone: $0.tentative ? .pending : .stable) }) }
        let rows = CaptionLayout.rows(lines, perLine: 44)
        CaptionSurface(theme: theme) {
            HStack(alignment: .top, spacing: 12) {
                StatusMark(theme: theme, state: model.state, level: app.stats?.micLevel ?? 0)
                if rows.isEmpty {
                    Text(StatusText.text(model.state)).font(theme.font).foregroundStyle(pal.pending == Tok.accentText ? Tok.text2 : pal.pending)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    CaptionBlock(rows: rows, palette: pal, font: theme.font, tracking: theme.tracking, reduce: reduce)
                }
                if metrics {
                    Text("\(Int(model.lagMs)) ms").font(AppType.caption.monospacedDigit())
                        .foregroundStyle(theme == .glass ? Color.white.opacity(0.5) : Tok.text2)
                }
            }
        }
        .frame(width: 600, height: 96)
    }
}

@MainActor final class LiveCaptionPanel {
    private var panel: NSPanel?
    init(_ model: LiveCaptionModel, app: AppModel) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 96), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = NSHostingView(rootView: LiveCaptionView(model: model, app: app))
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.sharingType = .none; p.hidesOnDeactivate = false; p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let s = NSScreen.main { p.setFrameOrigin(CGPoint(x: s.frame.midX - 300, y: s.frame.maxY - 48 - 36 - 12 - 96)) }     // under the recorder HUD
        panel = p
    }
    func show() { panel?.orderFrontRegardless() }
    func close() { panel?.orderOut(nil); panel = nil }
}

// MARK: Sentences (transcript panel + editor monitor)

struct Sentence: Identifiable, Equatable { let id: Int; let range: Range<Int>; let start: Double; let end: Double }
enum Sentences {
    static func split(_ w: [WordToken]) -> [Sentence] {
        var out: [Sentence] = [], s = 0
        for i in w.indices {
            let last = i == w.count - 1
            let stop = w[i].text.last.map { ".?!…".contains($0) } ?? false
            let gap = !last && w[i + 1].start - w[i].end > 0.8
            if last || stop || gap || i - s + 1 >= 14 {
                out.append(Sentence(id: out.count, range: s..<(i + 1), start: w[s].start, end: w[i].end)); s = i + 1
            }
        }
        return out
    }
    /// Last word whose start <= t.
    static func index(of w: [WordToken], at t: Double) -> Int? {
        var lo = 0, hi = w.count
        while lo < hi { let m = (lo + hi) / 2; if w[m].start <= t { lo = m + 1 } else { hi = m } }
        return lo > 0 ? lo - 1 : nil
    }
    static func find(_ ss: [Sentence], word: Int) -> Int {
        var lo = 0, hi = ss.count - 1
        while lo < hi { let m = (lo + hi) / 2; if ss[m].range.upperBound <= word { lo = m + 1 } else { hi = m } }
        return lo
    }
}

/// Editor monitor: the sentence at the playhead with the spoken word highlighted. Preview only (not rendered into exports yet).
struct CaptionMonitor: View {
    let model: EditorModel
    @AppStorage(CaptionKeys.theme) private var theme: CaptionTheme = .glass
    @AppStorage(CaptionKeys.monitor) private var on = true
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let _ = model.playhead                                 // subscribe; the TimelineView redraws at display rate while playing
        if on, let tr = model.transcript, !tr.words.isEmpty, !model.sentences.isEmpty {
            TimelineView(.animation(paused: !model.clock.playing)) { _ in
                let out = model.clock.playing ? model.clock.time(at: HostClock.now()) : model.playhead
                caption(tr.words, model.timeline.timeMap.source(atOutput: out))
            }
        }
    }

    @ViewBuilder private func caption(_ w: [WordToken], _ t: Double) -> some View {
        if let i = Sentences.index(of: w, at: t), t <= w[i].end + 0.6 {
            let s = model.sentences[Sentences.find(model.sentences, word: i)]
            let line = CLine(id: UInt64(s.id), words: s.range.map { k in CWord(text: w[k].text, tone: k < i ? .stable : (k == i ? .active : .pending)) })
            let rows = CaptionLayout.allRows(line, perLine: 44)
            let local = i - s.range.lowerBound
            let ar = rows.indices.first { r in local < rows[0...r].reduce(0) { $0 + $1.words.count } } ?? 0
            let start = max(min(ar - 1, rows.count - 2), 0)
            CaptionSurface(theme: theme) {
                CaptionBlock(rows: Array(rows[start..<min(start + 2, rows.count)]), palette: theme.palette(monitor: true), font: theme.font,
                             tracking: theme.tracking, reduce: reduce)
            }
            .frame(maxWidth: 700).frame(height: 112)
        }
    }
}

// MARK: Settings rows (Library) and the Transcript tab (Inspector)

struct LiveCaptionRows: View {
    let note: String?
    let app: AppModel
    @AppStorage(CaptionKeys.enabled) private var live = true
    @AppStorage(CaptionKeys.theme) private var theme: CaptionTheme = .glass
    @AppStorage(MoonshineSize.defaultsKey) private var size: MoonshineSize = .tiny
    @State private var installed = false
    @State private var error: String?
    @State private var downloadProgress: Double?
    var body: some View {
        Row(label: "Live captions", icon: "captions.bubble") { LToggle(on: $live, label: "Live captions") }
        if live {
            Row(label: "Caption style", icon: "paintbrush") { LSegmented(sel: $theme, items: [(.glass, "Glass"), (.lumen, "Lumen")]).frame(width: 130) }
            if installed {
                Row(label: "Speech model", icon: "waveform.circle") { Text("Installed").font(AppType.caption).foregroundStyle(Tok.text2) }
            } else if let p = (size == .tiny ? app.modelDownloadProgress : nil) ?? downloadProgress {
                Row(label: "Speech model", icon: "waveform.circle") { ProgressView(value: p).frame(width: 120) }
            } else {
                Row(label: "Speech model", icon: "waveform.circle") {
                    HStack(spacing: 8) {
                        LButton(title: "Download", icon: "arrow.down.circle", height: 24) { download() }
                        LButton(title: "Import…", icon: "folder", height: 24) { importModel() }
                    }
                }
            }
        }
        if let m = error ?? note { Text(m).font(AppType.caption).foregroundStyle(Tok.statusBad).frame(maxWidth: .infinity, alignment: .leading) }
        Color.clear.frame(height: 0).onAppear { installed = ModelStore.isInstalled(size) }.onChange(of: size) { _, s in installed = ModelStore.isInstalled(s) }
    }
    private func importModel() {
        guard let u = ModelPicker.pick() else { return }
        do { try ModelStore.importFolder(u, as: size); installed = true; error = nil } catch { self.error = "\(error)" }
    }
    private func download() {
        error = nil; downloadProgress = 0
        Task {
            do {
                try await ModelDownloader.download(size: size) { p in Task { @MainActor in downloadProgress = p } }
                downloadProgress = nil; installed = ModelStore.isInstalled(size)
            } catch { self.error = "\(error)"; downloadProgress = nil }
        }
    }
}

enum ModelPicker {
    @MainActor static func pick() -> URL? {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.message = "Choose the Moonshine model folder"
        return p.runModal() == .OK ? p.url : nil
    }
}

struct TranscriptTab: View {
    let model: EditorModel
    @AppStorage(CaptionKeys.theme) private var theme: CaptionTheme = .glass
    @AppStorage(CaptionKeys.enabled) private var live = true
    @AppStorage(CaptionKeys.monitor) private var monitor = true
    @AppStorage(MoonshineSize.defaultsKey) private var size: MoonshineSize = .tiny
    @State private var installed = Set<MoonshineSize>()
    @State private var error: String?
    @State private var downloadProgress: Double?

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 0) {
                Row(label: "Model") {
                    LDropdown(sel: $size, options: MoonshineSize.allCases.map { ($0, $0.title + (installed.contains($0) ? "" : " · not installed"), "waveform") }).frame(width: 170)
                }
                Row(label: "Live captions") { LToggle(on: $live, label: "Live captions") }
                Row(label: "Caption style") { LSegmented(sel: $theme, items: [(.glass, "Glass"), (.lumen, "Lumen")]).frame(width: 130) }
                Row(label: "Caption monitor") { LToggle(on: $monitor, label: "Caption monitor") }
                Row(label: "Model files") {
                    HStack(spacing: 8) {
                        if ModelStore.isInstalled(size) {
                            Text("Installed").font(AppType.caption).foregroundStyle(Tok.text2)
                        } else if let p = downloadProgress {
                            ProgressView(value: p).frame(width: 120)
                        } else {
                            LButton(title: "Download", icon: "arrow.down.circle") { download() }
                        }
                        LButton(title: "Import…", icon: "folder") { importModel() }
                    }
                }
            }.card()
            VStack(alignment: .leading, spacing: 12) {
                Text(size.detail).font(AppType.caption).foregroundStyle(Tok.text2)
                if let e = error { Text(e).font(AppType.caption).foregroundStyle(Tok.statusBad) }
                switch model.transcribeState {
                case .running(let p):
                    HStack(spacing: 8) { PixelWait(); Text("Transcribing \(Int(p * 100))%").font(AppType.body).foregroundStyle(Tok.text2); Spacer()
                        LButton(title: "Cancel", kind: .quiet) { model.cancelTranscribe() } }
                case .failed(let why):
                    Text(why).font(AppType.caption).foregroundStyle(Tok.statusBad)
                    LButton(title: "Retry", kind: .secondary) { model.transcribe() }
                case .notInstalled:
                    Text("Import a Moonshine model folder above.").font(AppType.caption).foregroundStyle(Tok.text2)
                case .idle:
                    if let t = model.transcript {
                        HStack { Text("\(t.words.count) words").font(AppType.caption.monospacedDigit()).foregroundStyle(Tok.text2); Spacer()
                            LButton(title: "Re-transcribe", kind: .quiet) { model.transcribe() } }
                    } else {
                        LButton(title: "Transcribe", icon: "text.alignleft", kind: .primary, height: 32) { model.transcribe() }
                    }
                }
                if model.transcript != nil { TranscriptList(model: model) }
            }.card()
        }
        .onAppear { refresh() }
    }
    private func refresh() { installed = Set(MoonshineSize.allCases.filter(ModelStore.isInstalled)) }
    private func importModel() {
        guard let u = ModelPicker.pick() else { return }
        do { try ModelStore.importFolder(u, as: size); error = nil } catch { self.error = "\(error)" }
        refresh()
    }
    private func download() {
        error = nil; downloadProgress = 0
        Task {
            do {
                try await ModelDownloader.download(size: size) { p in Task { @MainActor in downloadProgress = p } }
                downloadProgress = nil; refresh()
            } catch { self.error = "\(error)"; downloadProgress = nil }
        }
    }
}

private struct TranscriptList: View {
    let model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let ss = model.sentences, words = model.transcript?.words ?? []
        let t = model.timeline.timeMap.source(atOutput: model.playhead)
        let aw = Sentences.index(of: words, at: t)
        let activeS: Int? = (aw != nil && !ss.isEmpty) ? Sentences.find(ss, word: aw!) : nil
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(ss) { s in
                        SentenceRow(words: words[s.range], sentence: s, active: s.id == activeS ? (aw ?? 0) - s.range.lowerBound : nil) { model.seekSource(s.start) }
                            .equatable().id(s.id)
                    }
                }
            }
            .frame(height: 360)
            .onChange(of: activeS) { _, id in
                guard let id else { return }
                if reduce { proxy.scrollTo(id, anchor: .center) } else { withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

@MainActor private struct SentenceRow: View, Equatable {
    let words: ArraySlice<WordToken>
    let sentence: Sentence
    let active: Int?
    let seek: () -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool { a.sentence == b.sentence && a.active == b.active && a.words == b.words }
    var body: some View {
        Button(action: seek) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%d:%02d", Int(sentence.start) / 60, Int(sentence.start) % 60)).font(AppType.caption.monospacedDigit())
                    .foregroundStyle(Tok.text2).frame(width: 34, alignment: .leading)
                Text(attributed).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(active != nil ? Tok.wash : Color.clear))
        }.buttonStyle(.plain).accessibilityLabel(words.map(\.text).joined(separator: " "))
    }
    private var attributed: AttributedString {
        var out = AttributedString()
        for (k, w) in words.enumerated() {
            if k > 0 { out.append(AttributedString(" ")) }
            var a = AttributedString(w.text)
            a.foregroundColor = active == nil ? Tok.text2 : (k == active ? Tok.accentText : Tok.text)
            out.append(a)
        }
        out.font = AppType.body
        return out
    }
}
