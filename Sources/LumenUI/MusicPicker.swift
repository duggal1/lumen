import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import LumenAudio
import LumenProject

/// Music as a grid of sleeves, not a dropdown. Pick a mood, tap a sleeve to
/// audition it, tap Add to drop it on the music lane. Every sleeve is a flat
/// block in its mood's hue with a real waveform comb, so the shelf reads as a
/// record bin instead of a form. Adding a track puts it on the timeline where
/// it can be dragged and trimmed.
struct MusicPicker: View {
    let model: EditorModel
    @State private var category = "calm"
    @State private var playing: String?
    @State private var player: AVAudioPlayer?
    @State private var durations: [UUID: Double] = [:]
    @State private var waveforms: [String: [Float]] = [:]

    private static let moods = ["calm", "epic", "upbeat", "futuristic", "tension"]
    private var tracks: [BundledAudioAssets.Music] { BundledAudioAssets.music }
    private var filtered: [BundledAudioAssets.Music] { tracks.filter { $0.category == category } }
    private var addedPaths: Set<String> { Set(model.timeline.audio.lanes.compactMap { $0.path }) }

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Music").font(AppType.label).foregroundStyle(Tok.text)
                Spacer(minLength: 8)
                if playing != nil {
                    LIconButton(icon: "stop.fill", label: "Stop preview") { stop() }
                }
                LButton(title: "Import…", icon: "plus", kind: .quiet) { importMusic() }
            }

            moodBar

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(filtered, id: \.url) { track in
                    sleeve(track)
                }
            }

            if !addedTracks.isEmpty { addedSection }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await loadWaveforms() }
        .onDisappear { stop() }
    }

    // MARK: Mood: a quiet segmented row, not a dropdown. Each mood is a label
    // that owns the grid below it.

    private var moodBar: some View {
        HStack(spacing: 4) {
            ForEach(Self.moods, id: \.self) { mood in
                let on = mood == category
                Button { category = mood; stop() } label: {
                    Text(mood.capitalized)
                        .font(AppType.caption)
                        .foregroundStyle(on ? Tok.text : Tok.text2)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(on ? Tok.control : .clear))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: One sleeve

    private func sleeve(_ track: BundledAudioAssets.Music) -> some View {
        let hue = MusicInk.mood(track.category)
        let isPlaying = playing == track.url.path
        let added = addedPaths.contains(track.url.path)
        return Button { isPlaying ? stop() : play(track) } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    WaveformPeaks(peaks: waveforms[track.url.path] ?? [], tint: hue)
                        .frame(height: 26)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                    Text(track.title)
                        .font(AppType.body)
                        .foregroundStyle(Tok.text)
                        .lineLimit(1)
                    Text(track.category.capitalized)
                        .font(AppType.caption)
                        .foregroundStyle(Tok.text2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

                trailing(track, added: added, hue: hue)
                    .padding(.trailing, 8)
            }
            .background(RoundedRectangle(cornerRadius: Radius.field).fill(Tok.well))
            .overlay { if isPlaying { CornerBrackets().padding(-3) } }
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityLabel("\(track.title), \(track.category) music. \(isPlaying ? "Playing, tap to stop" : "Tap to preview")")
    }

    /// One trailing cell: an add affordance until the track is on the lane,
    /// then a remove affordance. Both are their own buttons so they never
    /// start a preview.
    @ViewBuilder private func trailing(_ track: BundledAudioAssets.Music, added: Bool, hue: Color) -> some View {
        if added {
            Button { model.removeMusicLane(model.timeline.audio.lanes.first(where: { $0.path == track.url.path })?.id ?? UUID()) } label: {
                Image(systemName: "check").font(.system(size: 11)).foregroundStyle(Tok.text2)
                    .frame(width: 24, height: 24).background(Circle().fill(Tok.control))
            }
            .buttonStyle(.plain).pointerStyle(.link)
            .accessibilityLabel("Remove \(track.title) from the timeline")
        } else {
            Button { add(track) } label: {
                Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Tok.text)
                    .frame(width: 24, height: 24).background(Circle().fill(hue.opacity(0.22)))
            }
            .buttonStyle(.plain).pointerStyle(.link)
            .accessibilityLabel("Add \(track.title) to the timeline")
        }
    }

    // MARK: Tracks already on the music lane

    private var addedTracks: [AudioLane] { model.timeline.audio.lanes.filter { $0.role == .music } }

    private var addedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("On the timeline").font(AppType.caption).foregroundStyle(Tok.text2)
                Spacer(minLength: 8)
            }
            ForEach(addedTracks) { lane in
                addedRow(lane)
            }
        }
        .padding(.top, 4)
    }

    private func addedRow(_ lane: AudioLane) -> some View {
        let duration = max(durations[lane.id] ?? model.timeline.compositionDuration, 0.02)
        let name = lane.path.map { Self.displayName($0) } ?? "Music"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PixelBitmap(rows: Bitmap.disc, cell: 1, color: MusicInk.lane).frame(width: 8, height: 8)
                Text(name).font(AppType.label).foregroundStyle(Tok.text).lineLimit(1)
                Spacer(minLength: 8)
                LIconButton(icon: "trash", label: "Remove \(name)") {
                    model.removeMusicLane(lane.id)
                }
            }
            SliderRow(label: "Start", v: laneValue(lane.id, \.placement),
                      range: 0...max(model.timeline.compositionDuration, 0.01),
                      fmt: { String(format: "%.1f s", $0) })
            SliderRow(label: "Volume", v: laneValue(lane.id, \.gainDb), range: -60...0,
                      fmt: { "\(Int($0)) dB" })
            SliderRow(label: "Trim start", v: optionalLaneValue(lane.id, \.trimStart, default: 0),
                      range: 0...(duration - 0.01), fmt: { String(format: "%.1f s", $0) })
            SliderRow(label: "Length", v: optionalLaneValue(lane.id, \.trimDuration,
                      default: max(duration - (lane.trimStart ?? 0), 0.01)),
                      range: 0.01...duration, fmt: { String(format: "%.1f s", $0) })
        }
        .padding(.vertical, 6)
        .task(id: lane.path) {
            guard let path = lane.path,
                  let value = try? await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration),
                  value.seconds.isFinite, value.seconds > 0 else { return }
            durations[lane.id] = value.seconds
        }
    }

    // MARK: Audio

    private func play(_ track: BundledAudioAssets.Music) {
        stop()
        guard let audio = try? AVAudioPlayer(contentsOf: track.url) else { return }
        audio.volume = Float(pow(10, -14.0 / 20))
        audio.play()
        player = audio
        playing = track.url.path
    }

    private func stop() {
        player?.stop(); player = nil; playing = nil
    }

    private func add(_ track: BundledAudioAssets.Music) {
        let start = model.playhead
        model.edit { $0.audio.lanes.append(AudioLane(role: .music, path: track.url.path, placement: start, gainDb: -18)) }
        stop()
    }

    private func importMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.edit { $0.audio.lanes.append(AudioLane(role: .music, path: url.path, placement: model.playhead, gainDb: -18)) }
        }
    }

    private func loadWaveforms() async {
        let list = tracks
        let loaded: [String: [Float]] = await Task.detached(priority: .utility) {
            var out: [String: [Float]] = [:]
            for t in list {
                guard let pcm = try? AudioIO.readMonoPrefix(t.url, seconds: 6), !pcm.isEmpty else { continue }
                out[t.url.path] = MusicPicker.combed(pcm, buckets: 40)
            }
            return out
        }.value
        waveforms = loaded
    }

    /// Peak-pool a sample into fixed buckets so a sleeve shows the real
    /// amplitude envelope of the track, normalized to its own peak.
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

    static func displayName(_ path: String) -> String {
        if let track = BundledAudioAssets.music.first(where: { $0.url.path == path }) { return track.title }
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "Music" : stem
    }

    // MARK: Bindings for lane sliders

    private func laneValue(_ id: UUID, _ key: WritableKeyPath<AudioLane, Double>) -> Binding<Double> {
        Binding(get: { model.timeline.audio.lanes.first(where: { $0.id == id })?[keyPath: key] ?? 0 },
                set: { value in model.edit(coalesce: true) { timeline in
                    guard let index = timeline.audio.lanes.firstIndex(where: { $0.id == id }) else { return }
                    timeline.audio.lanes[index][keyPath: key] = value
                } })
    }

    private func optionalLaneValue(_ id: UUID, _ key: WritableKeyPath<AudioLane, Double?>,
                                   default fallback: Double) -> Binding<Double> {
        Binding(get: { model.timeline.audio.lanes.first(where: { $0.id == id })?[keyPath: key] ?? fallback },
                set: { value in model.edit(coalesce: true) { timeline in
                    guard let index = timeline.audio.lanes.firstIndex(where: { $0.id == id }) else { return }
                    timeline.audio.lanes[index][keyPath: key] = value
                } })
    }
}