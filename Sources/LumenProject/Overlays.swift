import Foundation
import LumenCore

public enum CutOrigin: String, Codable, Sendable { case manual, autoTidy, transcript }
/// Removed span, SOURCE seconds.
public struct CutRange: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var origin: CutOrigin
    public init(id: UUID = UUID(), start: Double, end: Double, origin: CutOrigin = .manual) {
        self.id = id; self.start = start; self.end = end; self.origin = origin
    }
}

public enum MaskMode: String, Codable, CaseIterable, Sendable {
    case blur, pixelate, solid

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "blend" { self = .pixelate }
        else if let mode = Self(rawValue: value) { self = mode }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown mask mode: \(value)") }
    }
}
/// Rect in SOURCE pixels at SOURCE time t.
public struct MaskKey: Codable, Equatable, Sendable {
    public var t: Double, x: Double, y: Double, w: Double, h: Double
    public init(t: Double, x: Double, y: Double, w: Double, h: Double) { self.t = t; self.x = x; self.y = y; self.w = w; self.h = h }
}
public struct Mask: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var mode: MaskMode
    public var keys: [MaskKey]
    public var origin: Origin
    public var approved: Bool
    public var category: String?
    public var padding: Double
    public init(id: UUID = UUID(), start: Double, end: Double, mode: MaskMode = .blur, keys: [MaskKey], origin: Origin = .manual,
                approved: Bool = true, category: String? = nil, padding: Double = 6) {
        self.id = id; self.start = start; self.end = end; self.mode = mode; self.keys = keys; self.origin = origin
        self.approved = approved; self.category = category; self.padding = padding
    }
}

public enum HighlightStyle: String, Codable, CaseIterable, Sendable { case dim, outline, glow }
public struct Highlight: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var x: Double, y: Double, w: Double, h: Double          // source px
    public var style: HighlightStyle, dim: Double
    public init(id: UUID = UUID(), start: Double, end: Double, x: Double, y: Double, w: Double, h: Double, style: HighlightStyle = .dim, dim: Double = 0.55) {
        self.id = id; self.start = start; self.end = end; self.x = x; self.y = y; self.w = w; self.h = h; self.style = style; self.dim = dim
    }
}
/// Magnified glass over the canvas. `x/y` are the SOURCE pixel that the glass
/// looks at (ignored when `follow`), `cx/cy` are the canvas-normalized centre
/// where the glass itself sits. Both are persisted so a loupe can be dragged.
public struct Loupe: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var x: Double, y: Double                                // source px (ignored when follow)
    public var follow: Bool
    public var radius: Double                                      // fraction of canvas width
    public var magnification: Double
    public var round: Bool
    public var cx: Double, cy: Double                              // canvas-normalized glass centre
    public var border: Double                                      // fraction of canvas width
    public var shadow: Double
    public init(id: UUID = UUID(), start: Double, end: Double, x: Double = 0, y: Double = 0, follow: Bool = true, radius: Double = 0.12,
                magnification: Double = 2, round: Bool = true, cx: Double = 0.22, cy: Double = 0.74,
                border: Double = 0.006, shadow: Double = 0.45) {
        self.id = id; self.start = start; self.end = end; self.x = x; self.y = y; self.follow = follow
        self.radius = radius; self.magnification = magnification; self.round = round
        self.cx = cx; self.cy = cy; self.border = border; self.shadow = shadow
    }
    enum CodingKeys: String, CodingKey { case id, start, end, x, y, follow, radius, magnification, round, cx, cy, border, shadow }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start); end = try c.decode(Double.self, forKey: .end)
        x = (try? c.decode(Double.self, forKey: .x)) ?? 0; y = (try? c.decode(Double.self, forKey: .y)) ?? 0
        follow = (try? c.decode(Bool.self, forKey: .follow)) ?? true
        radius = (try? c.decode(Double.self, forKey: .radius)) ?? 0.12
        magnification = (try? c.decode(Double.self, forKey: .magnification)) ?? 2
        round = (try? c.decode(Bool.self, forKey: .round)) ?? true
        cx = (try? c.decode(Double.self, forKey: .cx)) ?? 0.22
        cy = (try? c.decode(Double.self, forKey: .cy)) ?? 0.74
        border = (try? c.decode(Double.self, forKey: .border)) ?? 0.006
        shadow = (try? c.decode(Double.self, forKey: .shadow)) ?? 0.45
    }
}
public struct TapIndicator: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var t: Double, x: Double, y: Double                      // source time, source px
    public init(id: UUID = UUID(), t: Double, x: Double, y: Double) { self.id = id; self.t = t; self.x = x; self.y = y }
}
public struct TextBlock: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var text: String
    public var x: Double, y: Double                                // canvas-normalized center
    public var size: Double                                        // fraction of canvas height
    public var color: RGBA
    public init(id: UUID = UUID(), start: Double, end: Double, text: String, x: Double = 0.5, y: Double = 0.86, size: Double = 0.045, color: RGBA = RGBA(0xFFFFFF)) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.x = x; self.y = y; self.size = size; self.color = color
    }
}

