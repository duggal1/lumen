import Foundation

public enum CutOrigin: String, Codable, Sendable { case manual, autoTidy }
/// Removed span, SOURCE seconds.
public struct CutRange: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var origin: CutOrigin
    public init(id: UUID = UUID(), start: Double, end: Double, origin: CutOrigin = .manual) {
        self.id = id; self.start = start; self.end = end; self.origin = origin
    }
}

public enum MaskMode: String, Codable, CaseIterable, Sendable { case blur, pixelate, solid, blend }
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
public struct Loupe: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public var x: Double, y: Double                                // source px (ignored when follow)
    public var follow: Bool
    public var radius: Double                                      // fraction of canvas width
    public var magnification: Double
    public var round: Bool
    public init(id: UUID = UUID(), start: Double, end: Double, x: Double = 0, y: Double = 0, follow: Bool = true, radius: Double = 0.12,
                magnification: Double = 2, round: Bool = true) {
        self.id = id; self.start = start; self.end = end; self.x = x; self.y = y; self.follow = follow
        self.radius = radius; self.magnification = magnification; self.round = round
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
    enum CodingKeys: String, CodingKey { case masks, highlights, loupes, taps, texts }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        masks = c.opt(.masks, masks); highlights = c.opt(.highlights, highlights); loupes = c.opt(.loupes, loupes)
        taps = c.opt(.taps, taps); texts = c.opt(.texts, texts)
    }
}

public enum LayoutKind: String, Codable, CaseIterable, Hashable, Sendable { case screenOnly, cameraOverlay, split, cameraFullscreen, cameraCutout }
public struct LayoutSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double                          // SOURCE seconds
    public var kind: LayoutKind
    public init(id: UUID = UUID(), start: Double, end: Double, kind: LayoutKind) { self.id = id; self.start = start; self.end = end; self.kind = kind }
}
public struct LayoutSettings: Codable, Equatable, Sendable {
    public var size = 0.22
    public var corner: WebcamLayout.Corner = .bottomRight
    public var shape: WebcamLayout.Shape = .circle
    public var mirror = true, border = true, shadow = true, autoFrame = true
    public init() {}
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

public enum CaptionAnimation: String, Codable, CaseIterable, Sendable { case none, fade, pop, slide }
public enum CaptionPosition: String, Codable, CaseIterable, Sendable { case auto, bottom, top }
public struct CaptionStyle: Codable, Equatable, Sendable {
    public var size = 0.042                                         // fraction of canvas height
    public var bold = true
    public var color = RGBA(0xFFFFFF)
    public var pill: RGBA? = RGBA(0x000000, a: 0.55)
    public var outline = false
    public var animation: CaptionAnimation = .pop
    public var wordHighlight = true
    public var highlightColor = RGBA(0xF97316)
    public var position: CaptionPosition = .auto
    public init() {}
}
public struct CaptionPlan: Codable, Equatable, Sendable {
    public var enabled = false
    public var style = CaptionStyle()
    public var maxLines = 2
    public var maxCharsPerLine: Int?                                // nil = aspect-adaptive
    public var locale = "en-US"
    public var vocabulary: [String] = []
    public var deletedWords: [Int] = []                             // transcript word indices removed by transcript editing
    public var textEdits: [String: String] = [:]                    // word index -> corrected text (captions only)
    public init() {}
}
