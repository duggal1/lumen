import Foundation
import os

/// Every tool call is written to a JSONL audit log: client id, tool, an
/// argument hash (never the raw arguments, which can contain file paths and
/// text), the result and the timestamp.
public final class AuditLog: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public var timestamp: Double
        public var client: String
        public var tool: String
        public var argsHash: String
        public var ok: Bool
        public var detail: String?
    }

    public let fileURL: URL
    private let lock = OSAllocatedUnfairLock(initialState: 0)

    public init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL ?? base.appendingPathComponent("Lumen", isDirectory: true)
            .appendingPathComponent("agent-audit.jsonl")
    }

    public func record(client: String, tool: String, arguments: JSONValue, ok: Bool, detail: String? = nil) {
        let entry = Entry(timestamp: Date().timeIntervalSince1970, client: client, tool: tool,
                          argsHash: Self.hash(arguments.jsonText), ok: ok, detail: detail)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let line = data + Data([0x0A])
        // AGENT: freeze the record before serialized I/O so Swift 6 can safely capture it while appends stay atomic.
        lock.withLock { _ in
            let files = FileManager.default
            try? files.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? files.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size + Int64(line.count) > 10 * 1024 * 1024 {
                let previous = fileURL.appendingPathExtension("1")
                try? files.removeItem(at: previous)
                try? files.moveItem(at: fileURL, to: previous)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile(); handle.write(line); try? handle.close()
            } else {
                try? line.write(to: fileURL, options: .atomic)
                try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
        }
    }

    /// Stable, non-reversible hash of the arguments.
    public static func hash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
