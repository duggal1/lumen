import Foundation

/// Models live in ~/Library/Application Support/Lumen/Models/<folder>. Nothing is downloaded by the app.
public enum ModelStore {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumen/Models", isDirectory: true)
    }
    public static func directory(_ s: MoonshineSize) -> URL { root.appendingPathComponent(s.folder, isDirectory: true) }
    public static func resolved(_ s: MoonshineSize) -> URL? { modelDir(in: directory(s)) }
    public static func isInstalled(_ s: MoonshineSize) -> Bool { resolved(s) != nil }

    /// The folder that actually holds the model files (the user may have picked a parent). ASSUMPTION: model files are *.ort.
    static func modelDir(in url: URL, depth: Int = 3) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        if items.contains(where: { $0.pathExtension == "ort" }) { return url }
        guard depth > 0 else { return nil }
        for d in items where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let m = modelDir(in: d, depth: depth - 1) { return m }
        }
        return nil
    }

    public static func importFolder(_ src: URL, as s: MoonshineSize) throws {
        guard let found = modelDir(in: src) else { throw SpeechError.modelMissing(src.path) }
        let dst = directory(s)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: found, to: dst)
    }
}

/// Keeps one loaded model alive across recordings and unloads it 90 s after the last user. Blocking calls are made from worker threads only.
final class RuntimeCache: @unchecked Sendable {
    static let shared = RuntimeCache()
    private let lock = NSLock()
    private var cur: MoonshineRuntime?
    private var users = 0, generation = 0

    func acquire(_ size: MoonshineSize) throws -> MoonshineRuntime {
        lock.lock(); defer { lock.unlock() }
        generation += 1; users += 1
        if let c = cur, c.size == size { return c }
        cur = nil
        guard let dir = ModelStore.resolved(size) else { users -= 1; throw SpeechError.modelMissing(ModelStore.directory(size).path) }
        do { let r = try MoonshineRuntime(directory: dir, size: size); cur = r; return r } catch { users -= 1; throw error }
    }
    func release() {
        lock.lock(); users -= 1; let g = generation; lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90) { [self] in
            lock.lock(); if users == 0, generation == g { cur = nil }; lock.unlock()
        }
    }
}
