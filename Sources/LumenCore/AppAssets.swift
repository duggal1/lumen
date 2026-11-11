import Foundation

public enum AppAssets {
    public static func directory(bundlePath: String, sourcePaths: [String]) -> URL? {
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent(bundlePath)]
            + sourcePaths.map { checkout.appendingPathComponent($0) }
            + sourcePaths.map { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent($0) }
        return candidates.compactMap { $0 }.first {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory) && directory.boolValue
        }
    }
}
