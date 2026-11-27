import Foundation
import Darwin
import LumenCore

extension KeyedDecodingContainer {
    /// Tolerant decode: a missing or malformed key yields the default, so older project files keep opening.
    func opt<T: Decodable>(_ k: Key, _ d: T) -> T { (try? decodeIfPresent(T.self, forKey: k)) ?? d }
}

public enum Origin: String, Codable, Sendable { case auto, manual }

public struct RGBA: Codable, Equatable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float
    public init(_ hex: UInt32, a: Float = 1) {
        r = Float((hex >> 16) & 255) / 255; g = Float((hex >> 8) & 255) / 255; b = Float(hex & 255) / 255; self.a = a
    }
    public init(r: Float, g: Float, b: Float, a: Float = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public var simd: SIMD4<Float> { [r, g, b, a] }
}

/// Ordered color ramps, dithered into a pixel field from the first tone to the last.
public enum DitherPalettes {
    public static let all: [(String, [RGBA])] = [
        ("Orange / black", [RGBA(0x0A0A0A), RGBA(0xFF6A00)]),
        ("Orange / white", [RGBA(0xFFFFFF), RGBA(0xFF6A00)]),
        ("Green / white", [RGBA(0xFFFFFF), RGBA(0x39D353)]),
        ("Green / black", [RGBA(0x0A0A0A), RGBA(0x39D353)]),
        ("Purple / black", [RGBA(0x0A0A0A), RGBA(0x8B5CF6)]),
        ("Purple / white", [RGBA(0xFFFFFF), RGBA(0x8B5CF6)]),
        ("Blue / black", [RGBA(0x0A0A0A), RGBA(0x3B82F6)]),
        ("Blue / white", [RGBA(0xFFFFFF), RGBA(0x3B82F6)]),
        ("Red / black", [RGBA(0x0A0A0A), RGBA(0xEF4444)]),
        ("Red / white", [RGBA(0xFFFFFF), RGBA(0xEF4444)]),
        ("Yellow / black", [RGBA(0x0A0A0A), RGBA(0xFACC15)]),
        ("Yellow / white", [RGBA(0xFFFFFF), RGBA(0xEAB308)]),
        ("Cyan / black", [RGBA(0x0A0A0A), RGBA(0x06B6D4)]),
        ("Cyan / white", [RGBA(0xFFFFFF), RGBA(0x06B6D4)]),
        ("Pink / black", [RGBA(0x0A0A0A), RGBA(0xEC4899)]),
        ("Pink / white", [RGBA(0xFFFFFF), RGBA(0xEC4899)]),
        ("White / black", [RGBA(0x0A0A0A), RGBA(0xFFFFFF)]),
        ("Spectrum", [RGBA(0x0A0A0A), RGBA(0xF97316), RGBA(0x22C55E), RGBA(0x8B5CF6), RGBA(0x3B82F6), RGBA(0xFACC15)]),
    ]
    public static func colors(named name: String) -> [RGBA] {
        all.first { $0.0 == name }?.1 ?? all[0].1
    }
}

/// Legacy backgrounds remain decodable for existing projects.
public enum BackgroundKind: String, Codable, CaseIterable, Sendable {
    case dither, canvas, wallpaper, solid, gradient, mesh
    /// A local image, either chosen from disk or fetched through Unsplash.
    case image
    public static let offered: [BackgroundKind] = [.solid, .canvas, .wallpaper, .image]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "wave" || value == "field" {
            self = .dither
        } else if let kind = Self(rawValue: value) {
            self = kind
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown background kind: \(value)")
        }
    }
}

public enum GradientPresets {
    public static let all: [(String, [RGBA])] = [
        ("Ember", [RGBA(0x1A0F08), RGBA(0x7C2D12), RGBA(0xF97316), RGBA(0xFDBA74)]),
        ("Graphite", [RGBA(0x0A0A0A), RGBA(0x171717), RGBA(0x262626), RGBA(0x3A3A3A)]),
        ("Paper", [RGBA(0xF4F4F4), RGBA(0xEDEDED), RGBA(0xE3E3E3), RGBA(0xFFFFFF)]),
        ("Dusk", [RGBA(0x1E1B4B), RGBA(0x4C1D95), RGBA(0xBE185D), RGBA(0xF97316)]),
        ("Ocean", [RGBA(0x082F49), RGBA(0x0369A1), RGBA(0x0EA5E9), RGBA(0x7DD3FC)]),
        ("Moss", [RGBA(0x052E16), RGBA(0x166534), RGBA(0x4ADE80), RGBA(0xBBF7D0)]),
    ]
}


public enum CanvasAspect: String, Codable, CaseIterable, Sendable {
    case r16x9, r16x10, r4x3, r5x4, r3x2, r1x1, r4x5, r9x16, r21x9
    public var ratio: Double {
        switch self {
        case .r16x9: 16.0 / 9; case .r16x10: 1.6; case .r4x3: 4.0 / 3; case .r5x4: 1.25; case .r3x2: 1.5
        case .r1x1: 1; case .r4x5: 0.8; case .r9x16: 9.0 / 16; case .r21x9: 21.0 / 9
        }
    }
    public var title: String {
        switch self {
        case .r16x9: "16:9"; case .r16x10: "16:10"; case .r4x3: "4:3"; case .r5x4: "5:4"; case .r3x2: "3:2"
        case .r1x1: "1:1"; case .r4x5: "4:5"; case .r9x16: "9:16"; case .r21x9: "21:9"
        }
    }
}

public struct EdgeInsetsN: Codable, Equatable, Sendable {
    public var top: Double, right: Double, bottom: Double, left: Double      // fraction of canvas width
    public init(top: Double, right: Double, bottom: Double, left: Double) { self.top = top; self.right = right; self.bottom = bottom; self.left = left }
    public init(all v: Double) { self.init(top: v, right: v, bottom: v, left: v) }
}
public struct CornerRadii: Codable, Equatable, Sendable {
    public var tl: Double, tr: Double, br: Double, bl: Double                // points @ 1440 px canvas
    public init(tl: Double, tr: Double, br: Double, bl: Double) { self.tl = tl; self.tr = tr; self.br = br; self.bl = bl }
    public init(all v: Double) { self.init(tl: v, tr: v, br: v, bl: v) }
}

