import Foundation
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

/// Two flat tones, ordered-dithered into a pixel field. Base first, ink second.
public enum DitherPalettes {
    public static let all: [(String, [RGBA])] = [
        ("Ember", [RGBA(0x0A0A0A), RGBA(0xFF6A00)]),
        ("Ember white", [RGBA(0xF4F4F4), RGBA(0xF05A00)]),
        ("Ocean", [RGBA(0x06121F), RGBA(0x38BDF8)]),
        ("Ocean white", [RGBA(0xEFF6FF), RGBA(0x2563EB)]),
        ("Moss", [RGBA(0x07130C), RGBA(0x4ADE80)]),
        ("Moss white", [RGBA(0xF0FDF4), RGBA(0x16A34A)]),
        ("Rose", [RGBA(0x140A10), RGBA(0xF472B6)]),
        ("Rose white", [RGBA(0xFDF2F8), RGBA(0xDB2777)]),
        ("Graphite", [RGBA(0x0A0A0A), RGBA(0x525252)]),
        ("Paper", [RGBA(0xF4F4F4), RGBA(0x171717)]),
    ]
    public static func colors(named name: String) -> [RGBA] {
        all.first { $0.0 == name }?.1 ?? all[0].1
    }
}

/// Legacy gradients are kept for decoding old projects; the picker offers dither, canvas, wallpaper and solid.
public enum BackgroundKind: String, Codable, CaseIterable, Sendable {
    case dither, canvas, wallpaper, solid, gradient, mesh, wave, field
    public static let offered: [BackgroundKind] = [.solid, .wave, .field, .canvas, .wallpaper]
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
    public var background: BackgroundKind = .solid
    public var colors: [RGBA] = [RGBA(0xF4F4F4), RGBA(0xDADADA)]
    public var gradientAngle: Double = 35
    public var ditherCell: Double = 4, ditherDensity: Double = 0.55, contentScale: Double = 1
    public var padding: Double = 0.06
    public var cornerRadius: Double = 14
    public var shadow: Double = 0.45
    public var innerBorder = true
    public var canvas: CanvasAspect = .r16x9
    public var paddingInsets: EdgeInsetsN?              // nil = uniform `padding`
    public var cornerRadii: CornerRadii?                // nil = uniform `cornerRadius`
    public var customAspect: Double?                    // nil = `canvas`
    public var zoomBackgroundBlur = false
    public var aspectRatio: Double { customAspect ?? canvas.ratio }
    public var insets: EdgeInsetsN { paddingInsets ?? EdgeInsetsN(all: padding) }
    public var radii: CornerRadii { cornerRadii ?? CornerRadii(all: cornerRadius) }
    enum CodingKeys: String, CodingKey {
        case background, colors, gradientAngle, ditherCell, ditherDensity, contentScale, padding, cornerRadius, shadow, innerBorder, canvas, paddingInsets, cornerRadii, customAspect, zoomBackgroundBlur
    }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        background = c.opt(.background, background); colors = c.opt(.colors, colors); gradientAngle = c.opt(.gradientAngle, gradientAngle)
        ditherCell = c.opt(.ditherCell, 12); ditherDensity = c.opt(.ditherDensity, ditherDensity); contentScale = c.opt(.contentScale, contentScale)
        padding = c.opt(.padding, padding); cornerRadius = c.opt(.cornerRadius, cornerRadius); shadow = c.opt(.shadow, shadow)
        innerBorder = c.opt(.innerBorder, innerBorder); canvas = c.opt(.canvas, canvas)
        paddingInsets = try? c.decodeIfPresent(EdgeInsetsN.self, forKey: .paddingInsets)
        cornerRadii = try? c.decodeIfPresent(CornerRadii.self, forKey: .cornerRadii)
        customAspect = try? c.decodeIfPresent(Double.self, forKey: .customAspect)
        zoomBackgroundBlur = c.opt(.zoomBackgroundBlur, zoomBackgroundBlur)
    }
}

