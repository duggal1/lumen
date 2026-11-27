import SwiftUI
import LumenProject
import LumenAudio

/// One click selects the sample and auditions the actual render PCM.
struct ClickSoundGrid: View {
    let selected: ClickSound
    let onChoose: (ClickSound) -> Void
    let onStop: () -> Void

    @State private var peaks: [ClickSound: [Float]] = [:]
    @State private var playing: ClickSound?
    @State private var previewReset: Task<Void, Never>?
     @State private var ready = false

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 4)]
 
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Click sound").font(AppType.label).foregroundStyle(Tok.text)
                Spacer(minLength: 8)
                if playing != nil {
                    LIconButton(icon: "stop.fill", label: "Stop preview") { stop() }
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(ClickSound.activeCollection, id: \.self) { tile($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            let loaded = await Task.detached(priority: .utility) {
                let bank = SFXBank()
                var result: [ClickSound: [Float]] = [:]
                for sound in ClickSound.activeCollection {
                    let pcm = bank.render(.click, clickTone: sound).samples
                    if !pcm.isEmpty { result[sound] = Self.combed(pcm, buckets: 24) }
                }
                return result
            }.value
            guard !Task.isCancelled else { return }
            peaks = loaded; ready = true
        }
        .onDisappear { stop() }
    }

    private func tile(_ sound: ClickSound) -> some View {
        let isSelected = sound == selected.activeTone
        let isPlaying = sound == playing
        let available = peaks[sound] != nil
        return Button {
            previewReset?.cancel()
            onChoose(sound); playing = sound
            previewReset = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(240)) } catch { return }
                playing = nil
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                WaveformPeaks(peaks: peaks[sound] ?? [], tint: isSelected ? Tok.text : Tok.text2)
                    .frame(height: 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Text(sound.title).font(AppType.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    PixelSymbol(isPlaying ? "speaker.wave.2.fill" : "play.fill", size: 10)
                }
                .foregroundStyle(isSelected ? Tok.text : Tok.text2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.field).fill(
                isPlaying ? Tok.accentSoft : (isSelected ? Tok.control : Tok.well)))
        }
        .buttonStyle(.plain)
        .clickable()
        .focusRing()
        .disabled(!available)
        .opacity(ready && !available ? 0.45 : 1)
        .accessibilityLabel("\(sound.title) click sound")
        .accessibilityHint(available ? "Select and preview" : "Sample unavailable")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func stop() {
        previewReset?.cancel(); previewReset = nil
        onStop(); playing = nil
    }

    nonisolated static func combed(_ pcm: [Float], buckets: Int) -> [Float] {
        guard !pcm.isEmpty, buckets > 0 else { return [] }
        let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.0001 else { return [] }
        let n = pcm.count
        return (0..<buckets).map { b in
            let lo = b * n / buckets, hi = min(n, max(lo + 1, (b + 1) * n / buckets))
            return pcm[lo..<hi].reduce(Float(0)) { max($0, abs($1)) } / peak
        }
    }
}

/// A 1-bit comb of peak bars. The played column could be tinted, but at rest
/// it is a flat envelope in the tile's ink.
struct WaveformPeaks: View {
    let peaks: [Float]
    var tint: Color

    var body: some View {
        Canvas { c, size in
            guard !peaks.isEmpty else {
                var dust = Path()
                let mid = size.height / 2
                var x: CGFloat = 0
                while x < size.width { dust.addRect(CGRect(x: x, y: mid, width: 1, height: 1)); x += 4 }
                c.fill(dust, with: .color(Tok.controlPressed))
                return
            }
            let n = CGFloat(peaks.count)
            let pitch = size.width / n
            let w = max(1, (pitch * 0.6).rounded())
            for (i, p) in peaks.enumerated() {
                let h = max(1, (CGFloat(p) * size.height).rounded())
                let x = CGFloat(i) * pitch + (pitch - w) / 2
                c.fill(Path(CGRect(x: x, y: (size.height - h) / 2, width: w, height: h)),
                       with: .color(tint))
            }
        }
    }
}