public struct Style: Codable, Equatable, Sendable {
    public var background: BackgroundKind = .image
    public var colors: [RGBA] = [RGBA(0xF4F4F4), RGBA(0xDADADA)]
    public var gradientAngle: Double = 35
    // AGENT: the preset id preserves its palette and geometry when a project is reopened.
    public var canvasPresetID = ""
    public var canvasSpeed = 1.0
    public var ditherCell: Double = 4, ditherDensity: Double = 0.55, contentScale: Double = 1
    public var ditherSaturation = true
    public var padding: Double = 0.025
    public var cornerRadius: Double = 14
    public var shadow: Double = 0.45
    public var innerBorder = true
    public var canvas: CanvasAspect = .r16x9
    public var paddingInsets: EdgeInsetsN?              // nil = uniform `padding`
    public var cornerRadii: CornerRadii?                // nil = uniform `cornerRadius`
    public var customAspect: Double?                    // nil = `canvas`
    /// Continuous blur for the background image, in canvas pixels. 0 is sharp.
    /// A wallpaper ships sharp; the user decides how soft it is.
    public var wallpaperBlur = 0.0
    /// Image adjust (0 = off). Additive; old projects decode to defaults.
    public var imageOpacity = 1.0, imageContrast = 1.0, imageBrightness = 1.0    /// Frame weight (pt). The frame toggle itself is `innerBorder`.
    public var frameWeight = 1.0
    /// Local photo for `.image`. Absolute path or bundled sentinel
    /// (`serene-lake.jpg` resolves from Resources/Wallpapers). The
    /// renderer loads it once per modification date, never per frame.
    public var backgroundImagePath: String? = "paintings/claude-monet/claude-monet_water-lilies-agapanthus_cma-136510.webp"
    public var aspectRatio: Double { customAspect ?? canvas.ratio }
    public var insets: EdgeInsetsN { paddingInsets ?? EdgeInsetsN(all: padding) }
    public var radii: CornerRadii { cornerRadii ?? CornerRadii(all: cornerRadius) }
    enum CodingKeys: String, CodingKey {
        case background, colors, gradientAngle, canvasPresetID, canvasSpeed, ditherCell, ditherDensity, contentScale, ditherSaturation, padding, cornerRadius, shadow, innerBorder, canvas, paddingInsets, cornerRadii, customAspect, wallpaperBlur, backgroundImagePath, imageOpacity, imageContrast, imageBrightness, frameWeight
    }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        background = c.opt(.background, background); colors = c.opt(.colors, colors); gradientAngle = c.opt(.gradientAngle, gradientAngle)
        canvasPresetID = c.opt(.canvasPresetID, canvasPresetID)
        canvasSpeed = c.opt(.canvasSpeed, canvasSpeed)
        ditherCell = c.opt(.ditherCell, ditherCell); ditherDensity = c.opt(.ditherDensity, ditherDensity); contentScale = c.opt(.contentScale, contentScale)
        ditherSaturation = c.opt(.ditherSaturation, ditherSaturation)
        padding = c.opt(.padding, padding); cornerRadius = c.opt(.cornerRadius, cornerRadius); shadow = c.opt(.shadow, shadow)
        innerBorder = c.opt(.innerBorder, innerBorder); canvas = c.opt(.canvas, canvas)
        paddingInsets = try? c.decodeIfPresent(EdgeInsetsN.self, forKey: .paddingInsets)
        cornerRadii = try? c.decodeIfPresent(CornerRadii.self, forKey: .cornerRadii)
        customAspect = try? c.decodeIfPresent(Double.self, forKey: .customAspect)
        wallpaperBlur = c.opt(.wallpaperBlur, wallpaperBlur)
        backgroundImagePath = try? c.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        imageOpacity = c.opt(.imageOpacity, imageOpacity)
        imageContrast = c.opt(.imageContrast, imageContrast); imageBrightness = c.opt(.imageBrightness, imageBrightness)
        frameWeight = c.opt(.frameWeight, frameWeight)
    }

    /// Makes a downloaded or user-selected photo the canvas background.
    public mutating func setPhotoBackground(_ path: String) {
        background = .image
        backgroundImagePath = path
    }
    /// Drops the photo reference when switching back to a generated backdrop.
    public mutating func clearPhotoBackground() {
        if background == .image { background = .solid }
        backgroundImagePath = nil
    }
}

/// Cursor artwork packs. Lumen's own vector art comes first; the
/// `glove`…`cookie` range is retired now (the Tiny Hand coat is gone), and
/// the packs render as stock glyphs again.
public enum CursorPack: String, Codable, CaseIterable, Sendable {
    case system, minimal, dot, pro, holiday, lavender, coral, sky, mint, lemon, pink, wood, chrome, grass, pixel, outline, ember, mono
    case glove, plush, robot, holo, fuzzy, marble, terrazzo, glass, jelly, pastel
    case lowpoly, knit, skeleton, astro, space, monster, water, lava, cactus, choco
    case cloud, mech, neon, leaf, cookie

