import Foundation
import os
import LumenCore

/// Capability grants, the app allow-list, the folder allow-list and the
/// bearer token, all in one 0600 file the human owns.
///
/// `actuate` and `network` are NEVER granted by default: an agent that can
/// move a mouse or reach the internet needs an explicit, revocable approval.
public final class Policy: @unchecked Sendable {
    public struct Client: Codable, Sendable, Equatable {
        public var capabilities: [String] = ["read"]
        public var bundleIDs: [String] = []
        public var paths: [String] = []
        // AGENT: the Agents tab needs durable identity details and last-seen time for each peer.
        public var path: String?
        public var signingID: String?
        public var lastSeen: Double?
        public init() {}

        private enum CodingKeys: String, CodingKey { case capabilities, bundleIDs, paths, path, signingID, lastSeen }

        // AGENT: old policy files have no peer metadata and must retain their existing grants.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? ["read"]
            bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? []
            paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
            path = try c.decodeIfPresent(String.self, forKey: .path)
            signingID = try c.decodeIfPresent(String.self, forKey: .signingID)
            lastSeen = try c.decodeIfPresent(Double.self, forKey: .lastSeen)
        }
    }

    public struct ManagedClient: Sendable, Equatable, Identifiable {
        public let key: String
        public let path: String?
        public let signingID: String?
        public let lastSeen: Double?
        public let capabilities: [String]
        public let bundleIDs: [String]
        public let paths: [String]
        public var id: String { key }
    }

    private struct Store: Codable {
        var clients: [String: Client] = [:]
        var token: String = ""
    }

    public let fileURL: URL
    private let store = OSAllocatedUnfairLock<Store>(initialState: Store())
    private let loadedAt = OSAllocatedUnfairLock<Date?>(initialState: nil)

    public init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL ?? base.appendingPathComponent("Lumen", isDirectory: true)
            .appendingPathComponent("agent-policy.json")
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            store.withLock { $0 = decoded }
        } else {
            store.withLock { $0.token = Self.makeToken() }
            persist()
        }
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    /// Re-reads the policy file when it changed on disk, so a grant made by
    /// the human takes effect in a daemon that is already running.
    private func refreshIfChanged() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modified = (attributes?[.modificationDate] as? Date) ?? Date.distantPast
        let known = loadedAt.withLock { $0 }
        guard known != modified else { return }
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Store.self, from: data) {
            store.withLock { $0 = decoded }
            loadedAt.withLock { $0 = modified }
        }
    }

    private func persist() {
        let snapshot = store.withLock { $0 }
        loadedAt.withLock { $0 = nil }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    // MARK: Queries

    public func allowed(_ capability: Capability, for client: String) -> Bool {
        refreshIfChanged()
        return store.withLock { $0.clients[client]?.capabilities ?? ["read"] }
            .contains(capability.rawValue)
    }

    public func bundleAllowed(_ bundleID: String, for client: String) -> Bool {
        refreshIfChanged()
        return store.withLock { $0.clients[client]?.bundleIDs ?? [] }.contains(bundleID)
    }

    public func allowedPaths(for client: String) -> [String] {
        refreshIfChanged()
        var list = store.withLock { $0.clients[client]?.paths ?? [] }
        // The project library is always writable: it is Lumen's own folder.
        if let library = libraryURL { list.append(library.path) }
        return list
    }

    /// The Lumen library folder, when the runtime knows it.
    public var libraryURL: URL? { defaultLibrary }

    private var defaultLibrary: URL? {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lumen")
    }

    /// Confines a path to the client's approved roots. Symlinks are resolved
    /// before the check, so `../` and link tricks cannot escape.
    public func resolvePath(_ path: String, for client: String) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        let roots = allowedPaths(for: client).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        }
        guard roots.contains(where: { resolved.path == $0.path || resolved.path.hasPrefix($0.path + "/") }) else {
            throw ToolError.pathNotAllowed(path)
        }
        return resolved
    }

    /// The capabilities currently granted to a client.
    public func grantedCapabilities(for client: String) -> [String] {
        refreshIfChanged()
        return store.withLock { $0.clients[client]?.capabilities ?? ["read"] }
    }

    /// The bundle ids a client may act on.
    public func grantedBundleIDs(for client: String) -> [String] {
        refreshIfChanged()
        return store.withLock { $0.clients[client]?.bundleIDs ?? [] }
    }

    /// The folders a client may read and write.
    public func grantedPaths(for client: String) -> [String] {
        refreshIfChanged()
        return store.withLock { $0.clients[client]?.paths ?? [] }
    }

    /// Known peers with their current local grants.
    // AGENT: the settings surface needs a stable client inventory instead of UI-only guesses.
    public func knownClients() -> [ManagedClient] {
        refreshIfChanged()
        return store.withLock { s in
            s.clients.map { key, client in
                ManagedClient(key: key, path: client.path, signingID: client.signingID,
                              lastSeen: client.lastSeen, capabilities: client.capabilities,
                              bundleIDs: client.bundleIDs, paths: client.paths)
            }.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        }
    }

    /// Records the kernel-verified peer that opened a socket connection.
    // AGENT: client names sent in initialize are untrusted, so grant inventory records kernel identity only.
    public func touch(_ peer: PeerIdentity) {
        store.withLock { s in
            var client = s.clients[peer.key] ?? Client()
            client.path = peer.path
            client.signingID = peer.signingID
            client.lastSeen = Date().timeIntervalSince1970
            s.clients[peer.key] = client
        }
        persist()
    }

    /// Removes every grant for a client.
    public func reset(client: String) {
        store.withLock { $0.clients.removeValue(forKey: client) }
        persist()
    }

    /// Removes every capability, app and folder grant while retaining peer history.
    // AGENT: a single revocation action must close every previously approved scope.
    public func revokeAll() {
        store.withLock { s in
            for key in Array(s.clients.keys) {
                guard var client = s.clients[key] else { continue }
                client.capabilities = ["read"]
                client.bundleIDs = []
                client.paths = []
                s.clients[key] = client
            }
        }
        persist()
    }

    /// The shared agent secret. One source of truth: the same token protects
    /// the optional HTTP transport and the in-app MCP server.
    public var bearerToken: String { AgentCredentials.token() }

    // MARK: Mutations

    public func grant(client: String, capabilities: [String]? = nil, bundleIDs: [String]? = nil, paths: [String]? = nil) {
        store.withLock { s in
            var c = s.clients[client] ?? Client()
            if let capabilities { c.capabilities = capabilities }
            if let bundleIDs { c.bundleIDs = bundleIDs }
            if let paths { c.paths = paths }
            s.clients[client] = c
        }
        persist()
    }

    public func revoke(client: String, capabilities: [String]) {
        store.withLock { s in
            var c = s.clients[client] ?? Client()
            c.capabilities = c.capabilities.filter { !capabilities.contains($0) }
            s.clients[client] = c
        }
        persist()
    }

    /// A constant-time comparison so a token cannot be guessed by timing.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        AgentCredentials.constantTimeEquals(a, b)
    }
}