public struct Overlays: Codable, Equatable, Sendable {
    public var masks: [Mask] = [], highlights: [Highlight] = [], loupes: [Loupe] = [], taps: [TapIndicator] = [], texts: [TextBlock] = []
    public var privacy = PrivacyPlan()
    enum CodingKeys: String, CodingKey { case masks, highlights, loupes, taps, texts, privacy }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        masks = c.opt(.masks, masks); highlights = c.opt(.highlights, highlights); loupes = c.opt(.loupes, loupes)
        taps = c.opt(.taps, taps); texts = c.opt(.texts, texts); privacy = c.opt(.privacy, privacy)
    }
}

public enum LayoutKind: String, Codable, CaseIterable, Hashable, Sendable { case screenOnly, cameraOverlay, split, cameraFullscreen, cameraCutout }
public struct LayoutSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double                          // SOURCE seconds
    public var kind: LayoutKind
    public init(id: UUID = UUID(), start: Double, end: Double, kind: LayoutKind) { self.id = id; self.start = start; self.end = end; self.kind = kind }
}
public enum BehindFace: String, Codable, CaseIterable, Sendable { case move, hide, fade }
public struct LayoutSettings: Codable, Equatable, Sendable {
    public var size = 0.22
    public var corner: WebcamLayout.Corner = .bottomRight
    public var shape: WebcamLayout.Shape = .circle
    public var mirror = true, border = true, shadow = true, autoFrame = true
    public var avoidCursor = true
    public var avoidMargin = 48.0
    public var snapDwell = 0.45
    public var behindFace: BehindFace = .move
    public var hideOnSilence = false
    public var silenceHold = 0.6
    enum CodingKeys: String, CodingKey {
        case size, corner, shape, mirror, border, shadow, autoFrame, avoidCursor, avoidMargin, snapDwell, behindFace, hideOnSilence, silenceHold
    }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        size = c.opt(.size, size); corner = c.opt(.corner, corner); shape = c.opt(.shape, shape); mirror = c.opt(.mirror, mirror)
        border = c.opt(.border, border); shadow = c.opt(.shadow, shadow); autoFrame = c.opt(.autoFrame, autoFrame)
        avoidCursor = c.opt(.avoidCursor, avoidCursor); avoidMargin = c.opt(.avoidMargin, avoidMargin); snapDwell = c.opt(.snapDwell, snapDwell)
        behindFace = c.opt(.behindFace, behindFace); hideOnSilence = c.opt(.hideOnSilence, hideOnSilence); silenceHold = c.opt(.silenceHold, silenceHold)
    }
}
/// Independent camera settings per layout.
public struct LayoutSet: Codable, Equatable, Sendable {
    public var screenOnly = LayoutSettings(), cameraOverlay = LayoutSettings(), split = LayoutSettings()
    public var cameraFullscreen = LayoutSettings(), cameraCutout = LayoutSettings()
    public init() {}
    public subscript(k: LayoutKind) -> LayoutSettings {
        get {
            switch k {
            case .screenOnly: screenOnly; case .cameraOverlay: cameraOverlay; case .split: split
            case .cameraFullscreen: cameraFullscreen; case .cameraCutout: cameraCutout
            }
        }
        set {
            switch k {
            case .screenOnly: screenOnly = newValue; case .cameraOverlay: cameraOverlay = newValue; case .split: split = newValue
            case .cameraFullscreen: cameraFullscreen = newValue; case .cameraCutout: cameraCutout = newValue
            }
        }
    }
}

