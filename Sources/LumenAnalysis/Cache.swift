import Foundation
import CryptoKit

enum AnalysisCache {
    static func key<P: Encodable>(media: URL, analyzer: String, version: Int, parameters: P) throws -> String {
        let values = try media.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? 0
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        var fingerprint = Data("\(size):\(modified):\(analyzer):\(version):".utf8)
        let handle = try FileHandle(forReadingFrom: media)
        defer { try? handle.close() }
        let chunk = 64 * 1024
        fingerprint.append(try handle.read(upToCount: chunk) ?? Data())
        if size > chunk {
            try handle.seek(toOffset: UInt64(max(size - chunk, 0)))
            fingerprint.append(try handle.read(upToCount: chunk) ?? Data())
        }
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
