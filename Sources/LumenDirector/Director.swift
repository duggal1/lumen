import Foundation
import LumenCore
import LumenProject

public struct DirectorInput: Sendable {
    public var events: [InputEvent]
    public var source: SourceInfo
    public var vad: [ClosedRange<Double>]
    public var ax: [AXFrame]
    public var face: [FaceSample]
    public var webcamAspect: Float
    public var activity: [ActivityPoint]
    public var transcript: Transcript?
    public var ocr: [OCRDetection]
    public var personMask: PersonMaskInfo?
    public var typing: [TypingTrace]
    public init(events: [InputEvent], source: SourceInfo, vad: [ClosedRange<Double>] = [], ax: [AXFrame] = [],
                face: [FaceSample] = [], webcamAspect: Float = 16.0 / 9, activity: [ActivityPoint] = [],
                transcript: Transcript? = nil, ocr: [OCRDetection] = [], personMask: PersonMaskInfo? = nil,
                typing: [TypingTrace] = []) {
        self.events = events; self.source = source; self.vad = vad; self.ax = ax; self.face = face
        self.webcamAspect = webcamAspect; self.activity = activity; self.transcript = transcript; self.ocr = ocr; self.personMask = personMask; self.typing = typing
    }
}

/// Reusable stage cache for interactive replans. Only stages that do not
/// depend on the zoom/camera parameters are retained; everything else is
/// still recomputed, so the result is identical to a cold derive.
public struct DeriveCache: Sendable {
    struct CursorKey: Equatable {
        var style: CursorStyle
        var taps: [TapIndicator]
        var timeMap: [Double]
    }
    var cursorKey: CursorKey?
    var cursor: (CursorTrack, [ClickFX])?

    /// SMOOTHNESS: the zoom planner only reads the camera parameters, the
    /// source-time map, the manual segments and the recorded input. A
    /// style-only edit (padding, colours) must not re-run it.
    struct PlanKey: Equatable {
        var camera: CameraParams
        var signature: [Double]
        var digest: UInt64
        var manual: [ZoomSegment]
        var source: SIMD3<Double>
    }
    var planKey: PlanKey?
    var plan: ZoomPlanner.ZoomPlan?

    /// Same idea for the speed-ramp planner.
    struct RampKey: Equatable {
        var audio: AudioPlan
        var signature: [Double]
        var vad: [ClosedRange<Double>]
        var digest: UInt64
        var backing: Double
    }
    var rampKey: RampKey?
    var ramps: [SpeedRamp]?

    public init() {}
}

extension TimeMap {
    /// The part of the time map the planners read: trim and cuts. The auto
    /// ramps are excluded — they are an output of the derive, not an input.
    var sourceSignature: [Double] {
        [trimStart, trimEnd] + cuts.flatMap { [$0.start, $0.end] }
    }
}

extension TimeMap {
    /// Auto speed-ramp ids are regenerated per replan, so `==` on the ramp
    /// array never matches a cached stage. Key on the values that matter.
    var signature: [Double] {
        [trimStart, trimEnd] + cuts.flatMap { [$0.start, $0.end] }
            + ramps.flatMap { [$0.start, $0.end, $0.speed] }
    }
}

public enum Director {
    /// Run only the event-based zoom planner at recording stop, without
    /// rendering, speech analysis, waveform work or audio mixing.
    public static func planRecordingZoom(events: [InputEvent], ax: [AXFrame],
                                         source: SourceInfo, timeline: Timeline) -> [ZoomSegment] {
        guard timeline.camera.autoZoom else { return timeline.zoom }
        let manual = timeline.zoom.filter { $0.origin == .manual }
        let avoid = manual.map { min($0.start, $0.end)...max($0.start, $0.end) }
        return (manual + ZoomPlanner.planSegments(events: events, ax: ax, typing: [], activity: [],
                                                   src: source, p: timeline.camera, tm: timeline.timeMap,
                                                   avoid: avoid)).sorted { $0.start < $1.start }
    }

    /// Pure and deterministic: same input, same Timeline. Replaces only .auto zoom/ramps; .manual survive.
    public static func derive(_ tl: Timeline, input: DirectorInput, revision: Int) -> Timeline {
        var cache = DeriveCache()
        return derive(tl, input: input, revision: revision, cache: &cache)
    }

