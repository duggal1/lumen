import Foundation
import LumenCore

public enum Origin: String, Codable, Sendable { case auto, manual }

public struct RGBA: Codable, Equatable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float
    public init(_ hex: UInt32, a: Float = 1) {
        r = Float((hex >> 16) & 255) / 255; g = Float((hex >> 8) & 255) / 255; b = Float(hex & 255) / 255; self.a = a
    }
    public var simd: SIMD4<Float> { [r, g, b, a] }
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

public enum BackgroundKind: String, Codable, CaseIterable, Sendable { case gradient, mesh, solid }
public enum CanvasAspect: String, Codable, CaseIterable, Sendable {
    case r16x9, r16x10, r1x1, r4x5, r9x16
    public var ratio: Double { switch self { case .r16x9: 16.0 / 9; case .r16x10: 1.6; case .r1x1: 1; case .r4x5: 0.8; case .r9x16: 9.0 / 16 } }
    public var title: String { switch self { case .r16x9: "16:9"; case .r16x10: "16:10"; case .r1x1: "1:1"; case .r4x5: "4:5"; case .r9x16: "9:16" } }
}

public struct Style: Codable, Equatable, Sendable {
    public var background: BackgroundKind = .gradient
    public var colors: [RGBA] = GradientPresets.all[0].1
    public var gradientAngle: Double = 35
    public var padding: Double = 0.06
    public var cornerRadius: Double = 14
    public var shadow: Double = 0.45
    public var innerBorder = true
    public var canvas: CanvasAspect = .r16x9
    public init() {}
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
    public init() {}
}

public enum ZoomPreset: String, Codable, CaseIterable, Sendable {
    case subtle, balanced, dramatic, fixed
    public var maxScale: Double { switch self { case .subtle: 1.6; case .balanced: 2.2; case .dramatic: 3.0; case .fixed: 2.0 } }
}
public struct CameraParams: Codable, Equatable, Sendable {
    public var preset: ZoomPreset = .balanced
    public var autoZoom = true
    public var maxScale = 2.2
    public var minTrigger = 1.25
    public var leadIn = 0.65, tail = 0.7, mergeGap = 2.5, panThroughGap = 1.5, minHold = 1.0
    public var omegaPan = 7.0, omegaZoom = 6.0, lookahead = 0.20, deadZone = 0.28
    public var shutter = 0.5
    public var maxSamples = 8
    public init() {}
}

public struct AudioPlan: Codable, Equatable, Sendable {
    public var micClean = true
    public var targetLUFS = -14.0
    public var clickSounds = true, whooshes = true, keySounds = false
    public var sfxGainDb = -20.0
    public var musicPath: String?
    public var musicGainDb = -18.0
    public var duckDepthDb = -14.0, duckAttack = 0.05, duckRelease = 0.4
    public var muteMicInRamps = true
    public var speedRampsAuto = true
    public var speedRampMinIdle = 2.0, speedRampMaxSpeed = 8.0
    public init() {}
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
    public init() {}
    enum CodingKeys: String, CodingKey { case corner, size, shape, mirror, border, shadow, autoFrame, faceFill, faceZoom }
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
    }
}

