import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import LumenAudio
import LumenProject

/// Music is a quiet record bin: pick a mood, tap a sleeve to audition it, tap
/// the cell to put it on the music lane. The previous picker decoded six
/// seconds of every bundled track the moment the page appeared — that was the
/// Studio's other source of lag. Here a sleeve decodes its own short prefix
/// only when it is on screen, and the result is cached in a bounded store.
struct MusicPicker: View {
    let model: EditorModel
    @State private var category = "calm"
    @State private var playing: String?
    @State private var player: AVAudioPlayer?
    @State private var durations: [UUID: Double] = [:]

    private static let moods = ["calm", "epic", "upbeat", "futuristic", "tension"]
    private var tracks: [BundledAudioAssets.Music] { BundledAudioAssets.music }
    private var filtered: [BundledAudioAssets.Music] { tracks.filter { $0.category == category } }
    private var addedPaths: Set<String> { Set(model.timeline.audio.lanes.compactMap { $0.path }) }
    private var addedTracks: [AudioLane] { model.timeline.audio.lanes.filter { $0.role == .music } }

    private let columns = [GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Music").font(AppType.label).foregroundStyle(Tok.text)
                Spacer(minLength: 8)
                if playing != nil {
                    LIconButton(icon: "stop.fill", label: "Stop preview") { stop() }
                }
                StudioButton(title: "Import…", icon: "plus", kind: .quiet) { importMusic() }
            }
            StudioPicker(sel: $category, options: Self.moods.map { ($0, $0.capitalized, "music.note") })
                .frame(maxWidth: .infinity)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(filtered, id: \.url) { track in
                    Sleeve(track: track,
                           hue: Dieother.mood(track.category),
                           playing: playing == track.url.path,
                           added: addedPaths.contains(track.url.path),
                           onPreview: { playing == track.url.path ? stop() : play(track) },
                           onAdd: { add(track) },
                           onRemove: { remove(track) })
                }
            }
            if !addedTracks.isEmpty { addedSection }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { stop() }
    }

    // MARK: One sleeve — loads only its own comb, only while visible

    private struct Sleeve: View {
        let track: BundledAudioAssets.Music
        let hue: Color
        let playing: Bool
        let added: Bool
        let onPreview: () -> Void
        let onAdd: () -> Void
        let onRemove: () -> Void
        @State private var peaks: [Float] = []

        var body: some View {
            HStack(alignment: .center, spacing: 8) {
                Button(action: onPreview) {
                    VStack(alignment: .leading, spacing: 0) {
                        WaveformPeaks(peaks: peaks, tint: hue)
                            .frame(height: 26)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                        Text(track.title).font(AppType.body).foregroundStyle(Tok.text).lineLimit(1)
                        Text(track.category.capitalized).font(AppType.caption).foregroundStyle(Tok.text2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).clickable()
                .accessibilityLabel("\(track.title), \(track.category) music. \(playing ? "Playing, tap to stop" : "Tap to preview")")
                Button(action: added ? onRemove : onAdd) {
                    Image(systemName: added ? "check" : "plus")
                        .font(AppType.glyph).foregroundStyle(added ? Tok.text2 : Tok.text)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(added ? Tok.control : hue.opacity(0.22)))
                }
                .buttonStyle(.plain).clickable().padding(.trailing, 8)
                .accessibilityLabel(added ? "Remove \(track.title) from the timeline" : "Add \(track.title) to the timeline")
            }
            .background(RoundedRectangle(cornerRadius: Radius.field).fill(playing ? StudioInk.pink.opacity(0.16) : StudioInk.well))
            .task(id: track.url.path) { peaks = await WaveformStore.shared.peaks(for: track.url) }
        }
    }

    // MARK: Tracks on the music lane

    private var addedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On the timeline").font(AppType.caption).foregroundStyle(Tok.text2)
            ForEach(addedTracks) { lane in addedRow(lane) }
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
                LIconButton(icon: "trash", label: "Remove \(name)") { model.removeMusicLane(lane.id) }
            }
            StudioSliderRow(label: "Start", v: laneValue(lane.id, \.placement),
                      range: 0...max(model.timeline.compositionDuration, 0.01),
                      fmt: { String(format: "%.1f s", $0) })
            StudioSliderRow(label: "Volume", v: laneValue(lane.id, \.gainDb), range: -60...0,
                      fmt: { "\(Int($0)) dB" })
            StudioSliderRow(label: "Trim start", v: optionalLaneValue(lane.id, \.trimStart, default: 0),
                      range: 0...(duration - 0.01), fmt: { String(format: "%.1f s", $0) })
            StudioSliderRow(label: "Length", v: optionalLaneValue(lane.id, \.trimDuration,
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

    private func remove(_ track: BundledAudioAssets.Music) {
        guard let id = model.timeline.audio.lanes.first(where: { $0.path == track.url.path })?.id else { return }
        model.removeMusicLane(id)
    }

    private func importMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.edit { $0.audio.lanes.append(AudioLane(role: .music, path: url.path, placement: model.playhead, gainDb: -18)) }
        }
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

/// A bounded, off-main cache of short waveform prefixes. Only a sleeve that is
/// actually on screen asks for an entry, and at most eight stay resident.
private actor WaveformStore {
    static let shared = WaveformStore()
    private var cache: [String: [Float]] = [:]
    private var order: [String] = []
    private let limit = 8

    func peaks(for url: URL) async -> [Float] {
        let key = url.path
        if let hit = cache[key] { return hit }
        let value = await Task.detached(priority: .utility) {
            guard let pcm = try? AudioIO.readMonoPrefix(url, seconds: 1.5), !pcm.isEmpty else { return [] as [Float] }
            return MusicPicker.combed(pcm, buckets: 24)
        }.value
        guard !value.isEmpty else { return [] }
        cache[key] = value
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            let oldest = order.removeFirst()
            cache[oldest] = nil
        }
        return value
    }
}
