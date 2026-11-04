import SwiftUI
import LumenAudio
import LumenProject

/// The bundled soundtrack library is derived from the actual audio files,
/// not hard-coded demo options. Existing imported tracks remain selectable.
struct MusicPicker: View {
    let model: EditorModel
    @State private var category = "calm"

    private var tracks: [BundledAudioAssets.Music] { BundledAudioAssets.music }
    private var filtered: [BundledAudioAssets.Music] { tracks.filter { $0.category == category } }

    var body: some View {
        VStack(spacing: 0) {
            if !tracks.isEmpty {
                Row(label: "Mood") {
                    LDropdown(sel: $category,
                              options: ["calm", "upbeat", "epic", "futuristic", "tension"].map {
                                  ($0, $0.capitalized, "music.note.list")
                              }).frame(width: 136)
                }
                Row(label: "Soundtrack") {
                    LDropdown(sel: selectedTrack, options: trackOptions).frame(width: 136)
                }
            }
            Row(label: "Your music") {
                LButton(title: "Import…", icon: "music.note") { model.importMusic() }
            }
        }
        .onAppear {
            if let current = tracks.first(where: { $0.url.path == model.timeline.audio.musicPath }) {
                category = current.category
            }
        }
    }

    private var selectedTrack: Binding<String> {
        Binding(get: { model.timeline.audio.musicPath ?? "" },
                set: { path in model.edit { $0.audio.musicPath = path.isEmpty ? nil : path } })
    }

    private var trackOptions: [(value: String, title: String, icon: String)] {
        let options: [(String, String, String)] = [("", "None", "speaker.slash")]
            + filtered.map { ($0.url.path, String($0.title.prefix(36)), "music.note") }
        if let current = model.timeline.audio.musicPath, !current.isEmpty,
           !options.contains(where: { $0.0 == current }) {
            return options + [(current, "Imported", "music.note")]
        }
        return options
    }
}
