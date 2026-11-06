import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Unsplash

/// Key resolution order: process environment (CI / power users), then the
/// value saved in Settings. Never bundled, never logged.
public enum UnsplashCredentials {
    public static let environmentKey = "LUMEN_UNSPLASH_ACCESS_KEY"
    public static let defaultsKey = "LumenUnsplashAccessKey"

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               stored: String? = UserDefaults.standard.string(forKey: defaultsKey)) -> String? {
        [environment[environmentKey], stored]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

public struct UnsplashPhoto: Codable, Sendable, Identifiable, Equatable {
    public struct URLs: Codable, Sendable, Equatable {

        public var raw: String? = nil, full: String? = nil, regular: String = "", small: String? = nil
        public init() {}
    }
    public struct User: Codable, Sendable, Equatable { public var name: String }
    public var id: String
    public var description: String?
    public var alt_description: String?
    public var width: Int
    public var height: Int
    public var urls: URLs
    public var user: User?

    public var caption: String { alt_description ?? description ?? user?.name ?? "Unsplash photo" }
    public var downloadURL: URL? { URL(string: urls.full ?? urls.regular) }
}

public enum UnsplashError: LocalizedError, Equatable {
    case missingKey, badResponse(Int), noResults, badPayload
    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add an Unsplash access key in Settings, or set LUMEN_UNSPLASH_ACCESS_KEY."
        case .badResponse(let code): "Unsplash returned HTTP \(code)."
        case .noResults: "No photos matched that search."
        case .badPayload: "Unsplash sent an unreadable response."
        }
    }
}

/// Small seam so tests never touch the network.
public protocol PhotoHTTP: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionPhotoHTTP: PhotoHTTP {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UnsplashError.badPayload }
        return (data, http)
    }
}

public struct UnsplashClient: Sendable {
    public var accessKey: String
    public var http: any PhotoHTTP
    public var searchURL = URL(string: "https://api.unsplash.com/search/photos")!

    public init(accessKey: String, http: any PhotoHTTP = URLSessionPhotoHTTP()) {
        self.accessKey = accessKey
        self.http = http
    }

    public func search(_ query: String, perPage: Int = 12, orientation: String = "landscape") async throws -> [UnsplashPhoto] {
        guard !accessKey.isEmpty else { throw UnsplashError.missingKey }
        guard var c = URLComponents(url: searchURL, resolvingAgainstBaseURL: false) else { throw UnsplashError.badPayload }
        c.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "per_page", value: String(max(1, min(perPage, 30)))),
            URLQueryItem(name: "orientation", value: orientation),
        ]
        guard let url = c.url else { throw UnsplashError.badPayload }
        var request = URLRequest(url: url)
        request.setValue("Client-ID \(accessKey)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else { throw UnsplashError.badResponse(response.statusCode) }
        struct Payload: Decodable { var results: [UnsplashPhoto] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { throw UnsplashError.badPayload }
        guard !payload.results.isEmpty else { throw UnsplashError.noResults }
        return payload.results
    }

    public func download(_ photo: UnsplashPhoto) async throws -> Data {
        guard let url = photo.downloadURL else { throw UnsplashError.badPayload }
        var request = URLRequest(url: url)
        request.setValue("Lumen/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode), !data.isEmpty else { throw UnsplashError.badResponse(response.statusCode) }
        return data
    }
}

/// On-disk cache keyed by the remote URL. Unsplash URLs are stable, so the
/// same photo is downloaded once per query result.
public struct PhotoCache: Sendable {
    public let directory: URL

    public init(directory: URL = PhotoCache.defaultDirectory) { self.directory = directory }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumen/PhotoCache", isDirectory: true)
    }

    public func file(for remote: URL) -> URL {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let ext = remote.pathExtension.isEmpty ? "jpg" : remote.pathExtension
        return directory.appendingPathComponent(digest).appendingPathExtension(ext)
    }

    public func existing(for remote: URL) -> URL? {
        let url = file(for: remote)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func store(_ data: Data, for remote: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = file(for: remote)
        try data.write(to: url, options: .atomic)
        return url
    }
}

public actor PhotoBackgroundService {
    private let client: UnsplashClient
    private let cache: PhotoCache

    public init(client: UnsplashClient, cache: PhotoCache = PhotoCache()) {
        self.client = client
        self.cache = cache
    }

    /// Search, download once, return a local file ready for `Style.backgroundImagePath`.
    public func fetch(query: String) async throws -> URL {
        let photos = try await client.search(query)
        guard let photo = photos.first, let remote = photo.downloadURL else { throw UnsplashError.noResults }
        if let cached = cache.existing(for: remote) { return cached }
        let data = try await client.download(photo)
        return try cache.store(data, for: remote)
    }
}

// MARK: - Inspector row

/// One row: type a subject, get a photo. Local file remains available for
/// people who already have an image. No gallery, no panel, no feature creep.
struct PhotoBackgroundRow: View {
    let model: EditorModel
    @State private var query = "abstract gradient"
    @State private var busy = false
    @State private var error: String?
    @State private var service: PhotoBackgroundService?

    var body: some View {
        VStack(spacing: 0) {
            Row(label: "Photo") {
                HStack(spacing: 8) {
                    TextField("Unsplash search", text: $query)
                        .textFieldStyle(.plain)
                        .font(AppType.body)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: Radius.field).fill(Tok.well))
                        .frame(width: 150)
                        .onSubmit { Task { await find() } }
                    LButton(title: busy ? "Finding…" : "Find", icon: "magnifyingglass", kind: .secondary) {
                        Task { await find() }
                    }
                    .disabled(busy)
                    LButton(title: "Choose…", kind: .quiet) { chooseLocal() }
                }
            }
            if let path = model.timeline.style.backgroundImagePath {
                Row(label: "File") {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(AppType.body).foregroundStyle(Tok.text2).lineLimit(1)
                }
            }
            if let error {
                Text(error).font(AppType.caption).foregroundStyle(Tok.accentText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func find() async {
        error = nil
        let key = UnsplashCredentials.resolve()
        guard let key else { error = UnsplashError.missingKey.localizedDescription; return }
        if service == nil {
            service = PhotoBackgroundService(client: UnsplashClient(accessKey: key))
        }
        busy = true
        defer { busy = false }
        do {
            guard let service else { return }
            let url = try await service.fetch(query: query)
            model.edit { $0.style.setPhotoBackground(url.path) }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func chooseLocal() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use photo"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil
        model.edit { $0.style.setPhotoBackground(url.path) }
    }
}
