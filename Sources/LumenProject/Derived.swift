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
    public var rate: Double
    public var nx: [Float], ny: [Float], lz: [Float]
    public var vx: [Float], vy: [Float], vz: [Float]
    public var ax: [Float], ay: [Float], az: [Float]
    public var yaw: [Float], pitch: [Float]             // degrees
    public init(count: Int, rate: Double = gridRate) {
        self.rate = rate
        nx = .init(repeating: 0.5, count: count); ny = nx; lz = .init(repeating: 0, count: count)
        vx = .init(repeating: 0, count: count); vy = vx; vz = vx
        ax = vx; ay = vx; az = vx; yaw = vx; pitch = vx
    }
}
public struct ClickFX: Sendable, Equatable {
    public var t: Double; public var x: Float; public var y: Float
    public init(t: Double, x: Float, y: Float) { self.t = t; self.x = x; self.y = y }
}
public struct SFXCue: Sendable, Equatable {
    public enum Kind: Sendable { case click, whooshIn, whooshOut, key, keyUp }
    public var t: Double; public var kind: Kind; public var gainDb: Double; public var keyCode: UInt16
    public var isKeyRelease: Bool
    public init(t: Double, kind: Kind, gainDb: Double, keyCode: UInt16 = 0, isKeyRelease: Bool = false) {
        self.t = t; self.kind = kind; self.gainDb = gainDb; self.keyCode = keyCode; self.isKeyRelease = isKeyRelease
    }
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

/// A time-varying source-pixel crop. Keyframes are in OUTPUT seconds and
/// interpolated with a rest-to-rest quintic per channel, so arrival is exact
/// and there is no velocity step at a keyframe.
public struct CropTrack: Sendable, Equatable {
    public struct Keyframe: Sendable, Equatable {
        public var t: Double
        public var rect: CGRect
        public init(t: Double, rect: CGRect) { self.t = t; self.rect = rect }
    }
    public var rate: Double
    public var keys: [Keyframe]
    public init(rate: Double = 480, keys: [Keyframe] = []) {
        self.rate = rate
        self.keys = keys.sorted { $0.t < $1.t }
    }

    public func evaluate(at t: Double) -> CGRect {
        guard let first = keys.first else { return .zero }
        if t <= first.t { return first.rect }
        guard let last = keys.last else { return first.rect }
        if t >= last.t { return last.rect }
        var lo = 0, hi = keys.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if keys[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = keys[lo], b = keys[hi]
        let T = max(b.t - a.t, 1e-4)
        func axis(_ x0: Double, _ x1: Double) -> Double {
            QuinticMove(t0: a.t, T: T, x0: x0, v0: 0, a0: 0, x1: x1).sample(t).x
        }
        return CGRect(x: axis(Double(a.rect.minX), Double(b.rect.minX)),
                      y: axis(Double(a.rect.minY), Double(b.rect.minY)),
                      width: axis(Double(a.rect.width), Double(b.rect.width)),
                      height: axis(Double(a.rect.height), Double(b.rect.height)))
    }
}

/// Dense 480 Hz viewport crop in SOURCE pixels, sampled by `FrameState`.
/// Pure value type; owned by the derived timeline and safe to share across tasks.
public struct DenseCropTrack: Sendable, Equatable {
    public var hz: Double
    public var rects: [SIMD4<Float>]
    public init(hz: Double = 480, rects: [SIMD4<Float>] = []) {
        self.hz = hz; self.rects = rects
    }
    public func rect(at t: Double) -> PxRect {
        guard !rects.isEmpty else { return PxRect(x: 0, y: 0, w: 0, h: 0) }
        let f = min(max(t * hz, 0), Double(rects.count - 1))
        let i = Int(f), j = min(i + 1, rects.count - 1)
        let v = rects[i] + (rects[j] - rects[i]) * Float(f - Double(i))
        return PxRect(x: Double(v.x), y: Double(v.y), w: Double(v.z), h: Double(v.w))
    }
}

/// Native-symbol shortcut overlays, derived from verified physical chords.
public struct ShortcutCue: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var label: String
    public init(start: Double, end: Double, label: String) {
        self.start = start; self.end = end; self.label = label
    }
}

public struct DerivedTracks: Sendable, Equatable {
    public var revision: Int
    public var sourceSize: SIMD2<Double>
    public var outputDuration: Double
    public var cursor: CursorTrack
    public var camera: CameraTrack
    public var clicks: [ClickFX]
    public var cues: [SFXCue]
    public var shortcuts: [ShortcutCue]
    public var duck: [Float]            // 100 Hz, output time
    public var face: [SIMD3<Float>]     // 30 Hz (cx, cy, height), normalized to webcam image
    public var webcamAspect: Float
    public var layout: LayoutTrack
    public var placement: PlacementTrack
    public var captions: [CaptionChunk]
    /// Command-key pills in OUTPUT time, derived from recorded key events.
    public var shortcutPills: [ShortcutDisplay] = []
    public var autoMasks: [Mask]
    public var personMask: PersonMaskInfo?
    /// Empty keys mean "no smart crop"; FrameState.cropRect is then .zero.
    public var crop: CropTrack
    /// F1: dense browser-content crop track (source px, 480 Hz).
    public var viewportCrop: DenseCropTrack
    public init(revision: Int, sourceSize: SIMD2<Double>, outputDuration: Double, cursor: CursorTrack, camera: CameraTrack,
                clicks: [ClickFX], cues: [SFXCue], duck: [Float], face: [SIMD3<Float>], webcamAspect: Float,
                layout: LayoutTrack = LayoutTrack(), placement: PlacementTrack = PlacementTrack(), captions: [CaptionChunk] = [],
                autoMasks: [Mask] = [], personMask: PersonMaskInfo? = nil, crop: CropTrack = CropTrack(),
                viewportCrop: DenseCropTrack = DenseCropTrack(), shortcutPills: [ShortcutDisplay] = []) {
        self.revision = revision; self.sourceSize = sourceSize; self.outputDuration = outputDuration; self.cursor = cursor
        self.camera = camera; self.clicks = clicks; self.cues = cues; self.duck = duck; self.face = face; self.webcamAspect = webcamAspect
        self.layout = layout; self.placement = placement; self.captions = captions; self.autoMasks = autoMasks; self.personMask = personMask
        self.shortcutPills = shortcutPills
        self.crop = crop
        self.viewportCrop = viewportCrop
        self.shortcuts = shortcuts
    }
    public static func == (a: Self, b: Self) -> Bool { a.revision == b.revision }
}