public enum CursorPack: String, Codable, CaseIterable, Sendable { case system, minimal, dot, ring, pro }
public struct CursorStyle: Codable, Equatable, Sendable {
    public var pack: CursorPack = .system
    public var size: Double = 1.0
    public var smoothingSigma: Double = 0.035
    public var glide: Double = 0.35
    public var idleHide: Double? = 2.0
    public var pressScale: Double = 0.86
    public var clickRing: Double? = 0.45
    public var zoomCompensation: Double = 0.5
    public var constantSize = false                     // true = cursor keeps its on-screen size during zoom
    public var loop: Double?                            // seconds of tail that glides back to the first frame; nil = off
    public var effectiveCompensation: Double { constantSize ? 1 : zoomCompensation }
    enum CodingKeys: String, CodingKey { case pack, size, smoothingSigma, glide, idleHide, pressScale, clickRing, zoomCompensation, constantSize, loop }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        pack = c.opt(.pack, pack); size = c.opt(.size, size); smoothingSigma = c.opt(.smoothingSigma, smoothingSigma); glide = c.opt(.glide, glide)
        idleHide = c.contains(.idleHide) ? ((try? c.decodeIfPresent(Double.self, forKey: .idleHide)) ?? nil) : idleHide
        pressScale = c.opt(.pressScale, pressScale)
        clickRing = c.contains(.clickRing) ? ((try? c.decodeIfPresent(Double.self, forKey: .clickRing)) ?? nil) : clickRing
        zoomCompensation = c.opt(.zoomCompensation, zoomCompensation); constantSize = c.opt(.constantSize, constantSize)
        loop = try? c.decodeIfPresent(Double.self, forKey: .loop)
    }
    public func encode(to e: Encoder) throws {      // explicit nulls so "off" survives a round trip
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(pack, forKey: .pack); try c.encode(size, forKey: .size); try c.encode(smoothingSigma, forKey: .smoothingSigma)
        try c.encode(glide, forKey: .glide); try c.encode(idleHide, forKey: .idleHide); try c.encode(pressScale, forKey: .pressScale)
        try c.encode(clickRing, forKey: .clickRing); try c.encode(zoomCompensation, forKey: .zoomCompensation)
        try c.encode(constantSize, forKey: .constantSize); try c.encodeIfPresent(loop, forKey: .loop)
    }
}

public enum ZoomPreset: String, Codable, CaseIterable, Sendable {
    case subtle, balanced, dramatic, cinematic, fixed
    public var maxScale: Double { switch self { case .subtle: 1.6; case .balanced: 2.2; case .dramatic: 3.0; case .cinematic: 2.6; case .fixed: 2.0 } }
}
public enum TiltMode: String, Codable, CaseIterable, Sendable { case off, lean, float, reveal }
public enum ZoomEasing: String, Codable, CaseIterable, Sendable {
    case snappy, smooth, cinematic
    public var omegaScale: Double { switch self { case .snappy: 1.35; case .smooth: 1.0; case .cinematic: 0.65 } }
}

public struct CameraParams: Codable, Equatable, Sendable {
    public var preset: ZoomPreset = .balanced
    public var autoZoom = true
    public var maxScale = 2.2
    public var minScale = 1.5
    public var minTrigger = 1.25
    public var leadIn = 0.45, tail = 0.7, mergeGap = 2.5, panThroughGap = 1.5, minHold = 1.0
    public var omegaPan = 7.0, omegaZoom = 6.0, lookahead = 0.20, deadZone = 0.28, followDelay = 0.12
    public var centerOffsetX = 0.0, centerOffsetY = 0.0         // view-normalized bias of where the cursor sits in the zoomed view
    public var sensitivity = 0.5                                // 0 = only clicks, 1 = purposeful hovers count too
    public var clickWeight = 3.0
    public var shutter = 0.5
    public var maxSamples = 8
    public var tilt: TiltMode = .off
    public var maxYaw = 8.0, maxPitch = 6.0, floatDeg = 1.2, omegaTilt = 5.0
    public var tiltSeed: UInt64 = 0xC11C
    enum CodingKeys: String, CodingKey {
        case preset, autoZoom, maxScale, minScale, minTrigger, leadIn, tail, mergeGap, panThroughGap, minHold, omegaPan, omegaZoom, lookahead, deadZone
        case followDelay, centerOffsetX, centerOffsetY, sensitivity, clickWeight, shutter, maxSamples, tilt, maxYaw, maxPitch, floatDeg, omegaTilt, tiltSeed
    }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        preset = c.opt(.preset, preset); autoZoom = c.opt(.autoZoom, autoZoom); maxScale = c.opt(.maxScale, maxScale); minScale = c.opt(.minScale, minScale)
        minTrigger = c.opt(.minTrigger, minTrigger); leadIn = c.opt(.leadIn, leadIn); tail = c.opt(.tail, tail); mergeGap = c.opt(.mergeGap, mergeGap)
        panThroughGap = c.opt(.panThroughGap, panThroughGap); minHold = c.opt(.minHold, minHold); omegaPan = c.opt(.omegaPan, omegaPan)
        omegaZoom = c.opt(.omegaZoom, omegaZoom); lookahead = c.opt(.lookahead, lookahead); deadZone = c.opt(.deadZone, deadZone)
        followDelay = c.opt(.followDelay, followDelay); centerOffsetX = c.opt(.centerOffsetX, centerOffsetX); centerOffsetY = c.opt(.centerOffsetY, centerOffsetY)
        sensitivity = c.opt(.sensitivity, sensitivity); clickWeight = c.opt(.clickWeight, clickWeight); shutter = c.opt(.shutter, shutter)
        maxSamples = c.opt(.maxSamples, maxSamples); tilt = c.opt(.tilt, tilt); maxYaw = c.opt(.maxYaw, maxYaw); maxPitch = c.opt(.maxPitch, maxPitch)
        floatDeg = c.opt(.floatDeg, floatDeg); omegaTilt = c.opt(.omegaTilt, omegaTilt); tiltSeed = c.opt(.tiltSeed, tiltSeed)
    }
    /// Applies a preset's whole feel. Sliders edited afterwards stick (nothing re-applies the preset behind the user's back).
    public mutating func apply(preset p: ZoomPreset) {
        preset = p; maxScale = p.maxScale
        leadIn = 0.45; tail = 0.7; omegaPan = 7; omegaZoom = 6; shutter = 0.5; tilt = .off
        if p == .cinematic { leadIn = 0.9; tail = 1.1; omegaPan = 4.5; omegaZoom = 4.0; shutter = 0.6; tilt = .lean }
    }
}

