import Foundation
import os
import Darwin

/// Every tool call is written as a JSONL record with selected non-secret context.
public final class AuditLog: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public var timestamp: Double
        public var client: String
        public var tool: String
        // AGENT: the audit log records actionable context without storing paths or user-entered text.
        public var projectID: String?
        public var bundleID: String?
        public var operationKinds: [String]
        public var counts: [String: Int]
        public var typedTextLength: Int
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
        let summary = Self.summary(arguments)
        let entry = Entry(timestamp: Date().timeIntervalSince1970, client: client, tool: tool,
                          projectID: summary.projectID, bundleID: summary.bundleID,
                          operationKinds: summary.operationKinds, counts: summary.counts,
                          typedTextLength: summary.typedTextLength, ok: ok, detail: detail)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let line = data + Data([0x0A])
        // AGENT: serialize rotation and the entire append so concurrent audit entries cannot interleave.
        lock.withLock { _ in
            let files = FileManager.default
            try? files.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? files.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size + Int64(line.count) > 10 * 1024 * 1024 {
                let previous = fileURL.appendingPathExtension("1")
                try? files.removeItem(at: previous)
                try? files.moveItem(at: fileURL, to: previous)
            }
            // AGENT: audit records are created with private permissions instead of becoming briefly world-readable.
            let fd = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd) }
            line.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { break }
                    offset += written
                }
            }
        }
    }

    /// Reads a bounded tail for the local Agents settings tab.
    // AGENT: operators need a live local audit view without giving tools a log-reading capability.
    public func recentLines(limit: Int = 80) -> [String] {
        lock.withLock { _ in
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return Array(text.split(whereSeparator: \.isNewline).suffix(max(1, limit)).map(String.init))
        }
    }

    /// Extracts only identifiers, operation names, counts, and text length.
    private static func summary(_ arguments: JSONValue) -> (projectID: String?, bundleID: String?, operationKinds: [String], counts: [String: Int], typedTextLength: Int) {
        guard case .object(let fields) = arguments else { return (nil, nil, [], [:], 0) }
        let projectID = fields["project_id"]?.stringValue
        let bundleID = fields["bundle_id"]?.stringValue
        var operationKinds: [String] = []
        var counts: [String: Int] = [:]
        var textLength = 0

        func collect(_ value: JSONValue, parent: String? = nil) {
            switch value {
            case .object(let object):
                if let op = object["op"]?.stringValue, operationKinds.count < 128 {
                    operationKinds.append(String(op.prefix(64)))
                }
                for (key, child) in object {
                    if key == "text", let text = child.stringValue { textLength += text.count }
                    collect(child, parent: key)
                }
            case .array(let values):
                if parent == "ops" { counts["ops"] = values.count }
                if parent == "actions" || parent == "do" { counts["actions"] = (counts["actions"] ?? 0) + values.count }
                if parent == "steps" { counts["steps"] = values.count }
                for child in values { collect(child, parent: parent) }
            default:
                break
            }
        }
        collect(arguments)
        return (projectID, bundleID, operationKinds, counts, textLength)
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
