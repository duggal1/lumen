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
        public var capabilities: [String] = ["read", "record", "edit", "export"]
        public var bundleIDs: [String] = []
        public var paths: [String] = []
        public init() {}
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
        return store.withLock { $0.clients[client]?.capabilities ?? ["read", "record", "edit", "export"] }
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
        return store.withLock { $0.clients[client]?.capabilities ?? ["read", "record", "edit", "export"] }
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

    /// Removes every grant for a client.
    public func reset(client: String) {
        store.withLock { $0.clients.removeValue(forKey: client) }
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
