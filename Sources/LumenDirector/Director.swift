import Foundation
import LumenCore
import LumenProject

public struct FaceSample: Sendable {
    public var t: Double, cx: Float, cy: Float, h: Float
    public init(t: Double, cx: Float, cy: Float, h: Float) { self.t = t; self.cx = cx; self.cy = cy; self.h = h }
}
public struct DirectorInput: Sendable {
    public var events: [InputEvent]
    public var source: SourceInfo
    public var vad: [ClosedRange<Double>]
    public var ax: [AXFrame]
    public var face: [FaceSample]
    public var webcamAspect: Float
    public init(events: [InputEvent], source: SourceInfo, vad: [ClosedRange<Double>] = [], ax: [AXFrame] = [],
                face: [FaceSample] = [], webcamAspect: Float = 16.0 / 9) {
        self.events = events; self.source = source; self.vad = vad; self.ax = ax; self.face = face; self.webcamAspect = webcamAspect
    }
}

public enum Director {
    /// Pure and deterministic: same input, same Timeline. Replaces only .auto zoom/ramps; .manual survive.
    public static func derive(_ tl: Timeline, input: DirectorInput, revision: Int) -> Timeline {
        var t = tl
        let src = input.source
        var tm = t.timeMap
        if tm.sourceDuration != src.duration && tm.trimEnd <= 0 {
            tm = TimeMap(sourceDuration: src.duration, trimStart: 0, trimEnd: src.duration, ramps: tm.ramps)
        }
        // time map first: camera runs in output time
        if t.audio.speedRampsAuto {
            tm.ramps = tm.ramps.filter { $0.origin == .manual }
                + SpeedRamps.plan(events: input.events, vad: input.vad, tm: tm, audio: t.audio, backing: src.backingScale)
        }
        t.timeMap = tm
        if t.camera.autoZoom {
            t.camera.maxScale = t.camera.preset == .fixed ? t.camera.maxScale : t.camera.preset.maxScale
            t.zoom = t.zoom.filter { $0.origin == .manual }
                + ZoomPlanner.plan(events: input.events, ax: input.ax, src: src, p: t.camera, tm: tm)
        }
        let (cursor, clicks) = CursorPipeline.run(events: input.events, st: t.cursor, tm: tm, src: src)
        let size = SIMD2(Double(src.width), Double(src.height))
        let cam = CameraSolver.solve(zoom: t.zoom, cursor: cursor, p: t.camera, src: size, outDur: tm.outputDuration)

        var cues: [SFXCue] = []
        if t.audio.clickSounds { cues += clicks.map { SFXCue(t: $0.t, kind: .click, gainDb: 0) } }
        if t.audio.keySounds {
            cues += input.events.filter { $0.kind == .keyDown }.map { SFXCue(t: tm.output(atSource: $0.t), kind: .key, gainDb: -6) }
        }
        if t.audio.whooshes {
            for z in t.zoom {
                let g = min(-12 + 6 * (z.scale - 1), 0)
                cues.append(SFXCue(t: z.start, kind: .whooshIn, gainDb: g)); cues.append(SFXCue(t: z.end, kind: .whooshOut, gainDb: g))
            }
        }
        cues.sort { $0.t < $1.t }

        // duck envelope @100 Hz from voice activity
        let dn = Int(tm.outputDuration * 100) + 2
        var voice = [Bool](repeating: false, count: dn)
        for r in input.vad {
            let a = max(Int(tm.output(atSource: r.lowerBound) * 100), 0), b = min(Int(tm.output(atSource: r.upperBound) * 100), dn - 1)
            if b >= a { for i in a...b { voice[i] = true } }
        }
        var duck = [Float](repeating: 1, count: dn)
        var g = 1.0
        let lowG = pow(10, t.audio.duckDepthDb / 20)
        for i in 0..<dn {
            let tgt = voice[i] ? lowG : 1.0
            let tc = tgt < g ? t.audio.duckAttack : t.audio.duckRelease
            g += (tgt - g) * (1 - exp(-0.01 / tc)); duck[i] = Float(g)
        }
        t.derived = DerivedTracks(revision: revision, sourceSize: size, outputDuration: tm.outputDuration, cursor: cursor, camera: cam,
                                  clicks: clicks, cues: cues, duck: duck, face: WebcamFraming.solve(input.face, tm: tm, camera: cam, layout: t.webcam),
                                  webcamAspect: input.webcamAspect)
        return t
    }
}

// MARK: Evaluation