    /// Cache-aware overload used by the interactive editor. The returned
    /// Timeline is byte-for-byte identical to the uncached call.
    public static func derive(_ tl: Timeline, input: DirectorInput, revision: Int, cache: inout DeriveCache) -> Timeline {
        // SMOOTHNESS: this path never cancels, so the result is identical to
        // the cancellable one. (`?? tl` is unreachable; it avoids a force
        // unwrap on a path that must never trap.)
        deriveCancellable(tl, input: input, revision: revision, cache: &cache, cancelled: { false }) ?? tl
    }

    /// SMOOTHNESS: a cancelled derive must be able to abandon its work. The
    /// stages are checked between each other, and the camera solve checks
    /// every few thousand samples, so a slider drag no longer queues behind
    /// a full 1440 Hz solve that nobody is waiting for.
    public static func deriveCancellable(_ tl: Timeline, input: DirectorInput, revision: Int,
                                         cache: inout DeriveCache, cancelled: () -> Bool) -> Timeline? {
        var t = tl
        let src = input.source
        var followPaths: [UUID: [(t: Double, c: SIMD2<Double>)]] = [:]
        if cancelled() { return nil }
        let digest = inputDigest(input)
        var tm = t.timeMap
        if tm.sourceDuration != src.duration && tm.trimEnd <= 0 {
            tm = TimeMap(sourceDuration: src.duration, trimStart: 0, trimEnd: src.duration, ramps: tm.ramps, cuts: tm.cuts)
        }
        // time map first: camera runs in output time
        if t.audio.speedRampsAuto {
            let manualRamps = tm.ramps.filter { $0.origin == .manual }
            let rkey = DeriveCache.RampKey(audio: t.audio, signature: tm.sourceSignature, vad: input.vad,
                                           digest: digest, backing: src.backingScale)
            let planned: [SpeedRamp]
            if cache.rampKey == rkey, let cached = cache.ramps {
                planned = cached
            } else {
                planned = SpeedRamps.plan(events: input.events, vad: input.vad, tm: tm, audio: t.audio, backing: src.backingScale, activity: input.activity)
                cache.rampKey = rkey; cache.ramps = planned
            }
            // AGENT: automatic ramps removed by the user must stay removed after every derive.
            let suppressed = Set(t.suppressedAuto)
            tm.ramps = manualRamps + planned.filter { !suppressed.contains($0.id.uuidString) }
        }
        if cancelled() { return nil }
        t.timeMap = tm
        if t.camera.autoZoom {
            let manual = t.zoom.filter { $0.origin == .manual }
            let avoid = manual.map { min($0.start, $0.end)...max($0.start, $0.end) }
            let pkey = DeriveCache.PlanKey(camera: t.camera, signature: tm.sourceSignature, digest: digest,
                                           manual: manual, source: SIMD3(Double(src.width), Double(src.height), src.backingScale))
            let planned: ZoomPlanner.ZoomPlan
            if cache.planKey == pkey, let cached = cache.plan {
                planned = cached
            } else {
                planned = ZoomPlanner.plan(events: input.events, ax: input.ax, typing: input.typing, activity: input.activity, src: src, p: t.camera,
                                           tm: tm, avoid: avoid)
                cache.planKey = pkey; cache.plan = planned
            }
            // AGENT: applying suppression here covers normal derives as well as explicit replans.
            let suppressed = Set(t.suppressedAuto)
            t.zoom = (manual + planned.segments.filter { !suppressed.contains($0.id.uuidString) }).sorted { $0.start < $1.start }
            // SMOOTHNESS: the caret paths travel with the plan and become the
            // camera's continuous follow targets.
            followPaths = planned.follow.mapValues { path in
                path.map { (tm.output(atSource: $0.t), $0.p) }
            }
        }
        if cancelled() { return nil }
        let key = DeriveCache.CursorKey(style: t.cursor, taps: t.overlays.taps, timeMap: tm.signature)
        let cursor: CursorTrack, clicks: [ClickFX]
        if cache.cursorKey == key, let cached = cache.cursor {
            (cursor, clicks) = cached
        } else {
            let result = CursorPipeline.run(events: input.events, taps: t.overlays.taps, st: t.cursor, tm: tm, src: src)
            cache.cursorKey = key; cache.cursor = result
            (cursor, clicks) = result
        }
        if cancelled() { return nil }
        let size = SIMD2(Double(src.width), Double(src.height))
        guard let cam = CameraSolver.solve(zoom: t.zoom, tm: tm, cursor: cursor, p: t.camera, src: size,
                                           outDur: tm.outputDuration, loop: t.cursor.loop,
                                           follow: followPaths,
                                           cancelled: cancelled) else { return nil }
        let placement = WebcamPlacement.solve(t, tm: tm, cam: cam, cursor: cursor, src: size, vad: input.vad,
                                             outDur: tm.outputDuration, clicks: clicks)
        let layoutSpans = LayoutSolver.spans(t, tm, hasWebcam: t.webcam != nil)
        let layout = LayoutSolver.solve(t, spans: layoutSpans.spans, fallback: layoutSpans.fallback, src: size,
                                        webcamAspect: Double(input.webcamAspect), placement: placement, outDur: tm.outputDuration)
        let autoMasks = MaskTracks.build(input.ocr, plan: t.overlays.privacy, src: src,
                                        contexts: PrivacyContextTrack.from(ax: input.ax))
            + MaskTracks.secureFields(events: input.events, ax: input.ax, plan: t.overlays.privacy, src: src,
                                      ocr: input.ocr)
        let captions = CaptionPlanner.plan(words: input.transcript?.words ?? [], tm: tm, p: t.captions, aspect: t.style.aspectRatio,
                                           kindAt: layout.kind(at:), cornerAt: placement.corner(at:))
        if cancelled() { return nil }

        var cues: [SFXCue] = []
        if t.audio.soundEffectsEnabled {
            if t.audio.clickSounds {
                cues += clicks.map { SFXCue(t: $0.t, kind: .click, gainDb: t.audio.clickGainDb) }
            }
            if t.audio.keySounds {
                cues += input.events.filter { $0.kind == .keyDown && !tm.isCut($0.t) }
                    .map { SFXCue(t: tm.output(atSource: $0.t), kind: .key, gainDb: 0, keyCode: $0.keyCode) }
            }
        }
        if t.audio.soundEffectsEnabled && t.audio.whooshes {
            // SMOOTHNESS: one whoosh pair per SCENE, not per segment. A
            // retarget produces abutting segments, and a whoosh-out right on
            // top of a whoosh-in reads as a stutter in the middle of one
            // continuous zoom.
            var scenes: [(start: Double, end: Double, scale: Double)] = []
            for z in t.zoom.sorted(by: { $0.start < $1.start }) {
                if let last = scenes.last, z.start - last.end <= 0.05 {
                    scenes[scenes.count - 1].end = max(last.end, z.end)
                    scenes[scenes.count - 1].scale = max(last.scale, z.scale)
                } else {
                    scenes.append((z.start, z.end, z.scale))
                }
            }
            for s in scenes {
                let a = tm.output(atSource: s.start), b = tm.output(atSource: s.end)
                guard b - a > 0.2 else { continue }
                // Small zooms still need an audible whoosh: floor at -9 dB,
                // rise gently with zoom magnitude, never above -2 dB.
                let g = clamp(-9 + 5 * (s.scale - 1), -9, -2)
                cues.append(SFXCue(t: a, kind: .whooshIn, gainDb: g + t.audio.zoomInGainDb))
                cues.append(SFXCue(t: b, kind: .whooshOut, gainDb: g + t.audio.zoomOutGainDb))
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
                                  webcamAspect: input.webcamAspect, layout: layout, placement: placement,
                                  captions: captions, autoMasks: autoMasks, personMask: input.personMask)
        if ProcessInfo.processInfo.environment["LUMEN_ZOOM_DEBUG"] == "1" {
            let cam = t.derived?.camera
            for event in input.events where event.kind == .down && event.button == 0 {
                let outTime = tm.output(atSource: event.t)
                let frame = t.evaluate(at: outTime)
                // Per-click: target lz, arrival at click, click in viewport (normalised).
                let idx = min(max(Int(outTime * (cam?.rate ?? gridRate)), 0), (cam?.lz.count ?? 1) - 1)
                let lzNow = (cam?.lz.isEmpty == false) ? Double(cam!.lz[idx]) : log(Double(frame.cameraScale))
                let targetScale = t.zoom.first { abs($0.start - event.t) < 0.01 }?.scale
                                    ?? t.zoom.first { event.t >= $0.start && event.t <= $0.end }?.scale ?? 1
                let targetLz = log(targetScale)
                let arrival = targetLz > 0.001 ? lzNow / targetLz : 0
                let vw = Double(src.width) / Double(frame.cameraScale), vh = Double(src.height) / Double(frame.cameraScale)
                let vx = (Double(event.x) - (Double(frame.cameraCenter.x) - vw / 2)) / vw
                let vy = (Double(event.y) - (Double(frame.cameraCenter.y) - vh / 2)) / vh
                let message = String(format: "LUMEN_ZOOM event=%.5f source=%.5f output=%.5f click=(%.1f,%.1f) focus=(%.1f,%.1f) scale=%.3f target_lz=%.3f arrival=%.3f viewport=(%.3f,%.3f)\n",
                                     event.t, event.t, outTime, event.x, event.y,
                                     frame.cameraCenter.x, frame.cameraCenter.y, frame.cameraScale,
                                     targetLz, arrival, vx, vy)
                FileHandle.standardError.write(Data(message.utf8))
            }
            let zs = t.zoom.sorted { $0.start < $1.start }
            for (a, b) in zip(zs, zs.dropFirst()) {
                let ta = tm.output(atSource: a.end), tb = tm.output(atSource: b.start)
                guard tb > ta, tb - ta < 2.2, let track = t.derived?.camera, !track.lz.isEmpty else { continue }
                let first = min(max(Int(ta * track.rate), 0), track.lz.count - 1)
                let last = min(max(Int(tb * track.rate), first), track.lz.count - 1)
                let lo = track.lz[first...last].min() ?? 0
                FileHandle.standardError.write(Data(String(format: "LUMEN_DIP gap=%.2f minScale=%.3f expected>=%.3f\n",
                    tb - ta, exp(Double(lo)), min(a.scale, b.scale) * 0.98).utf8))
            }
            for e in input.events where e.kind == .keyDown && e.axFrameIndex > 0 && Int(e.axFrameIndex) <= input.ax.count {
                guard let c = input.ax[Int(e.axFrameIndex) - 1].caret else { continue }
                let o = tm.output(atSource: e.t), f = t.evaluate(at: o)
                let vw = Double(src.width) / Double(f.cameraScale), vh = Double(src.height) / Double(f.cameraScale)
                let nx = (c.x + c.w / 2 - (Double(f.cameraCenter.x) - vw / 2)) / vw
                let ny = (c.y + c.h / 2 - (Double(f.cameraCenter.y) - vh / 2)) / vh
                FileHandle.standardError.write(Data(String(format: "LUMEN_TYPING t=%.3f scale=%.2f caret_in_view=(%.2f,%.2f)\n", e.t, f.cameraScale, nx, ny).utf8))
            }
        }
        return t
    }

    /// SMOOTHNESS: digest of everything the zoom/ramp planners read. A
    /// style-only edit keeps the digest, a changed click does not.
    private static func inputDigest(_ input: DirectorInput) -> UInt64 {
        var h = Hasher()
        for e in input.events {
            h.combine(e.t); h.combine(e.kind); h.combine(e.x); h.combine(e.y)
            h.combine(e.button); h.combine(e.keyCode); h.combine(e.flags)
            h.combine(e.cursorShape); h.combine(e.axFrameIndex); h.combine(e.scrollDelta)
        }
        for f in input.ax { h.combine(f.x); h.combine(f.y); h.combine(f.w); h.combine(f.h) }
        for t in input.typing {
            h.combine(t.t0); h.combine(t.t1); h.combine(t.samples.count)
            h.combine(t.rect?.origin.x); h.combine(t.rect?.origin.y); h.combine(t.rect?.size.width)
        }
        for a in input.activity {
            h.combine(a.t); h.combine(a.x); h.combine(a.y); h.combine(a.coverage)
            h.combine(a.region?.minX); h.combine(a.region?.minY)
            h.combine(a.region?.width); h.combine(a.region?.height)
        }
        return UInt64(bitPattern: Int64(h.finalize()))
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
    public var cameraTilt: SIMD2<Float> = .zero       // (yaw, pitch) degrees; renderer homography consumes this in Part 5
    public var cursor: CursorSample
    public var clickFX: [ClickRing]
    public var webcamCrop: SIMD4<Float>       // uv x, y, w, h
    public var sourceTime: Double
    public var layout: ResolvedLayout
    public var layoutKind: LayoutKind
    public var webcamCorner: WebcamLayout.Corner?
    public var webcamOpacity: Float
    public var caption: CaptionChunk?
    public var emphasis: EmphasisFrame

    public init(cameraCenter: SIMD2<Float>, cameraScale: Float, cameraTilt: SIMD2<Float> = .zero,
                cursor: CursorSample, clickFX: [ClickRing], webcamCrop: SIMD4<Float>, sourceTime: Double,
                layout: ResolvedLayout = .full, layoutKind: LayoutKind = .screenOnly, webcamCorner: WebcamLayout.Corner? = nil,
                webcamOpacity: Float = 1, caption: CaptionChunk? = nil, emphasis: EmphasisFrame = EmphasisFrame()) {
        self.cameraCenter = cameraCenter; self.cameraScale = cameraScale; self.cameraTilt = cameraTilt; self.cursor = cursor
        self.clickFX = clickFX; self.webcamCrop = webcamCrop; self.sourceTime = sourceTime; self.layout = layout
        self.layoutKind = layoutKind; self.webcamCorner = webcamCorner; self.webcamOpacity = webcamOpacity
        self.caption = caption; self.emphasis = emphasis
    }
}

@inline(__always) private func cr(_ a: [Float], _ f: Double) -> Float {
    let i = Int(f.rounded(.down)), u = Float(f - Double(i)), n = a.count
    func g(_ k: Int) -> Float { a[min(max(k, 0), n - 1)] }
    let p0 = g(i - 1), p1 = g(i), p2 = g(i + 1), p3 = g(i + 2)
    return p1 + 0.5 * u * (p2 - p0 + u * (2 * p0 - 5 * p1 + 4 * p2 - p3 + u * (3 * (p1 - p2) + p3 - p0)))
}
@inline(__always) private func qhm(_ p: [Float], _ v: [Float], _ a: [Float], _ f: Double, rate: Double) -> Float {
    guard p.count >= 2 else { return p.first ?? 0 }
    let i = min(max(Int(f), 0), p.count - 2)
    let duration = 1 / rate
    let move = QuinticMove(t0: Double(i) * duration, T: duration,
                           x0: Double(p[i]), v0: Double(v[i]), a0: Double(a[i]),
                           x1: Double(p[i + 1]), v1: Double(v[i + 1]), a1: Double(a[i + 1]))
    return Float(move.sample(f * duration).x)
}
private func cf(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

extension Timeline {
    /// Pure function of (self, t). Microseconds. Safe to call from any thread.
    public func evaluate(at t0: Double) -> FrameState {
        // Imported clips are composed on the same output clock but carry no
        // recording metadata: no camera move, no cursor, no masks. Returning a
        // synthetic state here keeps one evaluation entry point for preview and
        // export, so a clip can never inherit a stale zoom from the recording.
        if let (clip, time) = clipSource(atOutput: t0) {
            let d = SIMD2(Double(clip.width), Double(clip.height))
            return FrameState(cameraCenter: SIMD2(Float(d.x / 2), Float(d.y / 2)), cameraScale: 1,
                              cursor: CursorSample(position: .zero, velocity: .zero, opacity: 0, press: 1, shape: 0),
                              clickFX: [], webcamCrop: [0, 0, 1, 1], sourceTime: time,
                              layout: .full, layoutKind: .screenOnly, webcamCorner: nil, webcamOpacity: 0,
                              caption: nil, emphasis: EmphasisFrame())
        }
        guard let d = derived else {
            return FrameState(cameraCenter: .zero, cameraScale: 1, cameraTilt: .zero,
                              cursor: CursorSample(position: .zero, velocity: .zero, opacity: 0, press: 1, shape: 0),
                              clickFX: [], webcamCrop: [0, 0, 1, 1], sourceTime: 0)
        }
        let t = clamp(t0, 0, d.outputDuration), f = t * gridRate
        let c = d.camera, u = d.cursor
        let cameraFrame = t * c.rate
        let cam = SIMD2<Float>(qhm(c.nx, c.vx, c.ax, cameraFrame, rate: c.rate) * Float(d.sourceSize.x),
                               qhm(c.ny, c.vy, c.ay, cameraFrame, rate: c.rate) * Float(d.sourceSize.y))
        let scale = exp(qhm(c.lz, c.vz, c.az, cameraFrame, rate: c.rate))
        let tilt = SIMD2<Float>(cr(c.yaw, cameraFrame), cr(c.pitch, cameraFrame))
        let pos = SIMD2<Float>(cr(u.x, f), cr(u.y, f))
        let vel = SIMD2<Float>(cr(u.x, f + 1) - cr(u.x, f - 1), cr(u.y, f + 1) - cr(u.y, f - 1)) * Float(gridRate / 2)
        let cs = CursorSample(position: pos, velocity: vel, opacity: cf(cr(u.opacity, f), 0, 1), press: cr(u.press, f),
                              shape: u.shape[min(Int(f.rounded()), u.shape.count - 1)])
        var rings: [ClickRing] = []
        if cursor.clickRing != nil, cursor.clickEffect != .none, !d.clicks.isEmpty {
            let dur = max(cursor.clickDuration, 0.05)
            // A click whose time is the frame time must exist on that frame.
            // Source→output time conversion leaves a few 1e-14 of error, so an
            // exact comparison hides the first tick of every ripple.
            let eps = 1e-6
            var lo = 0, hi = d.clicks.count
            while lo < hi { let m = (lo + hi) / 2; if d.clicks[m].t <= t - dur + eps { lo = m + 1 } else { hi = m } }
            var i = lo
            // SMOOTHNESS: reserve once. `evaluate` runs for every sub-frame of
            // every frame; the ring list is the one array that grows there.
            rings.reserveCapacity(8)
            while i < d.clicks.count, d.clicks[i].t <= t + eps {
                rings.append(ClickRing(position: SIMD2(d.clicks[i].x, d.clicks[i].y), progress: Float((t - d.clicks[i].t) / dur)))
                i += 1
            }
            // Cap alive ripples: rapid clicking cannot fan out past 8 feeds.
            if rings.count > 8 { rings = Array(rings.suffix(8)) }
        }
        // webcam crop: face-aware or centered square
        let ar = max(d.webcamAspect, 0.1)
        var ch: Float = 1, cx: Float = 0.5, cy: Float = 0.5
        let layoutKind = d.layout.kind(at: t)
        if layoutSettings[layoutKind].autoFrame, !d.face.isEmpty {
            let fp = t * faceGridRate, i0 = min(Int(fp), d.face.count - 1), i1 = min(i0 + 1, d.face.count - 1)
            let fc = d.face[i0] + (d.face[i1] - d.face[i0]) * Float(fp - Double(i0))
            cx = fc.x; cy = fc.y; ch = cf(fc.z, 0.25, 1)
        }
        let cw = min(ch / ar, 1)
        let crop = SIMD4<Float>(cf(cx - cw / 2, 0, 1 - cw), cf(cy - ch / 2, 0, 1 - ch), cw, ch)
        let sourceTime = timeMap.source(atOutput: t)
        let emphasis = Emphasis.evaluate(overlays: overlays, autoMasks: d.autoMasks, sourceTime: sourceTime,
                                         cursor: pos, sourceSize: d.sourceSize)
        // SMOOTHNESS: captions are sorted by start — binary search instead of a
        // linear scan that ran for every sub-frame of every frame.
        var caption: CaptionChunk?
        if !d.captions.isEmpty {
            var lo = 0, hi = d.captions.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if d.captions[mid].start <= t { lo = mid } else { hi = mid - 1 }
            }
            let c = d.captions[lo]
            if t >= c.start, t < c.end { caption = c }
        }
        return FrameState(cameraCenter: cam, cameraScale: scale, cameraTilt: tilt, cursor: cs, clickFX: rings, webcamCrop: crop,
                          sourceTime: sourceTime, layout: d.layout.sample(at: t), layoutKind: layoutKind,
                          webcamCorner: d.placement.corner(at: t), webcamOpacity: d.placement.visibility(at: t),
                          caption: caption, emphasis: emphasis)
    }
}