/// Two faces, nothing else: a serif for the editorial read, a sans for the
/// neutral one. Both render at weight 450 — the old per-word bold made the
/// line reflow every time the spoken word changed.
public enum CaptionFont: String, Codable, CaseIterable, Sendable {
    case serif, sans
    public var title: String { switch self { case .serif: "Serif"; case .sans: "Sans" } }
    public var postScript: String { switch self { case .serif: "New York"; case .sans: "SF Pro Text" } }
    /// Legacy project files stored the old four-way choice. They map onto the
    /// two faces that remain; nothing is lost but the picker.
    public init(from d: Decoder) throws {
        let raw = try d.singleValueContainer().decode(String.self)
        switch raw {
        case "newYork": self = .serif
        case "sfPro", "sfRounded", "menlo": self = .sans
        default: self = raw == "serif" ? .serif : .sans
        }
    }
}
public struct CaptionStyle: Codable, Equatable, Sendable {
    public var size = 0.060                                         // fraction of canvas height
    public var color = RGBA(0xFFFFFF)
    /// Dark card so white text keeps 4.5:1+ contrast on bright pages;
    /// a light pill on a white page fails regardless of blur.
    public var pill: RGBA? = RGBA(0x0A0A0A, a: 0.62)
    public var font: CaptionFont = .sans
    enum CodingKeys: String, CodingKey { case size, color, pill, font }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        size = c.opt(.size, size); color = c.opt(.color, color)
        pill = c.contains(.pill) ? ((try? c.decodeIfPresent(RGBA.self, forKey: .pill)) ?? nil) : pill
        font = c.opt(.font, font)
    }
}
public struct CaptionPlan: Codable, Equatable, Sendable {
    /// Captions are opt-in. A transcript arriving must never switch them on
    /// behind the user's back, so nothing but the toggle writes this.
    public var enabled = false
    public var style = CaptionStyle()
    public var locale = "en-US"
    public var vocabulary: [String] = []
    public var deletedWords: [Int] = []                             // transcript word indices removed by transcript editing
    public var textEdits: [String: String] = [:]                    // word index -> corrected text (captions only)
    enum CodingKeys: String, CodingKey { case enabled, style, locale, vocabulary, deletedWords, textEdits }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = c.opt(.enabled, enabled); style = c.opt(.style, style); locale = c.opt(.locale, locale)
        vocabulary = c.opt(.vocabulary, vocabulary); deletedWords = c.opt(.deletedWords, deletedWords)
        textEdits = c.opt(.textEdits, textEdits)
    }
}

/// Where a detection came from. Context is a *separate* fact from a detection:
/// it describes the surface, never the pixels. An empty context means "unknown",
/// which is never the same thing as "public page".
public struct PrivacyContext: Codable, Sendable, Equatable {
    /// Verified registrable host of the focused browser surface (`mail.google.com`).
    public var host: String?
    public var appName: String?
    public var windowID: Int?
    /// Focused-element identity. A change means a different element.
    public var epoch: UInt32
    /// True when a real AX query produced this sample.
    public var resolved: Bool

    public init(host: String? = nil, appName: String? = nil, windowID: Int? = nil,
                epoch: UInt32 = 0, resolved: Bool = false) {
        self.host = host; self.appName = appName; self.windowID = windowID
        self.epoch = epoch; self.resolved = resolved
    }

    enum CodingKeys: String, CodingKey { case host, appName, windowID, epoch, resolved }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        windowID = try c.decodeIfPresent(Int.self, forKey: .windowID)
        epoch = try c.decodeIfPresent(UInt32.self, forKey: .epoch) ?? 0
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
    }

    /// Approved private surfaces. Matching is by exact host or a subdomain of
    /// one, never by substring: `mail.google.com.example.test` is a different
    /// registrable domain and must not count as private.
    public static let approvedPrivateHosts = ["mail.google.com", "accounts.google.com"]

    /// Host only, lowercased, without scheme, path, query, userinfo, port or a
    /// trailing dot. Anything that is not a bare host name is rejected.
    public static func normalizeHost(_ raw: String?) -> String? {
        guard var h = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !h.isEmpty else { return nil }
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let r = h.firstIndex(of: "/") { h = String(h[..<r]) }
        if let r = h.firstIndex(of: "?") { h = String(h[..<r]) }
        if let r = h.firstIndex(of: "#") { h = String(h[..<r]) }
        if let r = h.firstIndex(of: "@") { h = String(h[h.index(after: r)...]) }
        if let r = h.lastIndex(of: ":") { h = String(h[..<r]) }
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty, h.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else { return nil }
        return h
    }

    public static func hostIsApproved(_ raw: String?) -> Bool {
        guard let h = normalizeHost(raw) else { return false }
        return approvedPrivateHosts.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    public var normalizedHost: String? { Self.normalizeHost(host) }
    public var isApprovedPrivateHost: Bool { Self.hostIsApproved(host) }
    /// No evidence at all: legacy footage or a capture without AX.
    public var isUnknown: Bool { host == nil && appName == nil && windowID == nil && !resolved }

    /// Two samples describe the same surface. A focus, window, app or host
    /// change is a different surface, so a mask must not bridge across it.
    public func isSameSurface(as other: PrivacyContext) -> Bool {
        guard host == other.host, appName == other.appName, resolved == other.resolved else { return false }
        if let a = windowID, let b = other.windowID, a != b { return false }
        if resolved, epoch != other.epoch { return false }
        return true
    }

    public init(anchor: FocusAnchor?) {
        guard let a = anchor else { self = PrivacyContext(); return }
        self = PrivacyContext(host: a.host, appName: a.appName, windowID: a.windowID,
                              epoch: a.epoch, resolved: a.resolved)
    }
}

