import Foundation
import LumenCore

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
    public var yaw: [Float], pitch: [Float]             // degrees
    public init(count: Int) {
        nx = .init(repeating: 0.5, count: count); ny = nx; lz = .init(repeating: 0, count: count); vx = lz; vy = lz; vz = lz; yaw = lz; pitch = lz
    }
}
public struct ClickFX: Sendable, Equatable {
    public var t: Double; public var x: Float; public var y: Float
    public init(t: Double, x: Float, y: Float) { self.t = t; self.x = x; self.y = y }
}
public struct SFXCue: Sendable, Equatable {
    public enum Kind: Sendable { case click, whooshIn, whooshOut, key }
    public var t: Double; public var kind: Kind; public var gainDb: Double
    public init(t: Double, kind: Kind, gainDb: Double) { self.t = t; self.kind = kind; self.gainDb = gainDb }
}

/// Canvas-normalized layout (top-left origin). 12 floats packed so one spring drives all of them.
/// [0-3] screen rect, [4] screen opacity, [5-8] camera rect, [9] camera corner radius (fraction of min side, 0.5 = circle),
/// [10] camera opacity, [11] cutout blend (0 = framed video, 1 = person cutout).
public struct ResolvedLayout: Sendable, Equatable {
    public var v: SIMD16<Float>
    public init(v: SIMD16<Float> = .zero) { self.v = v }
    public static let full: ResolvedLayout = {
        var r = ResolvedLayout(); r.screenRect = [0, 0, 1, 1]; r.screenOpacity = 1; r.cameraRect = [0.72, 0.68, 0.24, 0.27]; return r
    }()
    public var screenRect: SIMD4<Float> {
        get { SIMD4(v[0], v[1], v[2], v[3]) }
        set { v[0] = newValue[0]; v[1] = newValue[1]; v[2] = newValue[2]; v[3] = newValue[3] }
    }
    public var screenOpacity: Float { get { v[4] } set { v[4] = newValue } }
    public var cameraRect: SIMD4<Float> {
        get { SIMD4(v[5], v[6], v[7], v[8]) }
        set { v[5] = newValue[0]; v[6] = newValue[1]; v[7] = newValue[2]; v[8] = newValue[3] }
    }
    public var cameraRadius: Float { get { v[9] } set { v[9] = newValue } }
    public var cameraOpacity: Float { get { v[10] } set { v[10] = newValue } }
    public var cutoutBlend: Float { get { v[11] } set { v[11] = newValue } }
}
public struct LayoutSpan: Sendable, Equatable {
    public var start: Double, end: Double, kind: LayoutKind
    public init(start: Double, end: Double, kind: LayoutKind) { self.start = start; self.end = end; self.kind = kind }
}
public struct LayoutTrack: Sendable, Equatable {
    public var rate: Double
    public var samples: [ResolvedLayout]
    public var spans: [LayoutSpan]                    // OUTPUT seconds
    public var fallback: LayoutKind
    public init(rate: Double = 120, samples: [ResolvedLayout] = [], spans: [LayoutSpan] = [], fallback: LayoutKind = .screenOnly) {
        self.rate = rate; self.samples = samples; self.spans = spans; self.fallback = fallback
    }
    public func kind(at t: Double) -> LayoutKind {
        for s in spans where t >= s.start && t < s.end { return s.kind }
        return fallback
    }
    public func sample(at t: Double) -> ResolvedLayout {
        guard samples.count >= 2 else { return samples.first ?? .full }
        let f = max(t, 0) * rate, i = min(max(Int(f), 0), samples.count - 2)
        let u = Float(min(max(f - Double(i), 0), 1))
        return ResolvedLayout(v: samples[i].v + (samples[i + 1].v - samples[i].v) * u)
    }
}
/// Webcam anchor corner + visibility over output time (60 Hz). Empty = no webcam.
public struct PlacementTrack: Sendable, Equatable {
    public var rate: Double
    public var corner: [UInt8]                        // index into WebcamLayout.Corner.allCases
    public var visible: [Float]
    public init(rate: Double = 60, corner: [UInt8] = [], visible: [Float] = []) { self.rate = rate; self.corner = corner; self.visible = visible }
    public func corner(at t: Double) -> WebcamLayout.Corner? {
        guard !corner.isEmpty else { return nil }
        let i = min(max(Int(t * rate), 0), corner.count - 1)
        let all = WebcamLayout.Corner.allCases
        return all[min(Int(corner[i]), all.count - 1)]
    }
    public func visibility(at t: Double) -> Float {
        guard !visible.isEmpty else { return 1 }
        return visible[min(max(Int(t * rate), 0), visible.count - 1)]
    }
}

public struct CaptionWord: Sendable, Equatable {
    public var text: String
    public var start: Double, end: Double             // OUTPUT seconds
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}
public struct CaptionChunk: Sendable, Equatable {
    public var start: Double, end: Double             // OUTPUT seconds
    public var lines: [[CaptionWord]]
    public var y: Double                              // canvas-normalized center of the block
    public init(start: Double, end: Double, lines: [[CaptionWord]], y: Double) { self.start = start; self.end = end; self.lines = lines; self.y = y }
    public var text: String { lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n") }
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
    public var layout: LayoutTrack
    public var placement: PlacementTrack
    public var captions: [CaptionChunk]
    public var autoMasks: [Mask]
    public init(revision: Int, sourceSize: SIMD2<Double>, outputDuration: Double, cursor: CursorTrack, camera: CameraTrack,
                clicks: [ClickFX], cues: [SFXCue], duck: [Float], face: [SIMD3<Float>], webcamAspect: Float,
                layout: LayoutTrack = LayoutTrack(), placement: PlacementTrack = PlacementTrack(), captions: [CaptionChunk] = [], autoMasks: [Mask] = []) {
        self.revision = revision; self.sourceSize = sourceSize; self.outputDuration = outputDuration; self.cursor = cursor
        self.camera = camera; self.clicks = clicks; self.cues = cues; self.duck = duck; self.face = face; self.webcamAspect = webcamAspect
        self.layout = layout; self.placement = placement; self.captions = captions; self.autoMasks = autoMasks
    }
    public static func == (a: Self, b: Self) -> Bool { a.revision == b.revision }
}
