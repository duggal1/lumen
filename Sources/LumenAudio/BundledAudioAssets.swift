import Foundation
import LumenCore

/// A single resolver for sounds in a packaged Lumen.app and from a source checkout.
/// Missing audio is not replaced by generated noise.
public enum BundledAudioAssets {
    public struct Music: Hashable, Sendable {
        public let category: String
        public let title: String
        public let url: URL
        public init(category: String, title: String, url: URL) {
            self.category = category; self.title = title; self.url = url
        }
    }

    public static var root: URL? {
        AppAssets.directory(bundlePath: "Audio", sourcePaths: ["App/public/assets"])
    }

    public static func effect(named name: String) -> URL? {
        guard let path = root?.appendingPathComponent(name), FileManager.default.fileExists(atPath: path.path) else { return nil }
        return path
    }

    /// Fresh click sfx (new-click.mp3) — default clickTone .fresh.
    public static var freshClick: [Float] {
        guard let url = effect(named: "new-click.mp3"),
              let pcm = try? AudioIO.readMono(url), !pcm.isEmpty else { return [] }
        let peak = pcm.reduce(Float(0)) { max($0, abs($1)) }
        return peak > 0.0001 ? pcm.map { $0 * (1.0 / peak) } : []
    }

    /// Clean, real, concise titles for the bundled tracks, keyed by the file's
    /// stem. YouTube dumps carry channel names and copyright tags in the
    /// filename; none of that belongs in the UI. A track without an entry
    /// falls back to a de-tagged version of its filename, never the raw dump.
    public static let musicTitles: [String: String] = [
        // calm
        "5. free ambient orchestral music (ferrn) [_K-joysFUIM]": "Still Air",
        "FREE｜ Orchestral Ambient Music ｜ Breathe [BVC73mCYc30]": "Breathe",
        "Juniper - Kevin MacLeod [USUAN1100186]": "Juniper",
        "Long Way to go - Relaxing Ambient Orchestral Music [B6ig7osq8HE]": "The Long Way",
        "Majestic Hills - Kevin MacLeod [USUAN1100423]": "Majestic Hills",
        "Quiet Night at the Shack - Background⧸Orchestra - Royalty Free Music [OD3m44UMrQo]": "Quiet Night",
        // epic
        "Dramatic Cinematic Orchestral Music by Cyber Pirate [No Copyright Music] ⧸ Echoe [GGlIv8mo69s]": "Echoes in the Dark",
        "EPIC Cinematic Music ｜ Powerful Orchestral Trailer (Copyright Free) [c8e7jLNdiTY]": "Powerful",
        "Epic Orchestral Cinematic Trailer Music (No Copyright) by VM ⧸ Echo of the Brave [NotnrHMCFn8]": "Echo of the Brave",
        "Épica - Epic Biblical Orchestral Trailer [MTQwm0cXR3c]": "Épica",
        "Noble Race - Kevin MacLeod [USUAN1100888]": "Noble Race",
        // futuristic
        "Dying Star – Epic Cinematic Space Instrumental ｜ Ambient Sci-Fi Soundtrack for F [b8ZAe-bOJdI]": "Dying Star",
        "On the Run ｜ Dark Sci-Fi⧸Orchestral Original [JOVvb7tIW8Q]": "On the Run",
        "The Silent Chamber ｜ Sci-Fi Cinematic Music ｜ CC BY 4.0 ｜ Muted Symphony [tMleI2CXqtQ]": "Silent Chamber",
        "Universe - Epic Cinematic Space Instrumental ｜ Ambient Sci-Fi Soundtrack for Fil [I3anaWxCdwk]": "Universe",
        // tension
        "[Free Tension Building Theme] ＂Time's Up＂ Royalty Free Cinematic Music [MYiOrwUiJV8]": "Time's Up",
        "Black Vortex - Kevin MacLeod [USUAN1300037]": "Black Vortex",
        "Dark Cinematic Tension Music ｜ Copyright Free Music ｜ BEATS BY OSA [LYEWdwa7gGA]": "Dark Tension",
        "No Copyright Epic Cinematic Trailer Music by VM ⧸ Shadow Tension [I4Dv-QQRgPI]": "Shadow Tension",
        "Tension Build to Epic Finale – Cinematic Trailer Music (No Copyright) by VM⧸ Aga [U_XO1n24V30]": "Against the Clock",
        // upbeat
        "😧Dramatic Orchestral — Royalty - JP Bianchini (No Copyright)Vlog Music 🎶 [Fem_YcFHXRM]": "Dramatic",
        "Orchestral Background Music [tGx7a7OhMeM]": "Daybreak",
        "Uplifting Orchestra -  Cinematic Background Music (No Copyright Music) [Y4BnewtoTj0]": "Uplifting",
        "Windland ｜ Cinematic Bright Upbeat Orchestral Music [vrQpVu24J84]": "Windland",
    ]

    public static let music: [Music] = {
        guard let root = root?.appendingPathComponent("music", isDirectory: true) else { return [] }
        let fm = FileManager.default
        return ["calm", "epic", "futuristic", "tension", "upbeat"].flatMap { category -> [Music] in
            let dir = root.appendingPathComponent(category, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
            return files.filter { $0.pathExtension.lowercased() == "mp3" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { file in
                    let stem = file.deletingPathExtension().lastPathComponent
                    return Music(category: category, title: musicTitles[stem] ?? cleanStem(stem), url: file)
                }
        }
    }()

    /// A last-resort clean title for an unknown track: drop any
    /// ` - Artist [isrc]` tail, then a remaining trailing `[video-id]`, then trim whitespace.
    public static func cleanStem(_ raw: String) -> String {
        // Strip the ` - Artist [isrc]` tail while its bracket is still present,
        // then any remaining trailing `[id]`. Reversing these loses the anchor
        // the artist pattern needs and leaves `"Song - Artist"` behind.
        var s = raw.replacingOccurrences(of: " - [A-Za-z].*\\[[A-Z0-9]+\\]$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: " \\[[^\\]]+\\]$", with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Untitled" : s
    }
}
