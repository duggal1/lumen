import Foundation
import CoreGraphics
import LumenProject

/// One 10 Hz energy sample from the Metal grid pass: `48 * 27` bytes, row-major.
/// Owned by Analysis, consumed by the Director; pure value, safe to share.
public struct ActivityGridPayload: Codable, Sendable, Equatable {
    public var t: Double
    public var cells: [UInt8]

    public init(t: Double, cells: [UInt8]) {
        self.t = t; self.cells = cells
    }
}

/// Cached output of the activity analyzer for one screen recording. Source
/// seconds and source pixels. Stored through `AnalysisCache` (JSON, keyed by
/// media fingerprint + analyzer + version + canonical parameters).
public struct ActivityCache: Codable, Sendable, Equatable {
    public var grids: [ActivityGridPayload]
    public var width: Int
    public var height: Int

    public init(grids: [ActivityGridPayload] = [], width: Int = 0, height: Int = 0) {
        self.grids = grids; self.width = width; self.height = height
    }
}

public extension ActivityCache {
    /// Reads a cached payload using the existing `AnalysisCache` key scheme.
    static func load(key: String, directory: URL) -> ActivityCache? {
        AnalysisCache.load(ActivityCache.self, key: key, directory: directory)
    }

    /// Writes a cached payload using the existing `AnalysisCache` key scheme.
    func save(key: String, directory: URL) throws {
        try AnalysisCache.save(self, key: key, directory: directory)
    }
}

/// Loads-or-computes a cached activity payload using the existing `AnalysisCache`
/// key scheme. Owns no state; safe to call from one analysis task at a time.
public enum ActivityFetch {
    private struct Parameters: Codable, Sendable {
        var offset: Double
        var fps: Double
    }

    public static func cached(url: URL, directory: URL, hz: Double = 10,
                              produce: @Sendable () async throws -> ActivityCache) async -> (ActivityCache?, String?) {
        do {
            try Task.checkCancellation()
            let key = try await AnalysisCache.key(media: url, analyzer: ActivityAnalyzer.analyzerID,
                                                  version: ActivityAnalyzer.analyzerVersion,
                                                  parameters: Parameters(offset: 0, fps: hz))
            if let cached = ActivityCache.load(key: key, directory: directory) { return (cached, nil) }
            let value = try await produce()
            try Task.checkCancellation()
            try value.save(key: key, directory: directory)
            return (value, nil)
        } catch is CancellationError {
            return (nil, "Cancelled")
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

/// Bridges the grid payload to the legacy `ActivityPoint` stream still read by
/// the speed-ramp planner. Pure and deterministic; no wall clock or randomness.
public enum ActivityPointBridge {
    /// Derives coarse changed-region points from consecutive energy grids.
    public static func points(from cache: ActivityCache) -> [ActivityPoint] {
        let gw = 48, gh = 27
        guard cache.width > 0, cache.height > 0 else { return [] }
        var out: [ActivityPoint] = []
        var previous: [UInt8]?
        for g in cache.grids where g.cells.count == gw * gh {
            defer { previous = g.cells }
            guard let prev = previous else { continue }
            var minX = gw, minY = gh, maxX = -1, maxY = -1, count = 0
            for i in 0..<(gw * gh) where Int(g.cells[i]) - Int(prev[i]) >= 20 {
                let x = i % gw, y = i / gw
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1
            }
            guard count >= 3 else { continue }
            let sx = Double(cache.width) / Double(gw)
            let sy = Double(cache.height) / Double(gh)
            let rect = CGRect(x: Double(minX) * sx, y: Double(minY) * sy,
                              width: Double(maxX - minX + 1) * sx,
                              height: Double(maxY - minY + 1) * sy)
            out.append(ActivityPoint(t: g.t, x: rect.midX, y: rect.midY,
                                     region: rect, coverage: Double(count) / Double(gw * gh)))
        }
        return out
    }
}
