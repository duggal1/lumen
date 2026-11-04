import Foundation
import CryptoKit

private actor MediaDigestCache {
    private struct Fingerprint: Hashable {
        var path: String
        var size: Int
        var modified: TimeInterval
    }

    static let shared = MediaDigestCache()
    private var values: [Fingerprint: Data] = [:]
    private var order: [Fingerprint] = []

    func digest(for media: URL) throws -> Data {
        let attributes = try media.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fingerprint = Fingerprint(path: media.standardizedFileURL.path, size: attributes.fileSize ?? 0,
                                      modified: attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)
        if let value = values[fingerprint] { return value }

        let handle = try FileHandle(forReadingFrom: media)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = Data(hasher.finalize())
        values[fingerprint] = digest
        order.append(fingerprint)
        if order.count > 16 { values.removeValue(forKey: order.removeFirst()) }
        return digest
    }
}

enum AnalysisCache {
    static func key<P: Encodable & Sendable>(media: URL, analyzer: String, version: Int, parameters: P) async throws -> String {
        var fingerprint = try await MediaDigestCache.shared.digest(for: media)
        fingerprint.append(Data("\(analyzer):\(version):".utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        fingerprint.append(try encoder.encode(parameters))
        return SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
    }

    static func load<Value: Decodable>(_ type: Value.Type, key: String, directory: URL) -> Value? {
        let url = fileURL(key, directory: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let value = try? JSONDecoder().decode(type, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return value
    }

    static func save<Value: Encodable>(_ value: Value, key: String, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL(key, directory: directory), options: .atomic)
    }

    private static func fileURL(_ key: String, directory: URL) -> URL {
        precondition(key.count == 64 && key.allSatisfy(\.isHexDigit))
        return directory.appendingPathComponent("\(key).json", isDirectory: false)
    }
}