/// One source-time context sample.
public struct PrivacyContextSample: Codable, Sendable, Equatable {
    public var t: Double
    public var context: PrivacyContext
    public init(t: Double, context: PrivacyContext) { self.t = t; self.context = context }
    enum CodingKeys: String, CodingKey { case t, context }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0
        context = try c.decodeIfPresent(PrivacyContext.self, forKey: .context) ?? PrivacyContext()
    }
}

/// Context over source time, run-length encoded so a long recording carries a
/// handful of samples instead of one per AX poll.
public struct PrivacyContextTrack: Codable, Sendable, Equatable {
    public var samples: [PrivacyContextSample]
    public init(samples: [PrivacyContextSample] = []) { self.samples = samples }

    /// Context in force at `t`, or nil when nothing is known that early.
    public func context(at t: Double) -> PrivacyContext? {
        var lo = 0, hi = samples.count
        while lo < hi {
            let m = (lo + hi) / 2
            if samples[m].t <= t { lo = m + 1 } else { hi = m }
        }
        return lo > 0 ? samples[lo - 1].context : nil
    }

    /// Build from AX samples. Frames without an anchor are recorded as unknown
    /// context, so a known surface followed by a gap still resets a mask.
    public static func from(ax: [AXFrame]) -> PrivacyContextTrack {
        let ordered = ax.compactMap { frame -> PrivacyContextSample? in
            guard let time = frame.sampledAt, time.isFinite else { return nil }
            return PrivacyContextSample(t: time, context: PrivacyContext(anchor: frame.anchor))
        }.sorted { $0.t < $1.t }
        var out: [PrivacyContextSample] = []
        for sample in ordered {
            if let last = out.last, last.context == sample.context { continue }
            out.append(sample)
        }
        return PrivacyContextTrack(samples: out)
    }
}

/// Automatic-mask policy. Detection, geometry, confidence and context stay
/// separate: this decides only what the *policy* may apply automatically.
public enum PrivacyPolicy {
    public enum Verdict: String, Codable, Sendable, Equatable {
        /// Apply automatically when the category is in `PrivacyPlan.autoApply`.
        case apply
        /// Never apply automatically: keep it as a proposal for review.
        case propose
    }

    /// A visible address is only private on a verified private host. Everywhere
    /// else it is ordinary page content and stays visible. Keys, tokens, private
    /// keys, card numbers, high-entropy values and the user's own patterns are
    /// secrets on any surface and keep their existing protection.
    public static func verdict(for category: SensitiveCategory, context: PrivacyContext?) -> Verdict {
        switch category {
        case .email, .phone:
            return (context?.isApprovedPrivateHost ?? false) ? .apply : .propose
        case .apiKey, .jwt, .privateKey, .card, .envSecret, .entropy, .custom:
            return .apply
        }
    }
}

/// Privacy analyzer settings and user decisions keyed by stable automatic-mask ids.
public struct PrivacyPlan: Codable, Equatable, Sendable {
    public var privacyModel = 2
    public var enabled = true
    public var autoDetect = true
    public var autoApply: [String] = ["apiKey", "jwt", "privateKey", "envSecret", "card", "email", "phone", "entropy", "password", "custom"]
    public var customPatterns: [String] = []
    public var padding = 6.0
    public var mode: MaskMode = .blur
    public var pixelSize = 0.0
    public var entropyThreshold = 3.5
    public var decisions: [String: Bool] = [:]
    enum CodingKeys: String, CodingKey { case privacyModel, enabled, autoDetect, autoApply, customPatterns, padding, mode, pixelSize, entropyThreshold, decisions }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = c.opt(.enabled, enabled); autoDetect = c.opt(.autoDetect, autoDetect); autoApply = c.opt(.autoApply, autoApply)
        customPatterns = c.opt(.customPatterns, customPatterns); padding = c.opt(.padding, padding); mode = c.opt(.mode, mode)
        pixelSize = c.opt(.pixelSize, pixelSize)
        if c.opt(.privacyModel, 1) < 2, mode == .pixelate, pixelSize == 16 {
            mode = .blur; pixelSize = 0
        }
        entropyThreshold = c.opt(.entropyThreshold, entropyThreshold); decisions = c.opt(.decisions, decisions)
    }
}