public enum Focus: Codable, Equatable, Sendable {
    case follow
    case fixed(x: Double, y: Double)                      // normalized
    case element(x: Double, y: Double, w: Double, h: Double)
}
public struct ZoomSegment: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var start: Double, end: Double                 // OUTPUT seconds
    public var scale: Double
    public var focus: Focus
    public var origin: Origin
    public init(start: Double, end: Double, scale: Double, focus: Focus, origin: Origin) {
        self.start = start; self.end = end; self.scale = scale; self.focus = focus; self.origin = origin
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

/// Output<->source time map. Value type; table is rebuilt on mutation and never persisted.
public struct TimeMap: Codable, Equatable, Sendable {
    public var sourceDuration: Double { didSet { rebuild() } }
    public var trimStart: Double { didSet { rebuild() } }
    public var trimEnd: Double { didSet { rebuild() } }
    public var ramps: [SpeedRamp] { didSet { rebuild() } }
    private var out: [Double] = []
    private static let ds = 1.0 / 240
    enum CodingKeys: String, CodingKey { case sourceDuration, trimStart, trimEnd, ramps }

    public init(sourceDuration: Double = 0, trimStart: Double = 0, trimEnd: Double? = nil, ramps: [SpeedRamp] = []) {
        self.sourceDuration = sourceDuration; self.trimStart = trimStart; self.trimEnd = trimEnd ?? sourceDuration; self.ramps = ramps
        rebuild()
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        sourceDuration = try c.decode(Double.self, forKey: .sourceDuration); trimStart = try c.decode(Double.self, forKey: .trimStart)
        trimEnd = try c.decode(Double.self, forKey: .trimEnd); ramps = try c.decode([SpeedRamp].self, forKey: .ramps)
        rebuild()
    }
    public static func == (a: TimeMap, b: TimeMap) -> Bool {
        a.sourceDuration == b.sourceDuration && a.trimStart == b.trimStart && a.trimEnd == b.trimEnd && a.ramps == b.ramps
    }
    private mutating func rebuild() {
        let n = Int((max(trimEnd - trimStart, 0) / Self.ds).rounded(.up))
        var o = [Double](repeating: 0, count: n + 1)
        let rs = ramps.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var j = 0
        for i in 0..<n {
            let s = trimStart + (Double(i) + 0.5) * Self.ds
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
    public func output(atSource s: Double) -> Double {
        let f = (s - trimStart) / Self.ds
        guard f > 0 else { return 0 }
        let i = Int(f)
        if i >= out.count - 1 { return out.last ?? 0 }
        return out[i] + (out[i + 1] - out[i]) * (f - Double(i))
    }
    public func source(atOutput t: Double) -> Double {
        guard out.count > 1 else { return trimStart }
        if t <= 0 { return trimStart }
        if t >= out[out.count - 1] { return trimStart + Double(out.count - 1) * Self.ds }
        var lo = 0, hi = out.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if out[mid] <= t { lo = mid } else { hi = mid } }
        let f = (t - out[lo]) / (out[lo + 1] - out[lo])
        return trimStart + (Double(lo) + f) * Self.ds
    }
    public func speed(atOutput t: Double) -> Double { (source(atOutput: t + 0.01) - source(atOutput: t)) / 0.01 }
}

// MARK: Derived (never persisted)

public struct CursorTrack: Sendable, Equatable {
    public var x: [Float], y: [Float], opacity: [Float], press: [Float]
    public var shape: [UInt16]
    public init(count: Int) {
        x = .init(repeating: 0, count: count); y = x; opacity = .init(repeating: 1, count: count)
        press = .init(repeating: 1, count: count); shape = .init(repeating: 0, count: count)
    }
}
public struct CameraTrack: Sendable, Equatable {
    public var nx: [Float], ny: [Float], lz: [Float], vx: [Float], vy: [Float], vz: [Float]
    public init(count: Int) {
        nx = .init(repeating: 0.5, count: count); ny = nx; lz = .init(repeating: 0, count: count); vx = lz; vy = lz; vz = lz
    }
}
public struct ClickFX: Sendable, Equatable {
    public var t: Double
    public var x: Float
    public var y: Float
    public init(t: Double, x: Float, y: Float) { self.t = t; self.x = x; self.y = y }
}
public struct SFXCue: Sendable, Equatable {
    public enum Kind: Sendable { case click, whooshIn, whooshOut, key }
    public var t: Double; public var kind: Kind; public var gainDb: Double
    public init(t: Double, kind: Kind, gainDb: Double) { self.t = t; self.kind = kind; self.gainDb = gainDb }
}
public struct DerivedTracks: Sendable, Equatable {
    public var revision: Int
    public var sourceSize: SIMD2<Double>
    public var outputDuration: Double
    public var cursor: CursorTrack
    public var camera: CameraTrack
    public var clicks: [ClickFX]
    public var cues: [SFXCue]
    public var duck: [Float]            // 100 Hz, output time
    public var face: [SIMD3<Float>]     // 30 Hz (cx, cy, height), normalized to webcam image
    public var webcamAspect: Float
    public init(revision: Int, sourceSize: SIMD2<Double>, outputDuration: Double, cursor: CursorTrack,
                camera: CameraTrack, clicks: [ClickFX], cues: [SFXCue], duck: [Float], face: [SIMD3<Float>],
                webcamAspect: Float) {
        self.revision = revision
        self.sourceSize = sourceSize
        self.outputDuration = outputDuration
        self.cursor = cursor
        self.camera = camera
        self.clicks = clicks
        self.cues = cues
        self.duck = duck
        self.face = face
        self.webcamAspect = webcamAspect
    }
    public static func == (a: Self, b: Self) -> Bool { a.revision == b.revision }
}

public struct Timeline: Sendable, Codable, Equatable {
    public var schemaVersion = 1
    public var timeMap: TimeMap
    public var zoom: [ZoomSegment] = []
    public var style = Style()
    public var cursor = CursorStyle()
    public var camera = CameraParams()
    public var audio = AudioPlan()
    public var webcam: WebcamLayout?
    public var derived: DerivedTracks?
    enum CodingKeys: String, CodingKey { case schemaVersion, timeMap, zoom, style, cursor, camera, audio, webcam }
    public init(duration: Double) { timeMap = TimeMap(sourceDuration: duration) }
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
    public var source: SourceInfo
    public var clock: RecordingClock
    public var mic: TrackMeta?, system: TrackMeta?, webcam: TrackMeta?
    public var droppedFrames = 0
    public init(name: String, source: SourceInfo, clock: RecordingClock) { self.name = name; self.source = source; self.clock = clock }
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
        for sub in ["cache", "thumbs"] { try FileManager.default.createDirectory(at: u.appendingPathComponent(sub), withIntermediateDirectories: true) }
        return .init(url: u)
    }
    public var projectURL: URL { url.appendingPathComponent("project.json") }

    private func f(_ n: String) -> URL { url.appendingPathComponent(n) }
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
