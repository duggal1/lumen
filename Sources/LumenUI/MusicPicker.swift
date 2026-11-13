import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import LumenAudio
import LumenProject

struct MusicPicker: View {
    let model: EditorModel
    @State private var category = "calm"
    @State private var candidate = ""
    @State private var player: AVAudioPlayer?
    @State private var previewError: String?
    @State private var durations: [UUID: Double] = [:]

    private var tracks: [BundledAudioAssets.Music] { BundledAudioAssets.music }
    private var filtered: [BundledAudioAssets.Music] { tracks.filter { $0.category == category } }

    var body: some View {
        VStack(spacing: 0) {
            if !tracks.isEmpty {
                Row(label: "Mood") {
                    LDropdown(sel: $category, options: ["calm", "upbeat", "epic", "futuristic", "tension"].map {
                        ($0, $0.capitalized, "music.note.list")
                    }).frame(width: 136)
                }
                Row(label: "Music") {
                    LDropdown(sel: $candidate, options: trackOptions).frame(width: 136)
                }
                HStack {
                    LButton(title: "Preview", icon: "play.fill") { preview(candidate, gain: -18) }
                        .disabled(candidate.isEmpty)
                    LIconButton(icon: "stop.fill", label: "Stop preview") { player?.stop(); player = nil }
                    LButton(title: "Use track", icon: "plus") {
                        player?.stop(); player = nil
                        addMusic(URL(fileURLWithPath: candidate))
                    }.disabled(candidate.isEmpty)
                }
            }
            Row(label: "Your music") {
                LButton(title: "Import…", icon: "music.note") { importMusic() }
            }
            if let root = BundledAudioAssets.root {
                LButton(title: "Music credits", icon: "info.circle", kind: .quiet) {
                    NSWorkspace.shared.open(root.appendingPathComponent("music/credits.csv"))
                }
            }
            ForEach(model.timeline.audio.lanes.filter { $0.role == .music }) { lane in
                let duration = max(durations[lane.id] ?? model.timeline.compositionDuration, 0.02)
                VStack(alignment: .leading, spacing: 4) {
                    Text(lane.path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Music")
                        .font(.caption).lineLimit(1)
                    HStack {
                        LButton(title: "Preview", icon: "play.fill") { if let path = lane.path { preview(path, gain: lane.gainDb) } }
                        LIconButton(icon: "stop.fill", label: "Stop preview") { player?.stop(); player = nil }
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
                    LButton(title: "Remove", icon: "trash", kind: .quiet) {
                        model.edit { $0.audio.lanes.removeAll { $0.id == lane.id } }
                    }
                }
                .task(id: lane.path) {
                    guard let path = lane.path,
                          let value = try? await AVURLAsset(url: URL(fileURLWithPath: path)).load(.duration),
                          value.seconds.isFinite, value.seconds > 0 else { return }
                    durations[lane.id] = value.seconds
                }
            }
            if model.timeline.audio.musicPath != nil {
                SliderRow(label: "Music volume", v: model.bind(\.audio.musicGainDb), range: -60...0,
                          fmt: { "\(Int($0)) dB" })
                LButton(title: "Remove music", icon: "trash", kind: .quiet) {
                    model.edit { $0.audio.musicPath = nil }
                }
            }
            if let previewError {
                Text(previewError).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if let current = tracks.first(where: { $0.url.path == model.timeline.audio.musicPath }) {
                category = current.category
                candidate = current.url.path
            }
        }
        .onChange(of: category) { _, _ in
            player?.stop(); player = nil; candidate = ""; previewError = nil
        }
        .onChange(of: candidate) { _, _ in
            player?.stop(); player = nil; previewError = nil
        }
        .onDisappear { player?.stop(); player = nil }
    }

    private var trackOptions: [(value: String, title: String, icon: String)] {
        [("", "Choose a track", "music.note.list")]
            + filtered.map { ($0.url.path, String($0.title.prefix(36)), "music.note") }
    }

    private func preview(_ path: String, gain: Double) {
        player?.stop()
        do {
            let audio = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            audio.volume = Float(pow(10, gain / 20))
            guard audio.play() else { previewError = "Could not play this track."; return }
            player = audio
            previewError = nil
        } catch {
            previewError = "Could not play this track."
        }
    }

    private func addMusic(_ url: URL) {
        let start = model.playhead
        model.edit { $0.audio.lanes.append(AudioLane(role: .music, path: url.path, placement: start, gainDb: -18)) }
    }

    private func importMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { addMusic(url) }
    }

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