    /// The Studio exposes only these three actual pointer silhouettes.
    public static let studioSkins: [Self] = [.system, .pixel, .outline]
    public var studioTitle: String {
        switch self {
        case .system: "Normal"
        case .pixel: "Pixelated"
        case .outline: "Outline"
        default: rawValue.capitalized
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let value = try c.decode(String.self)
        // Retired artwork is never rendered again; old projects keep a
        // recognizable, pointed pointer and all of their other settings.
        if value == "ring" { self = .outline; return }
        guard let pack = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown cursor pack: \(value)")
        }
        self = pack
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
public struct CursorStyle: Codable, Equatable, Sendable {
    public var pack: CursorPack = .system
    /// Optional artwork ink; nil preserves the skin's original color.
    public var ink: RGBA? = nil
    public var size: Double = 1.0
    public var smoothingSigma: Double = 0.035
    public var glide: Double = 0.35
    public var idleHide: Double? = 2.0
    public var pressScale: Double = 0.86
    public var clickEffect: ClickEffect = .none
    /// Apple-glass bloom expands on release and settles in about half a second.
    public var clickDuration: Double = 0.55
    /// Tint off by default (transparent white): the ripple refracts the
    /// video itself, with no flat fill color.
    public var clickColor: RGBA = RGBA(0xFFFFFF, a: 0)
    /// Multiplies the ring radius (0.5...2.0). Renderer consumes it.
    public var clickSize: Double = 1.0
    /// Multiplies ring alpha (0...1.5). Renderer consumes it.
    public var clickIntensity: Double = 1.0
    public var clickRing: Double? = nil
    public var zoomCompensation: Double = 0.5
    public var constantSize = false                     // true = cursor keeps its on-screen size during zoom
    public var loop: Double?                            // seconds of tail that glides back to the first frame; nil = off
    public var effectiveCompensation: Double { constantSize ? 1 : zoomCompensation }
    enum CodingKeys: String, CodingKey { case pack, ink, size, smoothingSigma, glide, idleHide, pressScale, clickRing, zoomCompensation, constantSize, loop, clickEffect, clickDuration, clickColor, clickSize, clickIntensity }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        pack = c.opt(.pack, pack); ink = try c.decodeIfPresent(RGBA.self, forKey: .ink); size = c.opt(.size, size); smoothingSigma = c.opt(.smoothingSigma, smoothingSigma); glide = c.opt(.glide, glide)
        idleHide = c.contains(.idleHide) ? ((try? c.decodeIfPresent(Double.self, forKey: .idleHide)) ?? nil) : idleHide
        pressScale = c.opt(.pressScale, pressScale)
        clickEffect = c.opt(.clickEffect, clickEffect); clickDuration = c.opt(.clickDuration, clickDuration); clickColor = c.opt(.clickColor, clickColor)
        clickSize = c.opt(.clickSize, clickSize); clickIntensity = c.opt(.clickIntensity, clickIntensity)
        clickRing = c.contains(.clickRing) ? ((try? c.decodeIfPresent(Double.self, forKey: .clickRing)) ?? nil) : clickRing
        zoomCompensation = c.opt(.zoomCompensation, zoomCompensation); constantSize = c.opt(.constantSize, constantSize)
        loop = try? c.decodeIfPresent(Double.self, forKey: .loop)
    }
    public func encode(to e: Encoder) throws {      // explicit nulls so "off" survives a round trip
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(pack, forKey: .pack); try c.encodeIfPresent(ink, forKey: .ink); try c.encode(size, forKey: .size); try c.encode(smoothingSigma, forKey: .smoothingSigma)
        try c.encode(glide, forKey: .glide); try c.encode(idleHide, forKey: .idleHide); try c.encode(pressScale, forKey: .pressScale)
        try c.encode(clickRing, forKey: .clickRing); try c.encode(zoomCompensation, forKey: .zoomCompensation)
        try c.encode(clickEffect, forKey: .clickEffect); try c.encode(clickDuration, forKey: .clickDuration)
        try c.encode(clickColor, forKey: .clickColor)
        try c.encode(clickSize, forKey: .clickSize); try c.encode(clickIntensity, forKey: .clickIntensity)
        try c.encode(constantSize, forKey: .constantSize); try c.encodeIfPresent(loop, forKey: .loop)
    }
}

public enum ZoomPreset: String, Codable, CaseIterable, Sendable {
    case subtle, balanced, dramatic, cinematic, fixed
    public var maxScale: Double { switch self { case .subtle: 1.5; case .balanced: 2.0; case .dramatic: 2.4; case .cinematic: 2.2; case .fixed: 2.0 } }
}
public enum TiltMode: String, Codable, CaseIterable, Sendable { case off, lean, reveal }
public enum ZoomEasing: String, Codable, CaseIterable, Sendable {
    case snappy, smooth, cinematic
    public var omegaScale: Double { switch self { case .snappy: 1.35; case .smooth: 1.0; case .cinematic: 0.65 } }
}

public struct CameraParams: Codable, Equatable, Sendable {
    public var preset: ZoomPreset = .balanced
    public var autoZoom = true
    public var maxScale = 2.0
    public var minScale = 1.25
    public var leadIn = 0.30, tail = 0.7, panThroughGap = 1.5
    public var omegaPan = 4.0, omegaZoom = 7.5, lookahead = 0.20, deadZone = 0.28, followDelay = 0.12
    public var baseScale = 1.8
    public var zoomOutGap = 2.6
    public var hold = 0.9
    public var cameraModel = 5
    public var centerOffsetX = 0.0, centerOffsetY = 0.0         // view-normalized bias of where the cursor sits in the zoomed view
    public var sensitivity = 0.5                                // scales explicit/visual attention sensitivity; hover is not an intent
    public var shutter = 0.5
    public var maxSamples = 12
    /// User setting for the real-time upscaler cap (2...10, ladder
    /// {2,3,4,5,6,8,10}). Magnification picks the smallest factor >= need.
    public var upscaleMaxFactor = 10
    /// Master switch for the real-time upscaler (A/B testing, low-end GPUs).
    public var upscaleEnabled = true
    public var tilt: TiltMode = .off
    public var maxYaw = 8.0, maxPitch = 6.0, omegaTilt = 5.0
    enum CodingKeys: String, CodingKey {
        case preset, autoZoom, maxScale, minScale, leadIn, tail, panThroughGap, omegaPan, omegaZoom, lookahead, deadZone
        case followDelay, centerOffsetX, centerOffsetY, sensitivity, shutter, maxSamples, upscaleMaxFactor, upscaleEnabled, tilt, maxYaw, maxPitch, omegaTilt
        case baseScale, zoomOutGap, hold, cameraModel
    }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        preset = c.opt(.preset, preset); autoZoom = c.opt(.autoZoom, autoZoom); maxScale = c.opt(.maxScale, maxScale); minScale = c.opt(.minScale, minScale)
        leadIn = c.opt(.leadIn, leadIn); tail = c.opt(.tail, tail)
        panThroughGap = c.opt(.panThroughGap, panThroughGap); omegaPan = c.opt(.omegaPan, omegaPan)
        omegaZoom = c.opt(.omegaZoom, omegaZoom); lookahead = c.opt(.lookahead, lookahead); deadZone = c.opt(.deadZone, deadZone)
        followDelay = c.opt(.followDelay, followDelay); centerOffsetX = c.opt(.centerOffsetX, centerOffsetX); centerOffsetY = c.opt(.centerOffsetY, centerOffsetY)
        sensitivity = c.opt(.sensitivity, sensitivity); shutter = c.opt(.shutter, shutter)
        maxSamples = c.opt(.maxSamples, maxSamples)
        baseScale = c.opt(.baseScale, baseScale)
        zoomOutGap = c.opt(.zoomOutGap, zoomOutGap); hold = c.opt(.hold, hold)
        cameraModel = c.opt(.cameraModel, 1)
        if cameraModel < 5 {
            maxScale = 2.0; minScale = 1.25; leadIn = 0.30; hold = 0.9; zoomOutGap = 2.6
            omegaZoom = 7.5; omegaPan = 4; baseScale = 1.8; cameraModel = 5
        }
        let savedUpscale = c.opt(.upscaleMaxFactor, upscaleMaxFactor)
        upscaleMaxFactor = min(max(savedUpscale == 8 ? 10 : savedUpscale, 2), 10)
        upscaleEnabled = c.opt(.upscaleEnabled, upscaleEnabled)
        tilt = c.opt(.tilt, tilt); maxYaw = c.opt(.maxYaw, maxYaw); maxPitch = c.opt(.maxPitch, maxPitch)
        omegaTilt = c.opt(.omegaTilt, omegaTilt)
    }
    /// Applies a preset's whole feel. Sliders edited afterwards stick (nothing re-applies the preset behind the user's back).
    public mutating func apply(preset p: ZoomPreset) {
        preset = p; maxScale = p.maxScale
        leadIn = 0.30; tail = 0.7; omegaPan = 4; omegaZoom = 7.5; shutter = 0.5; tilt = .off
        if p == .cinematic { leadIn = 0.45; tail = 1.1; omegaPan = 3; omegaZoom = 5.5; shutter = 0.6; tilt = .lean }
        // Fixed camera magnification remains independent of automatic fitting.
        switch p {
        case .subtle: baseScale = 1.4
        case .balanced: baseScale = 1.8
        case .dramatic: baseScale = 2.3
        case .cinematic: baseScale = 2.0
        case .fixed: break
        }
    }
}

