import Foundation

/// When the crop opens back up to the whole browser window.
/// Ownership: persisted intent in `Timeline`. Threading: value type, `Sendable`.
public enum UncropPolicy: String, Codable, Sendable, Equatable {
    /// Typing or clicking in browser chrome (address bar, tabs) only. Typing in
    /// a page form keeps the crop because the page content is the subject.
    case chromeTyping
    /// Any typing reveals the chrome.
    case anyTyping
    case never
}

/// Source-time crop mode. `full` shows the source, `content` the AXWebArea,
/// `window` the browser window (used for the uncropped reveal).
/// Ownership: persisted intent and derived state. Threading: value, `Sendable`.
public enum CropMode: String, Codable, Sendable, Equatable {
    case full, content, window
}

/// A manual crop span that replaces the automatic mode inside `[start, end)`.
/// Times are SOURCE seconds. Ownership: persisted intent. Threading: value type.
public struct CropOverride: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var mode: CropMode

    public init(id: UUID = UUID(), start: Double, end: Double, mode: CropMode) {
        self.id = id; self.start = start; self.end = end; self.mode = mode
    }
}

/// All tuning knobs for browser-content crop. Persisted in `Timeline` intent;
/// defaults are the tuned values. Every field is in source seconds or source
/// pixels. Ownership: persisted intent. Threading: value type, `Sendable`.
public struct CropSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var uncrop: UncropPolicy = .chromeTyping
    /// Hides the 1 px divider and AX rounding at the page edge.
    public var insetPx = 2.0
    public var minWebWidthPx = 480.0
    public var minWebHeightPx = 270.0
    public var uncropLead = 0.25
    public var uncropDuration = 0.60
    public var recropDuration = 0.70
    public var appSwitchDuration = 0.50
    public var holdAfterTyping = 0.80
    public var holdAfterUIClick = 1.20
    public var minDwell = 0.80
    public var trackSigma = 0.12
    public var overrides: [CropOverride] = []

    public init() {}
}

/// Partial update for `Command.setCropSettings`; `nil` means "leave unchanged".
/// Ownership: command payload. Threading: value type, `Sendable`.
public struct CropSettingsPatch: Codable, Sendable, Equatable {
    public var enabled: Bool?
    public var uncrop: UncropPolicy?
    public var insetPx: Double?
    public var minWebWidthPx: Double?
    public var minWebHeightPx: Double?
    public var uncropLead: Double?
    public var uncropDuration: Double?
    public var recropDuration: Double?
    public var appSwitchDuration: Double?
    public var holdAfterTyping: Double?
    public var holdAfterUIClick: Double?
    public var minDwell: Double?
    public var trackSigma: Double?

    public init(enabled: Bool? = nil, uncrop: UncropPolicy? = nil, insetPx: Double? = nil,
                minWebWidthPx: Double? = nil, minWebHeightPx: Double? = nil,
                uncropLead: Double? = nil, uncropDuration: Double? = nil,
                recropDuration: Double? = nil, appSwitchDuration: Double? = nil,
                holdAfterTyping: Double? = nil, holdAfterUIClick: Double? = nil,
                minDwell: Double? = nil, trackSigma: Double? = nil) {
        self.enabled = enabled; self.uncrop = uncrop; self.insetPx = insetPx
        self.minWebWidthPx = minWebWidthPx; self.minWebHeightPx = minWebHeightPx
        self.uncropLead = uncropLead; self.uncropDuration = uncropDuration
        self.recropDuration = recropDuration; self.appSwitchDuration = appSwitchDuration
        self.holdAfterTyping = holdAfterTyping; self.holdAfterUIClick = holdAfterUIClick
        self.minDwell = minDwell; self.trackSigma = trackSigma
    }

    /// Applies only the supplied fields. Pure; the caller validates finiteness.
    public func apply(to s: CropSettings) -> CropSettings {
        var r = s
        if let enabled { r.enabled = enabled }
        if let uncrop { r.uncrop = uncrop }
        if let insetPx { r.insetPx = insetPx }
        if let minWebWidthPx { r.minWebWidthPx = minWebWidthPx }
        if let minWebHeightPx { r.minWebHeightPx = minWebHeightPx }
        if let uncropLead { r.uncropLead = uncropLead }
        if let uncropDuration { r.uncropDuration = uncropDuration }
        if let recropDuration { r.recropDuration = recropDuration }
        if let appSwitchDuration { r.appSwitchDuration = appSwitchDuration }
        if let holdAfterTyping { r.holdAfterTyping = holdAfterTyping }
        if let holdAfterUIClick { r.holdAfterUIClick = holdAfterUIClick }
        if let minDwell { r.minDwell = minDwell }
        if let trackSigma { r.trackSigma = trackSigma }
        return r
    }
}
