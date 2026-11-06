import Foundation
import LumenProject
import LumenExport

enum ExportContainer: String, Codable, CaseIterable { case mp4 = "MP4", mov = "MOV"
    var ext: String { rawValue.lowercased() }
}
enum ExportResolution: String, Codable, CaseIterable {
    case source = "Source", ultraHD8K = "8K", ultraHD = "4K", p1440 = "1440p", p1080 = "1080p", p720 = "720p", custom = "Custom"
}
enum ExportRate: String, Codable, CaseIterable {
    case source = "Source", f24 = "24", f30 = "30", f60 = "60", f120 = "120", f144 = "144", f240 = "240"
    func fps(source: Double) -> Int {
        switch self {
        case .source: max(1, Int(source.rounded()))
        case .f24: 24; case .f30: 30; case .f60: 60
        case .f120: 120; case .f144: 144; case .f240: 240
        }
    }
}
enum ExportQuality: String, Codable, CaseIterable {
    case low = "Low", medium = "Medium", high = "High", max = "Max"
    var bpp: Double {
        switch self { case .low: 0.03; case .medium: 0.05; case .high: 0.08; case .max: 0.12 }
    }
}
enum ExportKind: String, Codable, CaseIterable {
    case video = "Video", gif = "GIF"
}

struct ExportSettings: Codable, Equatable {
    var kind: ExportKind = .video
    var container: ExportContainer = .mp4
    var codec: VideoCodec = .hevc
    var quality: ExportQuality = .high
    var resolution: ExportResolution = .source
    var customWidth = 1920, customHeight = 1080
    var frameRate: ExportRate = .source
    var includeAudio = true
    var audioBitrate = 256_000
    /// Premultiplied alpha channel. Forces ProRes 4444 in a .mov.
    var alpha = false
    /// A second, cursor-only movie with an alpha channel beside the main file.
    var cursorLayer = false
    /// One click renders 16:9, 1:1 and 9:16. Each aspect is re-aimed by the Director.
    var batchAspects = false
    var folder: String = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)
        .first?.path ?? NSHomeDirectory() + "/Movies"
    var filename = "Lumen export"

    /// ProRes cannot be written into an MP4, so the container follows the codec.
    var resolvedContainer: ExportContainer { codec.isProRes || alpha ? .mov : container }
    var fileExtension: String { kind == .gif ? "gif" : resolvedContainer.ext }

    private static let key = "lumen.export.settings.v2"

    enum CodingKeys: String, CodingKey {
        case kind, container, codec, quality, resolution, customWidth, customHeight, frameRate, includeAudio,
             audioBitrate, alpha, cursorLayer, batchAspects, folder, filename
    }
    init() {}
    /// Older settings files predate alpha/cursor-layer delivery; missing keys
    /// fall back to defaults instead of discarding the user's whole setup.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        func opt<T: Decodable>(_ k: CodingKeys, _ v: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? v }
        kind = opt(.kind, kind); container = opt(.container, container); codec = opt(.codec, codec)
        quality = opt(.quality, quality); resolution = opt(.resolution, resolution)
        customWidth = opt(.customWidth, customWidth); customHeight = opt(.customHeight, customHeight)
        frameRate = opt(.frameRate, frameRate); includeAudio = opt(.includeAudio, includeAudio)
        audioBitrate = opt(.audioBitrate, audioBitrate); alpha = opt(.alpha, alpha)
        cursorLayer = opt(.cursorLayer, cursorLayer); batchAspects = opt(.batchAspects, batchAspects)
        folder = opt(.folder, folder); filename = opt(.filename, filename)
    }

    static func load(defaultName: String) -> ExportSettings {
        if let data = UserDefaults.standard.data(forKey: key),
           let value = try? JSONDecoder().decode(ExportSettings.self, from: data) { return value }
        var value = ExportSettings()
        value.filename = defaultName.isEmpty ? value.filename : defaultName
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func dimensions(source: SourceInfo, aspect: Double) -> (Int, Int) {
        let height: Int = switch resolution {
        case .source: source.height
        case .ultraHD8K: 4320
        case .ultraHD: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .custom: customHeight
        }
        let h = max(2, min(8192, height)) & ~1
        let w = resolution == .custom ? max(2, min(8192, customWidth)) & ~1
            : (max(2, Int((Double(h) * aspect).rounded())) + 1) & ~1
        return (w, h)
    }

    func preset(source: SourceInfo, aspect: Double) -> ExportPreset {
        let (w, h) = dimensions(source: source, aspect: aspect)
        let fps = frameRate.fps(source: source.fps)
        let resolvedCodec: VideoCodec = alpha ? .prores4444 : codec
        return ExportPreset(name: "\(w)x\(h)@\(fps)-\(resolvedCodec.rawValue)",
                            codec: resolvedCodec, height: h, fps: fps, bpp: quality.bpp, customWidth: w,
                            alpha: alpha && resolvedCodec.supportsAlpha)
    }

    func destinationURL() -> URL? {
        let base = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base != ".", base != "..", !base.contains("/"), !base.contains(":") else { return nil }
        let lower = base.lowercased()
        let stem = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || lower.hasSuffix(".gif")
            ? String(base.dropLast(4)) : base
        let name = stem + "." + fileExtension
        return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true).appendingPathComponent(name)
    }

    func estimatedBytes(source: SourceInfo, aspect: Double, outputDuration: Double) -> Int64 {
        let (w, h) = dimensions(source: source, aspect: aspect)
        let fps = frameRate.fps(source: source.fps)
        let videoBits = Double(w) * Double(h) * Double(fps) * quality.bpp * max(outputDuration, 0)
        let audioBits = includeAudio ? Double(audioBitrate) * max(outputDuration, 0) : 0
        return Int64((videoBits + audioBits) / 8)
    }
}