public enum MicMode: String, Codable, CaseIterable, Sendable {
    case standard, loud, podcast, off
    /// Streaming/web target (-14 LUFS) by default; `.podcast` keeps the Apple
    /// Podcasts -16 LUFS spec and `.loud` is the -12 LUFS option.
    public var targetLUFS: Double { switch self { case .standard: -14; case .loud: -12; case .podcast: -16; case .off: -14 } }
}
public struct AudioLane: Codable, Equatable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case mic, system, voiceover, music, sfx }
    public var id: UUID
    public var role: Role
    public var path: String?                            // imported file; nil = recorded source
    public var placement: Double                        // OUTPUT seconds
    public var gainDb: Double, mute: Bool, separateTrack: Bool
    public var variant: String?                         // "EN", "ES"
    public var trimStart: Double? = nil
    public var trimDuration: Double? = nil
    /// nil preserves legacy music-bed behavior; false is a finite editable clip.
    public var loops: Bool? = nil
    public init(id: UUID = UUID(), role: Role, path: String? = nil, placement: Double = 0, gainDb: Double = 0, mute: Bool = false,
                separateTrack: Bool = false, variant: String? = nil) {
        self.id = id; self.role = role; self.path = path; self.placement = placement; self.gainDb = gainDb; self.mute = mute
        self.separateTrack = separateTrack; self.variant = variant
    }
}

public enum ClickSound: String, Codable, CaseIterable, Sendable {
    case mouse, subtle, fresh
    case click1, click2, click3, click4, click5
    case select1, select2, select3, select4, select5, select6, select7, select8
    case switch1, switch2, switch3, switch4, switch5, switch6, switch7
    case studioCrisp, studioSoft, studioMechanical, studioRelease
    case studioSnap, studioTick, studioLight, studioTap

    public static let studioCollection: [Self] = [
        .studioCrisp, .studioSoft, .studioMechanical
    ]

    /// Only the approved Fresh recording and the three authored retro clicks
    /// are exposed. All legacy IDs stay Codable for existing project files.
    public static let activeCollection: [Self] = [.fresh] + studioCollection

    public var activeTone: Self {
        Self.activeCollection.contains(self) ? self : .fresh
    }

    /// Active retro tones resolve from the Audio bundle; all other persisted
    /// click IDs migrate to the single approved Fresh recording.
    public var assetPath: String {
        switch self {
        case .studioCrisp: "cursor-clicks/crisp.wav"
        case .studioSoft: "cursor-clicks/soft.wav"
        case .studioMechanical: "cursor-clicks/mechanical.wav"
        case .studioRelease: "cursor-clicks/release.wav"
        case .studioSnap: "cursor-clicks/snap.wav"
        case .studioTick: "cursor-clicks/tick.wav"
        case .studioLight: "cursor-clicks/light.wav"
        case .studioTap: "cursor-clicks/tap.wav"
        case .mouse: "clicks/mouse-click-1.wav"
        case .subtle: "clicks/tick.wav"
        case .fresh: "clicks/mouse-click-2.wav"
        default: "clicks/analog.wav"
        }
    }

    public var title: String {
        switch self {
        case .studioCrisp: "Retro Classic"
        case .studioSoft: "Retro Soft"
        case .studioMechanical: "Retro Crisp"
        case .studioRelease: "Release"
        case .studioSnap: "Snap"
        case .studioTick: "Tick"
        case .studioLight: "Light"
        case .studioTap: "Tap"
        default: rawValue.capitalized
        }
    }
}

public enum StudioMode: String, Codable, CaseIterable, Sendable {
    case standard = "Studio Standard"
    case optimized = "Studio Optimized"
    public var title: String { rawValue }
}

public struct AudioPlan: Codable, Equatable, Sendable {
    /// Noise reduction is ON by default: a raw mic passthrough was the
    /// "not noticeably cleaner" complaint. Users can still turn it off.
    public var micClean = true
    public var noiseReductionStrength = 1.0
    public var voiceClarity = true
    public var micMode: MicMode = .standard
    /// Gentle compression strength, 0...1; clarity EQ is independent. Replaces the old
    /// `voiceProfile` + `studioAmount` pair. Legacy `studioAmount` values decode
    /// into this field; legacy `voiceProfile == .studio` projects keep the default.
    public var studio = 0.25
    public var micGainDb = 0.0, systemGainDb = -3.0
    public var declick = true, declickDepthDb = -12.0
    /// Room-tail suppression, 0...1. Applied before EQ and compression so the
    /// compressor cannot lift the reverb back up after every phrase.
    public var dereverb = 0.5
    /// Auto loudness. Off makes `outputGainDb` the only master gain.
    public var normalize = true
    public var outputGainDb = 0.0
    /// Lifts the user's own voice ~+2.5 dB (about 30% louder) in the final mix
    /// so it sits in front of system audio and music. Applied after the voice
    /// chain and before the shared master, so the -1 dBTP ceiling still holds.
    public var voiceBoostDb: Double = 2.5
    public var targetLUFSOverride: Double?
    public var targetLUFS: Double { targetLUFSOverride ?? micMode.targetLUFS }
    public var studioMode: StudioMode = .standard
    public var soundEffectsEnabled = true
    /// Zoom whooshes were removed. The symbol stays only because out-of-scope code and
    /// older persisted projects still references it; it is forced off on every decode and
    /// can never enable an audible whoosh.
    public var clickSounds = true, whooshes = false, keySounds = true
    public var typingModel = 2
    public var typingPackId: String = "mechvibes-default"
    public var typingLevelDb: Double = -9.0
    public var clickTone: ClickSound = .fresh
    public var sfxGainDb = -9.0
    public var zoomInGainDb = 0.0, zoomOutGainDb = 0.0, clickGainDb = 0.0
    public var sfxSettingsVersion = 1
    public var musicPath: String?
    public var musicGainDb = -18.0
    public var duckDepthDb = -14.0, duckAttack = 0.05, duckRelease = 0.4
    public var muteMicInRamps = true
    public var speedRampsAuto = true
    public var speedRampMinIdle = 4.0, speedRampMaxSpeed = 8.0
    public var lanes: [AudioLane] = []
    private enum LegacyKeys: String, CodingKey { case studioAmount }
    private enum LegacyLUFSKeys: String, CodingKey { case targetLUFS }
    enum CodingKeys: String, CodingKey {
        case noiseReductionStrength, voiceClarity, outputGainDb, voiceBoostDb, micClean, micMode, studio, micGainDb, systemGainDb, declick, declickDepthDb, targetLUFSOverride, soundEffectsEnabled, clickSounds, whooshes, keySounds, typingPackId, typingLevelDb, clickTone, sfxGainDb, zoomInGainDb, zoomOutGainDb, clickGainDb, sfxSettingsVersion, musicPath
        case dereverb, normalize, studioMode, typingModel
        case musicGainDb, duckDepthDb, duckAttack, duckRelease, muteMicInRamps, speedRampsAuto, speedRampMinIdle, speedRampMaxSpeed, lanes
    }
    public init() {}

    /// Product boundary: a single studio processing policy. Legacy fields stay
    /// decodable for old projects and low-level DSP tests; editing gain and
    /// muting are routing controls, not alternate voice profiles.
    public func studioPolicy() -> AudioPlan {
        var result = self
        result.micMode = micMode == .off ? .off : .standard
        result.micClean = true
        result.noiseReductionStrength = 1
        result.voiceClarity = true
        result.studio = 0.25
        result.studioMode = .standard
        result.dereverb = 0.5
        result.declick = true
        result.declickDepthDb = -12
        result.normalize = true
        result.targetLUFSOverride = nil
        return result
    }