public enum MicMode: String, Codable, CaseIterable, Sendable {
    case standard, loud, podcast, off
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
    public init(id: UUID = UUID(), role: Role, path: String? = nil, placement: Double = 0, gainDb: Double = 0, mute: Bool = false,
                separateTrack: Bool = false, variant: String? = nil) {
        self.id = id; self.role = role; self.path = path; self.placement = placement; self.gainDb = gainDb; self.mute = mute
        self.separateTrack = separateTrack; self.variant = variant
    }
}

public enum ClickSound: String, Codable, CaseIterable, Sendable { case mouse, subtle }

/// Optional mastering of microphone speech only. Existing projects decode as natural.
public enum VoiceProfile: String, Codable, CaseIterable, Sendable {
    case natural = "Natural", studio = "Studio"
}

public struct AudioPlan: Codable, Equatable, Sendable {
    public var micClean = true
    public var micMode: MicMode = .standard
    public var voiceProfile: VoiceProfile = .natural
    public var studioAmount = 0.65
    public var micGainDb = 0.0, systemGainDb = -3.0
    public var declick = true, declickDepthDb = -12.0
    public var outputGainDb = 0.0
    public var targetLUFS = -14.0
    public var clickSounds = true, whooshes = true, keySounds = false
    public var clickTone: ClickSound = .mouse
    public var sfxGainDb = -20.0
    public var musicPath: String?
    public var musicGainDb = -18.0
    public var duckDepthDb = -14.0, duckAttack = 0.05, duckRelease = 0.4
    public var muteMicInRamps = true
    public var speedRampsAuto = true
    public var speedRampMinIdle = 4.0, speedRampMaxSpeed = 8.0
    public var lanes: [AudioLane] = []
    enum CodingKeys: String, CodingKey {
        case outputGainDb, micClean, micMode, voiceProfile, studioAmount, micGainDb, systemGainDb, declick, declickDepthDb, targetLUFS, clickSounds, whooshes, keySounds, clickTone, sfxGainDb, musicPath
        case musicGainDb, duckDepthDb, duckAttack, duckRelease, muteMicInRamps, speedRampsAuto, speedRampMinIdle, speedRampMaxSpeed, lanes
    }
    public init() {}
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        outputGainDb = c.opt(.outputGainDb, outputGainDb)
        micClean = c.opt(.micClean, micClean); micMode = c.opt(.micMode, micMode)
        voiceProfile = c.opt(.voiceProfile, voiceProfile); studioAmount = c.opt(.studioAmount, studioAmount)
        micGainDb = c.opt(.micGainDb, micGainDb)
        systemGainDb = c.opt(.systemGainDb, systemGainDb); declick = c.opt(.declick, declick); declickDepthDb = c.opt(.declickDepthDb, declickDepthDb)
        targetLUFS = c.opt(.targetLUFS, targetLUFS); clickSounds = c.opt(.clickSounds, clickSounds); whooshes = c.opt(.whooshes, whooshes)
        keySounds = c.opt(.keySounds, keySounds); clickTone = c.opt(.clickTone, clickTone); sfxGainDb = c.opt(.sfxGainDb, sfxGainDb)
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
    public var enhancement: WebcamEnhancement = .natural
    public var detailAmount = 0.5
    public init() {}
    enum CodingKeys: String, CodingKey { case corner, size, shape, mirror, border, shadow, autoFrame, faceFill, faceZoom, backdrop, enhancement, detailAmount }
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
        let n = Int((max(trimEnd - trimStart, 0) / Self.ds).rounded(.up))
        var o = [Double](repeating: 0, count: n + 1)
        let rs = ramps.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        let cs = cuts.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
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
        let f = (s - trimStart) / Self.ds
        guard f > 0 else { return 0 }
        let i = Int(f)
        if i >= out.count - 1 { return out.last ?? 0 }
        return out[i] + (out[i + 1] - out[i]) * (f - Double(i))
    }
    public func source(atOutput t: Double) -> Double {
        guard out.count > 1 else { return trimStart }
        if t < 0 { return trimStart }
        if t >= out[out.count - 1] { return trimStart + Double(out.count - 1) * Self.ds }
        var lo = 0, hi = out.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if out[mid] <= t { lo = mid } else { hi = mid } }
        let f = (t - out[lo]) / (out[lo + 1] - out[lo])
        return trimStart + (Double(lo) + f) * Self.ds
    }
    public func speed(atOutput t: Double) -> Double { (source(atOutput: t + 0.01) - source(atOutput: t)) / 0.01 }
}