public struct CursorSample: Sendable {
    public var position: SIMD2<Float>, velocity: SIMD2<Float>
    public var opacity: Float, press: Float
    public var shape: UInt16
}
public struct ClickRing: Sendable { public var position: SIMD2<Float>; public var progress: Float }
public struct FrameState: Sendable {
    public var cameraCenter: SIMD2<Float>     // source px
    public var cameraScale: Float
    public var cursor: CursorSample
    public var clickFX: [ClickRing]
    public var webcamCrop: SIMD4<Float>       // uv x, y, w, h
    public var sourceTime: Double
}

@inline(__always) private func cr(_ a: [Float], _ f: Double) -> Float {
    let i = Int(f.rounded(.down)), u = Float(f - Double(i)), n = a.count
    func g(_ k: Int) -> Float { a[min(max(k, 0), n - 1)] }
    let p0 = g(i - 1), p1 = g(i), p2 = g(i + 1), p3 = g(i + 2)
    return p1 + 0.5 * u * (p2 - p0 + u * (2 * p0 - 5 * p1 + 4 * p2 - p3 + u * (3 * (p1 - p2) + p3 - p0)))
}
@inline(__always) private func hm(_ p: [Float], _ v: [Float], _ f: Double) -> Float {
    let i = min(max(Int(f), 0), p.count - 2), s = Float(f - Double(i)), h = Float(1 / gridRate)
    let s2 = s * s, s3 = s2 * s
    return (2 * s3 - 3 * s2 + 1) * p[i] + (s3 - 2 * s2 + s) * h * v[i] + (-2 * s3 + 3 * s2) * p[i + 1] + (s3 - s2) * h * v[i + 1]
}
private func cf(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

extension Timeline {
    /// Pure function of (self, t). Microseconds. Safe to call from any thread.
    public func evaluate(at t0: Double) -> FrameState {
        guard let d = derived else {
            return FrameState(cameraCenter: .zero, cameraScale: 1,
                              cursor: CursorSample(position: .zero, velocity: .zero, opacity: 0, press: 1, shape: 0),
                              clickFX: [], webcamCrop: [0, 0, 1, 1], sourceTime: 0)
        }
        let t = clamp(t0, 0, d.outputDuration), f = t * gridRate
        let c = d.camera, u = d.cursor
        let cam = SIMD2<Float>(hm(c.nx, c.vx, f) * Float(d.sourceSize.x), hm(c.ny, c.vy, f) * Float(d.sourceSize.y))
        let scale = exp(hm(c.lz, c.vz, f))
        let pos = SIMD2<Float>(cr(u.x, f), cr(u.y, f))
        let vel = SIMD2<Float>(cr(u.x, f + 1) - cr(u.x, f - 1), cr(u.y, f + 1) - cr(u.y, f - 1)) * Float(gridRate / 2)
        let cs = CursorSample(position: pos, velocity: vel, opacity: cf(cr(u.opacity, f), 0, 1), press: cr(u.press, f),
                              shape: u.shape[min(Int(f.rounded()), u.shape.count - 1)])
        var rings: [ClickRing] = []
        if let dur = cursor.clickRing, !d.clicks.isEmpty {
            var lo = 0, hi = d.clicks.count
            while lo < hi { let m = (lo + hi) / 2; if d.clicks[m].t <= t - dur { lo = m + 1 } else { hi = m } }
            var i = lo
            while i < d.clicks.count, d.clicks[i].t <= t {
                rings.append(ClickRing(position: SIMD2(d.clicks[i].x, d.clicks[i].y), progress: Float((t - d.clicks[i].t) / dur)))
                i += 1
            }
        }
        // webcam crop: face-aware or centered square
        let ar = max(d.webcamAspect, 0.1)
        var ch: Float = 1, cx: Float = 0.5, cy: Float = 0.5
        if !d.face.isEmpty {
            let fp = t * faceGridRate, i0 = min(Int(fp), d.face.count - 1), i1 = min(i0 + 1, d.face.count - 1)
            let fc = d.face[i0] + (d.face[i1] - d.face[i0]) * Float(fp - Double(i0))
            cx = fc.x; cy = fc.y; ch = cf(fc.z, 0.25, 1)
        }
        let cw = min(ch / ar, 1)
        let crop = SIMD4<Float>(cf(cx - cw / 2, 0, 1 - cw), cf(cy - ch / 2, 0, 1 - ch), cw, ch)
        return FrameState(cameraCenter: cam, cameraScale: scale, cursor: cs, clickFX: rings, webcamCrop: crop,
                          sourceTime: timeMap.source(atOutput: t))
    }
}