    /// Deliberately conservative whitelist of mixer-only controls.
    /// New fields default to requiring derivation until explicitly audited.
    /// Click gain (embedded in derived cues), ducking and ramp controls are
    /// NOT mix-only. Click tone, key level and SFX bus gain are.
    public func hasSameDerivation(as other: AudioPlan) -> Bool {
        var normalized = self
        normalized.micGainDb = other.micGainDb
        normalized.systemGainDb = other.systemGainDb
        normalized.outputGainDb = other.outputGainDb
        normalized.voiceBoostDb = other.voiceBoostDb
        normalized.musicGainDb = other.musicGainDb
        normalized.typingLevelDb = other.typingLevelDb
        normalized.sfxGainDb = other.sfxGainDb
        normalized.clickTone = other.clickTone
        return normalized == other
    }

    public static func migrateLUFS(override: Double?, legacy: Double?, mode: MicMode) -> Double? {
        if let o = override { return o }
        guard let l = legacy else { return nil }
        let oldDefault: Double = mode == .loud ? -12 : -16
        if abs(l - oldDefault) < 1e-9 || abs(l - mode.targetLUFS) < 1e-9 || (mode == .standard && abs(l + 14) < 1e-9) { return nil }
        return l
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        outputGainDb = c.opt(.outputGainDb, outputGainDb)
        let boost = c.opt(.voiceBoostDb, voiceBoostDb)
        voiceBoostDb = boost.isFinite ? min(max(boost, 0), 6) : 2.5
        micClean = c.opt(.micClean, micClean); micMode = c.opt(.micMode, micMode)
        let reduction = c.opt(.noiseReductionStrength, noiseReductionStrength)
        noiseReductionStrength = reduction.isFinite ? min(max(reduction, 0), 1) : 1
        voiceClarity = c.opt(.voiceClarity, voiceClarity)
        // Legacy `studioAmount` decodes into `studio` when the new key is absent.
        if let lc = try? d.container(keyedBy: LegacyKeys.self),
           let v = try lc.decodeIfPresent(Double.self, forKey: .studioAmount) {
            studio = v
        }
        studio = c.opt(.studio, studio)
        micGainDb = c.opt(.micGainDb, micGainDb)
        dereverb = c.opt(.dereverb, dereverb); normalize = c.opt(.normalize, normalize)
        systemGainDb = c.opt(.systemGainDb, systemGainDb); declick = c.opt(.declick, declick); declickDepthDb = c.opt(.declickDepthDb, declickDepthDb)
        let legacyLUFS = (try? d.container(keyedBy: LegacyLUFSKeys.self).decodeIfPresent(Double.self, forKey: .targetLUFS)) ?? nil
        targetLUFSOverride = AudioPlan.migrateLUFS(override: (try? c.decode(Double.self, forKey: .targetLUFSOverride)), legacy: legacyLUFS, mode: micMode); clickSounds = c.opt(.clickSounds, clickSounds); whooshes = false
        studioMode = c.opt(.studioMode, studioMode)
        soundEffectsEnabled = c.opt(.soundEffectsEnabled, soundEffectsEnabled)
        keySounds = c.opt(.keySounds, keySounds); typingPackId = c.opt(.typingPackId, typingPackId); typingLevelDb = c.opt(.typingLevelDb, typingLevelDb); clickTone = c.opt(.clickTone, clickTone); sfxGainDb = c.opt(.sfxGainDb, sfxGainDb)
        // Whoosh gain knobs are inert: no whoosh asset is bundled or rendered.
        zoomInGainDb = 0; zoomOutGainDb = 0; clickGainDb = c.opt(.clickGainDb, clickGainDb)
        typingModel = c.opt(.typingModel, 1)
        if typingModel < 2 {
            keySounds = true; typingLevelDb = -9; typingPackId = "mechvibes-default"; typingModel = 2
        }
        let oldSFXSettings = c.opt(.sfxSettingsVersion, 0)
        if oldSFXSettings < 1 && abs(typingLevelDb + 12) < 0.001 { typingLevelDb = -9 }
        sfxSettingsVersion = 1
        musicPath = try? c.decodeIfPresent(String.self, forKey: .musicPath)
        musicGainDb = c.opt(.musicGainDb, musicGainDb); duckDepthDb = c.opt(.duckDepthDb, duckDepthDb); duckAttack = c.opt(.duckAttack, duckAttack)
        duckRelease = c.opt(.duckRelease, duckRelease); muteMicInRamps = c.opt(.muteMicInRamps, muteMicInRamps)
        speedRampsAuto = c.opt(.speedRampsAuto, speedRampsAuto); speedRampMinIdle = c.opt(.speedRampMinIdle, speedRampMinIdle)
        speedRampMaxSpeed = c.opt(.speedRampMaxSpeed, speedRampMaxSpeed); lanes = c.opt(.lanes, lanes)
    }
}

public enum WebcamBackdrop: String, Codable, CaseIterable, Sendable {
    case original = "Original"
    case transparent = "Remove background"
    case wallpaper = "Desktop wallpaper"
    case canvas = "Canvas color"
    case image = "Choose image"
}

public enum WebcamEnhancement: String, Codable, CaseIterable, Sendable {
    case natural = "Natural"
    case crisp = "Crisp"
}

public struct WebcamLayout: Codable, Equatable, Sendable {
    public enum Corner: String, Codable, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }
    public enum Shape: String, Codable, CaseIterable, Sendable { case circle, roundRect }
    public var corner: Corner = .bottomRight
    public var size = 0.22
    public var shape: Shape = .circle
    public var mirror = true, border = true, shadow = true, autoFrame = true
    public var faceFill = 0.31
    public var faceZoom = 0.6
    public var backdrop: WebcamBackdrop = .original
    public var backdropImagePath: String?
    public var enhancement: WebcamEnhancement = .natural
    public var detailAmount = 0.5
    public init() {}
    enum CodingKeys: String, CodingKey { case corner, size, shape, mirror, border, shadow, autoFrame, faceFill, faceZoom, backdrop, backdropImagePath, enhancement, detailAmount }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        corner = try c.decodeIfPresent(Corner.self, forKey: .corner) ?? corner
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? size
        shape = try c.decodeIfPresent(Shape.self, forKey: .shape) ?? shape
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? mirror
        border = try c.decodeIfPresent(Bool.self, forKey: .border) ?? border
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? shadow
        autoFrame = try c.decodeIfPresent(Bool.self, forKey: .autoFrame) ?? autoFrame
        faceFill = try c.decodeIfPresent(Double.self, forKey: .faceFill) ?? faceFill
        faceZoom = try c.decodeIfPresent(Double.self, forKey: .faceZoom) ?? faceZoom
        backdrop = try c.decodeIfPresent(WebcamBackdrop.self, forKey: .backdrop) ?? backdrop
        backdropImagePath = try c.decodeIfPresent(String.self, forKey: .backdropImagePath)
        enhancement = try c.decodeIfPresent(WebcamEnhancement.self, forKey: .enhancement) ?? enhancement
        detailAmount = try c.decodeIfPresent(Double.self, forKey: .detailAmount) ?? detailAmount
    }
}

