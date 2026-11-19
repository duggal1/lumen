import Foundation

/// Persisted tuning for activity-driven auto-zoom. Value type; owned by Project, safe to share across tasks.
///
/// Defaults are the shipping behaviour. `setActivitySettings` changes only these
/// fields; the Director replans from the same grids when any of them changes.
public struct ActivitySettings: Codable, Sendable, Equatable {
    public var enabled = true
    /// Cell energy at or above this value counts as changed (about 5 luma levels).
    public var threshold: UInt8 = 20
    /// Fewer changed cells than this is a lone cursor/loader pixel, not a subject.
    public var minCells = 2
    /// A change covering more of the frame is navigation or scrolling, not a subject.
    public var maxAreaFraction = 0.55
    /// Extra room around the changed region, as a fraction of its size.
    public var padFraction = 0.35
    public var maxScale = 1.8
    /// Below this magnification a zoom is not worth a shot.
    public var minTrigger = 1.25
    public var onsetSamples = 2
    public var settleHold = 0.6
    public var minHold = 1.6
    public var maxActiveSeconds = 8.0
    public var lead = 0.10
    /// Cursor neighbourhood, in grid cells, suppressed when only hovering.
    public var hoverRadiusCells = 2.5
    public var zoomOnLoaders = true
    public var suppressAfterKey = 0.4
    public var scrollWindow = 0.3

    public init() {}
}

/// Sparse patch for `setActivitySettings`; only non-nil fields replace persisted values. Value type, Sendable.
public struct ActivitySettingsPatch: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var threshold: UInt8?
    public var minCells: Int?
    public var maxAreaFraction: Double?
    public var padFraction: Double?
    public var maxScale: Double?
    public var minTrigger: Double?
    public var onsetSamples: Int?
    public var settleHold: Double?
    public var minHold: Double?
    public var maxActiveSeconds: Double?
    public var lead: Double?
    public var hoverRadiusCells: Double?
    public var zoomOnLoaders: Bool?
    public var suppressAfterKey: Double?
    public var scrollWindow: Double?

    public init(enabled: Bool? = nil, threshold: UInt8? = nil, minCells: Int? = nil,
                maxAreaFraction: Double? = nil, padFraction: Double? = nil,
                maxScale: Double? = nil, minTrigger: Double? = nil, onsetSamples: Int? = nil,
                settleHold: Double? = nil, minHold: Double? = nil, maxActiveSeconds: Double? = nil,
                lead: Double? = nil, hoverRadiusCells: Double? = nil, zoomOnLoaders: Bool? = nil,
                suppressAfterKey: Double? = nil, scrollWindow: Double? = nil) {
        self.enabled = enabled; self.threshold = threshold; self.minCells = minCells
        self.maxAreaFraction = maxAreaFraction; self.padFraction = padFraction
        self.maxScale = maxScale; self.minTrigger = minTrigger; self.onsetSamples = onsetSamples
        self.settleHold = settleHold; self.minHold = minHold; self.maxActiveSeconds = maxActiveSeconds
        self.lead = lead; self.hoverRadiusCells = hoverRadiusCells; self.zoomOnLoaders = zoomOnLoaders
        self.suppressAfterKey = suppressAfterKey; self.scrollWindow = scrollWindow
    }

    /// Applies this patch to a base settings value without mutating either input.
    public func applying(to base: ActivitySettings) -> ActivitySettings {
        var s = base
        if let enabled { s.enabled = enabled }
        if let threshold { s.threshold = threshold }
        if let minCells { s.minCells = minCells }
        if let maxAreaFraction { s.maxAreaFraction = maxAreaFraction }
        if let padFraction { s.padFraction = padFraction }
        if let maxScale { s.maxScale = maxScale }
        if let minTrigger { s.minTrigger = minTrigger }
        if let onsetSamples { s.onsetSamples = onsetSamples }
        if let settleHold { s.settleHold = settleHold }
        if let minHold { s.minHold = minHold }
        if let maxActiveSeconds { s.maxActiveSeconds = maxActiveSeconds }
        if let lead { s.lead = lead }
        if let hoverRadiusCells { s.hoverRadiusCells = hoverRadiusCells }
        if let zoomOnLoaders { s.zoomOnLoaders = zoomOnLoaders }
        if let suppressAfterKey { s.suppressAfterKey = suppressAfterKey }
        if let scrollWindow { s.scrollWindow = scrollWindow }
        return s
    }
}
