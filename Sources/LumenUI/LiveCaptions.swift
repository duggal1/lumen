import SwiftUI
import AppKit
import LumenCore
import LumenProject
import LumenSpeech

// Live transcription and its floating recorder panel have been removed.
// Transcript editing and Moonshine model management exist in the Studio only.

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

enum ModelPicker {
    @MainActor static func pick() -> URL? {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.message = "Choose the Moonshine model folder"
        return p.runModal() == .OK ? p.url : nil
    }
}

struct TranscriptTab: View {
    let model: EditorModel
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
                ToggleRow(label: "Render captions in final video", on: model.bind(\.captions.enabled))
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
