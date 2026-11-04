import Foundation

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
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Audio", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("App/public/assets", isDirectory: true)
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("mouse-click.mp3").path) }
    }

    public static func effect(named name: String) -> URL? {
        guard let path = root?.appendingPathComponent(name), FileManager.default.fileExists(atPath: path.path) else { return nil }
        return path
    }

    public static let music: [Music] = {
        guard let root = root?.appendingPathComponent("music", isDirectory: true) else { return [] }
        let fm = FileManager.default
        return ["calm", "epic", "futuristic", "tension", "upbeat"].flatMap { category -> [Music] in
            let dir = root.appendingPathComponent(category, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
            return files.filter { $0.pathExtension.lowercased() == "mp3" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { file in
                    let raw = file.deletingPathExtension().lastPathComponent
                    let name = raw.replacingOccurrences(of: " \\[[^\\]]+\\]$", with: "", options: .regularExpression)
                    return Music(category: category, title: name, url: file)
                }
        }
    }()
}
