import Foundation
import LumenCore

/// Markers recorded by the agent (or by a human pressing a marker button) are
/// stored next to the project as `markers.json`. Additive: a project without
/// markers decodes exactly as before.
public struct MarkerFile: Codable, Sendable, Equatable {
    public var version = 1
    /// Host-clock seconds (same clock as `InputEvent.t`).
    public var markers: [CaptureMarker] = []
    public init() {}
}

public extension ProjectBundle {
    /// `markers.json` inside the bundle.
    var markersURL: URL { url.appendingPathComponent("markers.json") }

    func loadMarkers() -> MarkerFile {
        guard let data = try? Data(contentsOf: markersURL),
              let file = try? JSONDecoder().decode(MarkerFile.self, from: data) else { return MarkerFile() }
        return file
    }

    /// Writes the marker sidecar. Atomic, so a crash never leaves a half file.
    @discardableResult
    func saveMarkers(_ file: MarkerFile) throws -> MarkerFile {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: markersURL, options: .atomic)
        return file
    }

    /// Source seconds for a marker, using the project's clock origin.
    /// Markers are stored on the host clock; the timeline works in source
    /// seconds, so every anchor needs this conversion.
    func sourceTime(for marker: CaptureMarker, meta: ProjectMeta) -> Double {
        max(marker.startHostSeconds - meta.clock.originHostSeconds, 0)
    }

    /// Marks in source seconds, ready to be used as edit anchors.
    func sourceMarkers(meta: ProjectMeta) -> [(marker: CaptureMarker, start: Double, end: Double)] {
        let origin = meta.clock.originHostSeconds
        return loadMarkers().markers.map { m in
            (m, max(m.startHostSeconds - origin, 0), max(m.endHostSeconds - origin, 0))
        }
    }
}