public enum Focus: Codable, Equatable, Sendable {
    case follow
    case fixed(x: Double, y: Double)                      // normalized source coords
    case element(x: Double, y: Double, w: Double, h: Double)
}

/// start/end are SOURCE seconds (content-anchored). The camera solver converts to output time through the TimeMap.
public struct ZoomSegment: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var start: Double, end: Double
    public var scale: Double
    public var focus: Focus
    public var easing: ZoomEasing?
    public var origin: Origin
    public init(id: UUID = UUID(), start: Double, end: Double, scale: Double, focus: Focus, easing: ZoomEasing? = nil, origin: Origin) {
        self.id = id; self.start = start; self.end = end; self.scale = scale; self.focus = focus; self.easing = easing; self.origin = origin
    }
}

public struct SpeedRamp: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var start: Double, end: Double                 // SOURCE seconds
    public var speed: Double
    public var origin: Origin = .auto
    public init(start: Double, end: Double, speed: Double, origin: Origin = .auto) {
        self.start = start; self.end = end; self.speed = speed; self.origin = origin
    }
}

/// Output<->source time map. Cuts remove source spans (zero output length); ramps retime. Table is rebuilt on mutation, never persisted.
public struct TimeMap: Codable, Equatable, Sendable {
    public var sourceDuration: Double { didSet { rebuild() } }
    public var trimStart: Double { didSet { rebuild() } }
    public var trimEnd: Double { didSet { rebuild() } }
    public var ramps: [SpeedRamp] { didSet { rebuild() } }
    public var cuts: [CutRange] { didSet { rebuild() } }
    private var out: [Double] = []
    private static let ds = 1.0 / 240
    /// Instrumentation only: how many times the lookup table was rebuilt.
    /// Deliberately outside CodingKeys and `==` so it never changes a saved
    /// project or an undo snapshot; bulk edits use it to prove they rebuild once.
    public private(set) var rebuildCount: Int = 0
    enum CodingKeys: String, CodingKey { case sourceDuration, trimStart, trimEnd, ramps, cuts }

    public init(sourceDuration: Double = 0, trimStart: Double = 0, trimEnd: Double? = nil, ramps: [SpeedRamp] = [], cuts: [CutRange] = []) {
        self.sourceDuration = sourceDuration; self.trimStart = trimStart; self.trimEnd = trimEnd ?? sourceDuration
        self.ramps = ramps; self.cuts = cuts
        rebuild()
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sourceDuration = try c.decode(Double.self, forKey: .sourceDuration); trimStart = try c.decode(Double.self, forKey: .trimStart)
        trimEnd = try c.decode(Double.self, forKey: .trimEnd); ramps = try c.decode([SpeedRamp].self, forKey: .ramps)
        cuts = c.opt(.cuts, [CutRange]())
        rebuild()
    }
    public static func == (a: TimeMap, b: TimeMap) -> Bool {
        a.sourceDuration == b.sourceDuration && a.trimStart == b.trimStart && a.trimEnd == b.trimEnd && a.ramps == b.ramps && a.cuts == b.cuts
    }
    private mutating func rebuild() {
        rebuildCount += 1
        guard trimStart.isFinite, trimEnd.isFinite, trimEnd >= trimStart else { out = [0]; return }
        let ticks = ((trimEnd - trimStart) / Self.ds).rounded(.up)
        // Bound hostile decoded project metadata before allocating or converting.
        // A 24-hour recording is the upper supported dense-map duration.
        guard ticks.isFinite, ticks <= 24 * 3600 / Self.ds else { out = [0]; return }
        let n = Int(ticks)
        var o = [Double](repeating: 0, count: n + 1)
        let rs = ramps.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.speed.isFinite && $0.speed > 0 }.sorted { $0.start < $1.start }
        let cs = cuts.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }.sorted { $0.start < $1.start }
        var j = 0, jc = 0
        for i in 0..<n {
            let s = trimStart + (Double(i) + 0.5) * Self.ds
            while jc < cs.count && cs[jc].end <= s { jc += 1 }
            if jc < cs.count && s >= cs[jc].start { o[i + 1] = o[i]; continue }
            while j < rs.count && rs[j].end < s { j += 1 }
            var m = 1.0
            if j < rs.count, s >= rs[j].start {
                let r = rs[j], w = max(min(0.5, (r.end - r.start) / 4), 0.01)
                m = 1 + (r.speed - 1) * smoothstep((s - r.start) / w) * smoothstep((r.end - s) / w)
            }
            o[i + 1] = o[i] + Self.ds / m
        }
        out = o
    }
    public var outputDuration: Double { out.last ?? 0 }
    public func isCut(_ s: Double) -> Bool { cuts.contains { s >= $0.start && s < $0.end } }
    public func output(atSource s: Double) -> Double {
        guard s.isFinite else { return 0 }
        let f = (s - trimStart) / Self.ds
        guard f.isFinite, f > 0 else { return 0 }
        guard f < Double(max(out.count - 1, 0)) else { return out.last ?? 0 }
        let i = Int(f)
        return out[i] + (out[i + 1] - out[i]) * (f - Double(i))
    }
    public func source(atOutput t: Double) -> Double {
        guard t.isFinite, trimStart.isFinite, out.count > 1 else { return trimStart.isFinite ? trimStart : 0 }
        if t < 0 { return trimStart }
        if t >= out[out.count - 1] { return trimStart + Double(out.count - 1) * Self.ds }
        var lo = 0, hi = out.count - 1
        // A cut makes many consecutive table entries identical. Accumulated
        // float error can put that plateau a hair ABOVE an exact seam time
        // (e.g. 0.2500000000000003 for a cut at 0.25), which would select the
        // last frame before the cut instead of the first one after it. The
        // epsilon is a millionth of a source tick, far below any frame.
        let eps = Self.ds * 1e-6
        while hi - lo > 1 { let mid = (lo + hi) / 2; if out[mid] <= t + eps { lo = mid } else { hi = mid } }
        let span = out[lo + 1] - out[lo]
        // The epsilon above can put t a hair below out[lo]; clamp instead of
        // extrapolating a negative fraction past the seam.
        let f = span > 0 ? min(max((t - out[lo]) / span, 0), 1) : 0
        return trimStart + (Double(lo) + f) * Self.ds
    }
    public func speed(atOutput t: Double) -> Double { (source(atOutput: t + 0.01) - source(atOutput: t)) / 0.01 }
}

/// A logical split boundary inside the recording. A seam changes nothing in
/// the output: it only lets the magnetic lane show, select and join two halves
/// of one continuous source range. Stored in SOURCE seconds.
public struct SplitSeam: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var t: Double
    public init(id: UUID = UUID(), t: Double) { self.id = id; self.t = t }
}

