import Foundation

/// Sidecar written beside an export that used the independent cursor layer.
///
/// The cursor-only movie (`<name>.cursor.mov`, ProRes 4444 with alpha) keeps
/// the pointer on its own track. This sidecar records the exact contract that
/// track was rendered against — duration, frame rate, canvas size — so an
/// external editor can replace the screen track with fresh footage while the
/// cursor layer is reused unchanged.
public struct CursorRelinkSidecar: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var projectName: String
    public var screenFile: String
    public var cursorFile: String
    public var duration: Double
    public var fps: Int
    public var width: Int, height: Int
    public init(projectName: String, screenFile: String, cursorFile: String,
                duration: Double, fps: Int, width: Int, height: Int) {
        self.projectName = projectName; self.screenFile = screenFile; self.cursorFile = cursorFile
        self.duration = duration; self.fps = fps; self.width = width; self.height = height
    }
}

public enum CursorRelink {
    /// `<stem>.cursor-relink.json`, next to the main export — same stem as the
    /// `<stem>.cursor.mov` writer in `Exporter.cursorLayer`.
    public static func sidecarURL(mainExport: URL) -> URL {
        mainExport.deletingPathExtension().appendingPathExtension("cursor-relink.json")
    }

    public static func make(projectName: String, mainExport: URL, cursorFile: URL,
                            duration: Double, fps: Int, width: Int, height: Int) -> CursorRelinkSidecar {
        CursorRelinkSidecar(projectName: projectName,
                            screenFile: mainExport.lastPathComponent,
                            cursorFile: cursorFile.lastPathComponent,
                            duration: duration, fps: fps, width: width, height: height)
    }

    /// Writes the sidecar next to the main export. Returns its URL.
    @discardableResult
    public static func writeSidecar(mainExport: URL, cursorFile: URL, duration: Double,
                                    fps: Int, width: Int, height: Int) throws -> URL {
        let sidecar = make(projectName: mainExport.deletingPathExtension().lastPathComponent,
                           mainExport: mainExport, cursorFile: cursorFile,
                           duration: duration, fps: fps, width: width, height: height)
        let url = sidecarURL(mainExport: mainExport)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: url, options: .atomic)
        return url
    }

    public static func read(from url: URL) throws -> CursorRelinkSidecar {
        try JSONDecoder().decode(CursorRelinkSidecar.self, from: Data(contentsOf: url))
    }

    /// Problems that would make stacking the saved cursor on a replacement
    /// screen visibly wrong. Empty means the replacement is interchangeable.
    public static func validate(_ sidecar: CursorRelinkSidecar,
                                screenDuration: Double, screenFPS: Int) -> [String] {
        var issues: [String] = []
        if sidecar.screenFile.isEmpty { issues.append("missing screen file name") }
        if sidecar.cursorFile.isEmpty { issues.append("missing cursor file name") }
        if sidecar.fps != screenFPS {
            issues.append("frame rate mismatch: cursor \(sidecar.fps) fps, screen \(screenFPS) fps")
        }
        let tolerance = screenFPS > 0 ? 1.0 / Double(screenFPS) : 0.02
        if abs(sidecar.duration - screenDuration) > tolerance {
            issues.append("duration mismatch: cursor \(sidecar.duration)s, screen \(screenDuration)s")
        }
        return issues
    }

    /// Short instructions an editor can follow without Lumen.
    public static func instructions(_ sidecar: CursorRelinkSidecar) -> String {
        """
Replacing the screen while keeping the cursor (\(sidecar.projectName))

1. Import `\(sidecar.screenFile)` (the Lumen export) and `\(sidecar.cursorFile)` (ProRes 4444, alpha).
2. Put the cursor movie on the track ABOVE the screen. Set its blend/alpha to overlay (screen) so the transparent areas drop out.
3. New screen footage must be \(sidecar.width)x\(sidecar.height) at \(sidecar.fps) fps, \(sidecar.duration)s long, starting at frame 0 — same as the sidecar contract.
4. Replace the screen track underneath. Leave the cursor track untouched.
"""
    }
}