public struct Timeline: Sendable, Codable, Equatable {
    public var schemaVersion = 2
    public var timeMap: TimeMap
    public var zoom: [ZoomSegment] = []
    public var style = Style()
    public var cursor = CursorStyle()
    public var camera = CameraParams()
    public var audio = AudioPlan()
    public var webcam: WebcamLayout?
    public var overlays = Overlays()
    public var layouts: [LayoutSegment] = []
    public var layoutSettings = LayoutSet()
    public var captions = CaptionPlan()
    public var derived: DerivedTracks?
    enum CodingKeys: String, CodingKey {
        case schemaVersion, timeMap, zoom, style, cursor, camera, audio, webcam, overlays, layouts, layoutSettings, captions
    }
    public init(duration: Double) { timeMap = TimeMap(sourceDuration: duration) }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        timeMap = try c.decode(TimeMap.self, forKey: .timeMap)
        let version = c.opt(.schemaVersion, 1)
        schemaVersion = 2
        zoom = c.opt(.zoom, zoom)
        if version < 2 { for i in zoom.indices { zoom[i].start = timeMap.source(atOutput: zoom[i].start); zoom[i].end = timeMap.source(atOutput: zoom[i].end) } }
         style = c.opt(.style, style); cursor = c.opt(.cursor, cursor); camera = c.opt(.camera, camera)
        audio = c.opt(.audio, audio); webcam = try? c.decodeIfPresent(WebcamLayout.self, forKey: .webcam)
        overlays = c.opt(.overlays, overlays); layouts = c.opt(.layouts, layouts); layoutSettings = c.opt(.layoutSettings, layoutSettings)
        captions = c.opt(.captions, captions)
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
public struct ProjectMeta: Codable, Sendable {
    public var name: String
    public var created = Date()
    public var analysisSalt: UInt64
    public var source: SourceInfo
    public var clock: RecordingClock
    public var mic: TrackMeta?, system: TrackMeta?, webcam: TrackMeta?
    public var droppedFrames = 0
    enum CodingKeys: String, CodingKey { case name, created, analysisSalt, source, clock, mic, system, webcam, droppedFrames }
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
        droppedFrames = (try? c.decode(Int.self, forKey: .droppedFrames)) ?? 0
    }
}
public struct ProjectFile: Codable, Sendable {
    public var meta: ProjectMeta
    public var timeline: Timeline
    public init(meta: ProjectMeta, timeline: Timeline) { self.meta = meta; self.timeline = timeline }
}
public struct AXFrame: Codable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
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

    public func save(_ file: ProjectFile) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(file).write(to: projectURL, options: .atomic)
    }
    public func load() throws -> ProjectFile {
        try JSONDecoder().decode(ProjectFile.self, from: Data(contentsOf: projectURL))
    }
    /// events.bin stores absolute host seconds (crash-safe, append-only). Rebased here.
    public func events(origin: Double) throws -> [InputEvent] {
        var ev = EventCodec.decode(try Data(contentsOf: eventsURL))
        for i in ev.indices { ev[i].t -= origin }
        return ev.filter { $0.t >= 0 }.sorted { $0.t < $1.t }
    }
}