/// Time-varying crop for Area capture. `roi` is stored normalized to the
/// source frame, the same coordinate space the planner uses for focus rects.
/// A nil or empty ROI means "no smart crop" and keeps the static sourceRect
/// behaviour.
public struct SmartCropConfig: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var roi: CGRect? = nil
    /// Points, in the source display's own scale; converted to source px before use.
    public var revealMarginPt: Double = 24
    /// Output seconds from the end of an intent to the fully restored crop.
    public var returnSeconds: Double = 0.45
    public init() {}
    public init(enabled: Bool, roi: CGRect? = nil, revealMarginPt: Double = 24, returnSeconds: Double = 0.45) {
        self.enabled = enabled; self.roi = roi
        self.revealMarginPt = revealMarginPt; self.returnSeconds = returnSeconds
    }
    public var isActive: Bool {
        guard enabled, let r = roi else { return false }
        return r.width > 0 && r.height > 0
    }
}

public struct Timeline: Sendable, Codable, Equatable {
    public var schemaVersion = 5
    public var timeMap: TimeMap
    /// Logical split points in the recording, source seconds. No output effect.
    public var seams: [SplitSeam] = []
    public var zoom: [ZoomSegment] = []
    /// AGENT: ids of automatic zooms a human deleted. Replanning used to add
    /// them straight back, so the delete never stuck.
    public var suppressedAuto: [String] = []
    public var style = Style()
    public var cursor = CursorStyle()
    public var camera = CameraParams()
    public var audio = AudioPlan()
    public var webcam: WebcamLayout?
    public var overlays = Overlays()
    public var layouts: [LayoutSegment] = []
    public var layoutSettings = LayoutSet()
    public var captions = CaptionPlan()
    /// Command-key pills burned into the exported picture. Off by default so
    /// existing projects render exactly as before.
    public var shortcutOverlay = ShortcutOverlayPlan()
    /// Imported video appended after the recording, in OUTPUT seconds.
    public var clips: [TimelineClip] = []
    /// Requested crossfade at magnetic-lane clip joins, in OUTPUT seconds.
    /// A project-wide scalar: a request, not a promise (see `effectiveCrossfade`).
    public var crossfadeDuration: Double = 0
    /// The usable crossfade: never longer than half the shortest clip, so a
    /// join can always be covered from both sides.
    public var effectiveCrossfade: Double {
        guard crossfadeDuration.isFinite, crossfadeDuration > 0 else { return 0 }
        let shortest = clips.map(\.duration).min() ?? Double.infinity
        return min(crossfadeDuration, max(shortest / 2, 0))
    }
    public var smartCrop = SmartCropConfig()
    /// Browser-content crop tuning (F1). Old projects decode to defaults.
    public var cropSettings = CropSettings()
    /// Activity-driven auto-zoom tuning (F2). Old projects decode to defaults.
    public var activity = ActivitySettings()
    public var derived: DerivedTracks?
    enum CodingKeys: String, CodingKey {
        case schemaVersion, timeMap, zoom, suppressedAuto, style, cursor, camera, audio, webcam, overlays, layouts, layoutSettings, captions, shortcutOverlay, clips, crossfadeDuration, seams, smartCrop, cropSettings, activity
    }
    public init(duration: Double) { timeMap = TimeMap(sourceDuration: duration) }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        timeMap = try c.decode(TimeMap.self, forKey: .timeMap)
        let version = c.opt(.schemaVersion, 1)
        schemaVersion = 5
        seams = c.opt(.seams, seams)
        zoom = c.opt(.zoom, zoom)
        suppressedAuto = c.opt(.suppressedAuto, suppressedAuto)
        if version < 2 { for i in zoom.indices { zoom[i].start = timeMap.source(atOutput: zoom[i].start); zoom[i].end = timeMap.source(atOutput: zoom[i].end) } }
        if version < 4 {
            // v3 -> v4: legacy Loudness key targetLUFS is handled inside AudioPlan decode.
        }
         style = c.opt(.style, style); cursor = c.opt(.cursor, cursor); camera = c.opt(.camera, camera)
        audio = c.opt(.audio, audio).studioPolicy(); webcam = try? c.decodeIfPresent(WebcamLayout.self, forKey: .webcam)
        overlays = c.opt(.overlays, overlays); layouts = c.opt(.layouts, layouts); layoutSettings = c.opt(.layoutSettings, layoutSettings)
        captions = c.opt(.captions, captions)
        shortcutOverlay = c.opt(.shortcutOverlay, shortcutOverlay)
        clips = c.opt(.clips, clips)
        crossfadeDuration = c.opt(.crossfadeDuration, 0)
        smartCrop = c.opt(.smartCrop, smartCrop)
        // v4 -> v5: crop and activity settings did not exist; defaults apply.
        cropSettings = c.opt(.cropSettings, cropSettings)
        activity = c.opt(.activity, activity)
    }

    /// Total length of the deliverable: the edited recording plus any imported clips.
    public var compositionDuration: Double {
        max(timeMap.outputDuration, clips.map(\.end).max() ?? 0)
    }
    public func clip(atOutput t: Double) -> TimelineClip? {
        clips.first { $0.contains(output: t) }
    }
    /// Output time -> seconds inside the imported file, or nil on the recording.
    public func clipSource(atOutput t: Double) -> (clip: TimelineClip, time: Double)? {
        guard let c = clip(atOutput: t) else { return nil }
        return (c, c.sourceTime(atOutput: t))
    }
}

// MARK: Bundle

public struct SourceInfo: Codable, Sendable {
    public var width: Int, height: Int
    public var fps: Double, duration: Double, backingScale: Double
    public var originX: Double, originY: Double
    public init(width: Int, height: Int, fps: Double, duration: Double, backingScale: Double, originX: Double, originY: Double) {
        self.width = width; self.height = height; self.fps = fps; self.duration = duration
        self.backingScale = backingScale; self.originX = originX; self.originY = originY
    }
}
public struct TrackMeta: Codable, Sendable {
    public var file: String, startHostSeconds: Double
    public init(file: String, startHostSeconds: Double) { self.file = file; self.startHostSeconds = startHostSeconds }
}
/// Separately recorded additional microphone or loopback source.
public struct MicrophoneSourceMeta: Codable, Sendable {
    public var deviceID: String, deviceName: String
    public var track: TrackMeta
    public init(deviceID: String, deviceName: String, track: TrackMeta) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.track = track
    }
}

