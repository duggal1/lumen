import SwiftUI
import AVFoundation
import LumenProject
import LumenAudio

/// Every click sound as a tile you can audition in place. One tap both selects
/// it and plays it, so there is no dropdown and no separate preview button.
/// The tile's comb is the real waveform peak of the sample, so the grid shows
/// the shape of each click instead of describing it.
struct ClickSoundGrid: View {
    let selected: ClickSound
    let onChoose: (ClickSound) -> Void

    @State private var peaks: [ClickSound: [Float]] = [:]
    @State private var playing: ClickSound?
    @State private var player: AVAudioPlayer?

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 1)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Click sound").font(AppType.label).foregroundStyle(Tok.text)
                Spacer(minLength: 8)
                if playing != nil {
                    LIconButton(icon: "stop.fill", label: "Stop preview") { stop() }
                }
            }
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(ClickSound.allCases, id: \.self) { sound in
                    tile(sound)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await loadPeaks() }
        .onDisappear { stop() }
    }

    private func tile(_ sound: ClickSound) -> some View {
        let isSelected = sound == selected
        let isPlaying = sound == playing
        return Button { onChoose(sound); play(sound) } label: {
            VStack(alignment: .leading, spacing: 6) {
                WaveformPeaks(peaks: peaks[sound] ?? [], tint: isSelected ? Tok.text : Tok.text2)
                    .frame(height: 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.title(sound))
                    .font(AppType.caption)
                    .foregroundStyle(isSelected ? Tok.text : Tok.text2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Selection and playback are one luminance step, never a stroke or
            // a bracket (DESIGN.md §2.1, §3.1.7).
            .background(RoundedRectangle(cornerRadius: Radius.field).fill(
                isPlaying ? Tok.accentSoft : (isSelected ? Tok.control : Tok.well)))
        }
        .buttonStyle(.plain)
        .clickable()
        .focusRing()
        .accessibilityLabel("\(Self.title(sound)) click sound")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func play(_ sound: ClickSound) {
        stop()
        let url: URL?
        switch sound {
        case .mouse: url = BundledAudioAssets.effect(named: "mouse-click.mp3")
        case .subtle: url = BundledAudioAssets.effect(named: "Subtle-ui-tap-interactions.mp3")
        case .fresh: url = BundledAudioAssets.effect(named: "new-click.mp3")
        default: url = BundledAudioAssets.effect(named: "touches/\(sound.rawValue).wav")
        }
        guard let url, let audio = try? AVAudioPlayer(contentsOf: url) else { return }
        audio.volume = 0.9
        audio.play()
        player = audio
        playing = sound
    }

    private func stop() {
        player?.stop(); player = nil; playing = nil
    }

    private func loadPeaks() async {
        let tones = ClickSound.allCases
        let loaded: [ClickSound: [Float]] = await Task.detached(priority: .utility) {
            var out: [ClickSound: [Float]] = [:]
            for tone in tones {
                let name: String
                switch tone {
                case .mouse: name = "mouse-click.mp3"
                case .subtle: name = "Subtle-ui-tap-interactions.mp3"
                case .fresh: name = "new-click.mp3"
                default: name = "touches/\(tone.rawValue).wav"
                }
                guard let url = BundledAudioAssets.effect(named: name),
                      let pcm = try? AudioIO.readMono(url), !pcm.isEmpty else { continue }
                out[tone] = ClickSoundGrid.combed(pcm, buckets: 24)
            }
            return out
        }.value
        peaks = loaded
    }

    /// Peak-pool a sample into fixed buckets so the tile comb is the real
    /// amplitude envelope of the click, normalized to its own peak.
    nonisolated static func combed(_ pcm: [Float], buckets: Int) -> [Float] {
        guard !pcm.isEmpty else { return [] }
        let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.0001 else { return [] }
        let n = pcm.count
        var out = [Float](repeating: 0, count: buckets)
        for b in 0..<buckets {
            let lo = b * n / buckets, hi = max(lo + 1, (b + 1) * n / buckets)
            var m: Float = 0
            for i in lo..<min(hi, n) { m = max(m, abs(pcm[i])) }
            out[b] = m / peak
        }
        return out
    }

    static func title(_ sound: ClickSound) -> String {
        switch sound {
        case .mouse: "Mouse"
        case .subtle: "Subtle"
        case .fresh: "Fresh"
        default: sound.rawValue.uppercased()
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