/// The single funnel every agent-supplied path must pass through.
///
/// AGENT: tools used to accept raw paths, so a background image could read any
/// file the user owns and `screenshot` could write anywhere. Confinement now
/// lives in one place instead of being remembered per tool.
public struct PathGuard: Sendable {
    public let policy: Policy
    public let client: String

    public static let imageExt: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
    public static let audioExt: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "aiff", "caf"]
    public static let videoExt: Set<String> = ["mov", "mp4", "m4v"]

    public init(policy: Policy, client: String) {
        self.policy = policy
        self.client = client
    }

    /// Resolves and confines a path, optionally checking its extension.
    public func path(_ p: String, ext: Set<String>? = nil) throws -> URL {
        let url = try policy.resolvePath(p, for: client)
        if let ext, !ext.contains(url.pathExtension.lowercased()) {
            throw ToolError.invalidArguments(
                "\(url.lastPathComponent): expected one of \(ext.sorted().joined(separator: ", ")).")
        }
        return url
    }

    /// A path the tool is about to CREATE (the file need not exist yet).
    public func writablePath(_ p: String, ext: Set<String>? = nil) throws -> URL {
        let expanded = (p as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let roots = policy.allowedPaths(for: client).map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath()
        }
        guard roots.contains(where: { parent.path == $0.path || parent.path.hasPrefix($0.path + "/") }) else {
            throw ToolError.pathNotAllowed(p)
        }
        if let ext, !ext.contains(url.pathExtension.lowercased()) {
            throw ToolError.invalidArguments(
                "\(url.lastPathComponent): expected one of \(ext.sorted().joined(separator: ", ")).")
        }
        return url
    }
}