public struct ProjectMeta: Codable, Sendable {
    public var name: String
    public var created = Date()
    public var analysisSalt: UInt64
    public var source: SourceInfo
    public var clock: RecordingClock
    public var mic: TrackMeta?, system: TrackMeta?, webcam: TrackMeta?
    /// Older projects have no additional inputs; decoding defaults to empty.
    public var additionalMicrophones: [MicrophoneSourceMeta] = []
    public var droppedFrames = 0
    public var captureResolution: String = "native"
    public var captureQuality: String = "high"
    public var captureMbps: Double = 0
    enum CodingKeys: String, CodingKey { case name, created, analysisSalt, source, clock, mic, system, webcam, additionalMicrophones, droppedFrames, captureResolution, captureQuality, captureMbps }
    public init(name: String, source: SourceInfo, clock: RecordingClock) {
        self.name = name; self.analysisSalt = UInt64.random(in: UInt64.min...UInt64.max); self.source = source; self.clock = clock
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date(timeIntervalSince1970: 0)
        analysisSalt = (try? c.decode(UInt64.self, forKey: .analysisSalt)) ?? fnv1a64(name + String(created.timeIntervalSince1970))
        source = try c.decode(SourceInfo.self, forKey: .source)
        clock = try c.decode(RecordingClock.self, forKey: .clock)
        mic = try? c.decodeIfPresent(TrackMeta.self, forKey: .mic)
        system = try? c.decodeIfPresent(TrackMeta.self, forKey: .system)
        webcam = try? c.decodeIfPresent(TrackMeta.self, forKey: .webcam)
        additionalMicrophones = (try? c.decode([MicrophoneSourceMeta].self, forKey: .additionalMicrophones)) ?? []
        droppedFrames = (try? c.decode(Int.self, forKey: .droppedFrames)) ?? 0
        captureResolution = (try? c.decode(String.self, forKey: .captureResolution)) ?? "native"
        captureQuality = (try? c.decode(String.self, forKey: .captureQuality)) ?? "high"
        captureMbps = (try? c.decode(Double.self, forKey: .captureMbps)) ?? 0
    }
}
public struct ProjectFile: Codable, Sendable {
    public var meta: ProjectMeta
    public var timeline: Timeline
    // AGENT: both the editor and daemon need a revision persisted with the project for compare-and-swap saves.
    public var revision: Int? = nil
    public init(meta: ProjectMeta, timeline: Timeline, revision: Int? = nil) {
        self.meta = meta; self.timeline = timeline; self.revision = revision
    }
}

public enum ProjectError: Error, Sendable {
    case conflict(expected: Int, actual: Int)
}
/// Provenance and freshness of one accessibility sample.
///
/// Capture owns it; consumers (Director, privacy policy) only read it. A
/// sample is usable only when `epoch` matches the focused element the event
/// resolved to and `sampledAt` is recent — otherwise it is stale evidence and
/// must not aim a camera or place a mask.
///
/// `host` is a verified registrable host only (`mail.google.com`). A full URL
/// is never stored: paths and query strings carry the very content privacy
/// exists to protect.
public struct FocusAnchor: Codable, Sendable, Equatable {
    /// Increments whenever the focused element changes identity. A sample from
    /// a different epoch describes a different field and must be discarded.
    public var epoch: UInt32
    /// Host seconds of the accessibility sample (same clock as AXFrame.sampledAt).
    public var sampledAt: Double
    /// Verified browser host, when the focused app is a known browser and the
    /// host could be established from legitimate AX evidence. Never a URL.
    public var host: String?
    /// Captured window id, so a mask can reset at a window change.
    public var windowID: Int?
    /// Captured application name, for diagnostics and legacy-context decisions.
    public var appName: String?
    /// True when the sample came from a successful AX query rather than an estimate.
    public var resolved: Bool

    public init(epoch: UInt32 = 0, sampledAt: Double = 0, host: String? = nil, windowID: Int? = nil,
                appName: String? = nil, resolved: Bool = false) {
        self.epoch = epoch; self.sampledAt = sampledAt; self.host = host
        self.windowID = windowID; self.appName = appName; self.resolved = resolved
    }
}

public struct AXFrame: Codable, Sendable {
    public struct Rect: Codable, Sendable {
        public var x: Double, y: Double, w: Double, h: Double
        public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    }
    public var caret: Rect? = nil
    public var sampledAt: Double? = nil
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    /// Secure text field (password/CC) or a field whose title names one.
    public var secure: Bool
    /// Best-effort AX title/description so labels like "Password" mask too.
    public var label: String?
    /// Provenance/freshness/context of this sample. Absent on projects written
    /// before it existed: those samples are treated as unknown context.
    public var anchor: FocusAnchor? = nil
    public init(x: Double, y: Double, w: Double, h: Double, secure: Bool = false, label: String? = nil,
                anchor: FocusAnchor? = nil) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.secure = secure
        self.label = label
        self.anchor = anchor
    }
    enum CodingKeys: String, CodingKey { case x, y, w, h, secure, label, caret, sampledAt, anchor }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        x = (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? 0
        y = (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? 0
        w = (try? c.decodeIfPresent(Double.self, forKey: .w)) ?? 0
        h = (try? c.decodeIfPresent(Double.self, forKey: .h)) ?? 0
        caret = try c.decodeIfPresent(Rect.self, forKey: .caret)
        sampledAt = try c.decodeIfPresent(Double.self, forKey: .sampledAt)
        secure = c.opt(.secure, false); label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
        anchor = try c.decodeIfPresent(FocusAnchor.self, forKey: .anchor)
    }
}

public struct ProjectBundle: Sendable, Hashable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static func create(named: String, in dir: URL) throws -> ProjectBundle {
        let u = dir.appendingPathComponent(named).appendingPathExtension("lumen")
        for sub in ["cache", "thumbs"] {
            try FileManager.default.createDirectory(at: u.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return .init(url: u)
    }
    private func f(_ n: String) -> URL { url.appendingPathComponent(n) }
    public var projectURL: URL { f("project.json") }
    public var screenURL: URL { f("screen.mov") }
    public var framesMetaURL: URL { f("frames.meta") }
    public var eventsURL: URL { f("events.bin") }
    public var cursorsURL: URL { f("cursors.json") }
    public var axURL: URL { f("ax.json") }
    public var micURL: URL { f("mic.caf") }
    public var systemURL: URL { f("system.caf") }
    public var webcamURL: URL { f("webcam.mov") }
    public var cacheURL: URL { f("cache") }

    /// Saves atomically under a per-project lock and optionally checks the prior revision.
    // AGENT: the editor and MCP engine previously overwrote project.json without coordinating revisions.
    @discardableResult
    public func save(_ file: ProjectFile, expectingRevision: Int? = nil) throws -> Int {
        let lockURL = f("project.lock")
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(lockFD, LOCK_UN) }
        let actualRevision: Int
        if FileManager.default.fileExists(atPath: projectURL.path) {
            actualRevision = try load().revision ?? 0
        } else {
            actualRevision = 0
        }
        if let expectingRevision, expectingRevision != actualRevision {
            throw ProjectError.conflict(expected: expectingRevision, actual: actualRevision)
        }
        var persisted = file
        persisted.revision = actualRevision + 1
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(persisted).write(to: projectURL, options: .atomic)
        return actualRevision + 1
    }
    public func load() throws -> ProjectFile {
        var file = try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: projectURL))
        // Shared packages store imported clips relative to the bundle. Resolve
        // them here so every consumer keeps seeing one absolute path.
        for i in file.timeline.clips.indices where !file.timeline.clips[i].path.hasPrefix("/") {
            file.timeline.clips[i].path = url.appendingPathComponent(file.timeline.clips[i].path).path
        }
        return file
    }
    /// events.bin stores absolute host seconds (crash-safe, append-only). Rebased here.
    public func events(origin: Double) throws -> [InputEvent] {
        var ev = EventCodec.decode(try Data(contentsOf: eventsURL))
        for i in ev.indices { ev[i].t -= origin }
        return ev.filter { $0.t >= 0 }.sorted { $0.t < $1.t }
    }
}
