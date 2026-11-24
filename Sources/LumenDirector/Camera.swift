import Foundation
import LumenCore
import LumenProject

/// The recorded camera, baked at 480 Hz; critically damped springs.
enum CameraSolver {
    static let cameraRate = 480.0

    /// Forward/backward dead-zone tracking (ZoomPrecisionTests locks it).
    static func centredPlay(_ samples: [Double], halfZone: Double) -> [Double] {
        guard let first = samples.first, let last = samples.last else { return samples }
        func pass(_ input: [Double], start: Double) -> [Double] {
            var result = input, value = start
            for i in input.indices {
                if input[i] > value + halfZone { value = input[i] - halfZone }
                else if input[i] < value - halfZone { value = input[i] + halfZone }
                result[i] = value
            }
            return result
        }
        let forward = pass(samples, start: first)
        let backward = Array(pass(Array(samples.reversed()), start: last).reversed())
        return zip(forward, backward).map { ($0 + $1) / 2 }
    }

    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams,
                      src: SIMD2<Double>, outDur: Double, loop: Double?,
                      crop: DenseCropTrack = DenseCropTrack(), aspect: Double? = nil) -> CameraTrack {
        solve(zoom: zoom, tm: tm, cursor: cursor, p: p, src: src, outDur: outDur, loop: loop,
              crop: crop, aspect: aspect, follow: [:], cancelled: { false }) ?? CameraTrack(count: 2, rate: cameraRate)
    }

    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams,
                      src: SIMD2<Double>, outDur: Double, loop: Double?,
                      crop: DenseCropTrack = DenseCropTrack(), aspect: Double? = nil,
                      cancelled: () -> Bool) -> CameraTrack? {
        solve(zoom: zoom, tm: tm, cursor: cursor, p: p, src: src, outDur: outDur, loop: loop,
              crop: crop, aspect: aspect, follow: [:], cancelled: cancelled)
    }

    /// Follow paths: output seconds, source-normalised coords.
    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams,
                      src: SIMD2<Double>, outDur: Double, loop: Double?,
                      crop: DenseCropTrack = DenseCropTrack(), aspect: Double? = nil,
                      kinds: [UUID: ZoomPlanner.IntentKind] = [:],
                      follow: [UUID: [(t: Double, c: SIMD2<Double>)]],
                      cancelled: () -> Bool) -> CameraTrack? {
        guard outDur.isFinite, outDur > 0, src.x.isFinite, src.y.isFinite, src.x > 0, src.y > 0 else {
            return CameraTrack(count: 2, rate: cameraRate)
        }
        if cancelled() { return nil }
        let ctx = Context(rate: cameraRate, n: max(Int(outDur * cameraRate) + 1, 2), src: src,
                          cropAtTick: denseCropTicks(crop, tm: tm, rate: cameraRate, outDur: outDur, src: src),
                          aspect: aspect, p: p)
        let scenes = buildScenes(zoom: zoom, tm: tm, ctx: ctx, follow: follow)
        if scenes.isEmpty, p.tilt != .reveal { return CameraTrack(count: 2, rate: cameraRate) }
        return solveScenes(scenes, context: ctx, cursor: cursor, params: p, loop: loop,
                           kinds: kinds, cancelled: cancelled)
    }

    private static func solveScenes(_ scenes: [Scene], context ctx: Context, cursor: CursorTrack,
                                    params: CameraParams, loop: Double?,
                                    kinds: [UUID: ZoomPlanner.IntentKind], cancelled: () -> Bool) -> CameraTrack? {
        let baked = assignChains(scenes, mergeHorizon: ctx.panThroughGap)
        let (followX, followY) = globalFollow(cursor: cursor, baked: baked, ctx: ctx)
        var followTracks: [(start: Int, centers: [SIMD2<Double>])?] = []
        followTracks.reserveCapacity(baked.count)
        for s in baked {
            if cancelled() { return nil }
            followTracks.append(pathCenters(s, ctx: ctx))
        }
        guard var track = bake(baked, ctx: ctx, followX: followX, followY: followY,
                               followTracks: followTracks, kinds: kinds, cancelled: cancelled) else { return nil }
        if params.preset != .fixed, let last = baked.max(by: { $0.off < $1.off }),
           last.segment.origin == .auto {
            let end = track.lz.count - 1
            let duration = params.tail.isFinite ? clamp(params.tail, 0.3, 2) : 0.7
            // The release must own a real runway. When the final shot ends at
            // (or past) the composition end, anchoring the start at its event
            // compressed the whole return into 8-9 ticks — a visible pan
            // teleport. Start at the earlier of the shot end and (end - tail);
            // a shot that runs off the edge is simply cut short by the return.
            let start = min(last.off, Double(end) / track.rate - duration)
            finishAutomaticZoom(&track, startingAt: start, duration: duration)
        }
        blendLoop(&track, duration: loop)
        applyTilt(&track, params: params)
        publishDerivatives(&track)
        return track
    }

    /// Publish derivatives from the baked positions so `qhm` reconstructs the
    /// same trajectory at sub-tick times (positions are left untouched, so the
    /// fixed-pivot invariant stays exact).
    private static func publishDerivatives(_ track: inout CameraTrack) {
        let n = track.lz.count
        guard n >= 3 else { return }
        let r = track.rate, r2 = r * r
        for k in 1..<(n - 1) {
            func d(_ a: [Float]) -> Double { Double(a[k + 1]) - Double(a[k - 1]) }
            func dd(_ a: [Float]) -> Double {
                Double(a[k + 1]) - 2 * Double(a[k]) + Double(a[k - 1])
            }
            track.vx[k] = Float(d(track.nx) * r / 2)
            track.vy[k] = Float(d(track.ny) * r / 2)
            track.ax[k] = Float(dd(track.nx) * r2)
            track.ay[k] = Float(dd(track.ny) * r2)
            // C1: publish the scale derivatives from the FINAL baked lz, in the
            // same pass as the position channels. A leg boundary or the tail
            // rewrite can otherwise leave vz/az stale by one tick, so the
            // sub-tick Hermite used qhm() would start the next leg with a
            // velocity step. All six fields now come from the same bake.
            track.vz[k] = Float(d(track.lz) * r / 2)
            track.az[k] = Float(dd(track.lz) * r2)
        }
    }

    /// C2 binomial passes on pan, restricted to frames that are actually
    /// moving. A settled hold is bit-for-bit constant over the whole kernel
    /// window, so it is left untouched — preserving the exact arrival target —
    /// while a re-aim loses the velocity step that spikes the jerk metric.
    private static func smoothMovingPan(_ track: inout CameraTrack, ctx: Context) {
        let n = track.nx.count
        guard n >= 5 else { return }
        for _ in 0..<16 {
            let cx = track.nx, cy = track.ny
            for k in 2..<(n - 2) {
                func s(_ a: [Float]) -> Float {
                    (a[k - 2] + 4 * a[k - 1] + 6 * a[k] + 4 * a[k + 1] + a[k + 2]) / 16
                }
                track.nx[k] = s(cx); track.ny[k] = s(cy)
            }
        }
        for k in 0..<n {
            let c = clampCenter(SIMD2(Double(track.nx[k]), Double(track.ny[k])),
                                Double(track.lz[k]), k, ctx: ctx)
            track.nx[k] = Float(c.x); track.ny[k] = Float(c.y)
        }
    }

    private static func finishAutomaticZoom(_ track: inout CameraTrack, startingAt time: Double,
                                            duration requestedDuration: Double) {
        let last = track.lz.count - 1
        let start = min(max(Int((time * track.rate).rounded(.up)), 0), last - 1)
        let end = min(start + Int((requestedDuration * track.rate).rounded(.up)), last)
        let span = Double(end - start)
        let duration = span / track.rate
        let initialLog = Double(track.lz[start])
        let neutral = SIMD2<Double>(repeating: 0.5)
        let initialCenter = SIMD2(Double(track.nx[start]), Double(track.ny[start]))
        // Fixed-pivot release: the subject stays pinned on screen while the
        // plate returns to full frame. Guard the pivot for a near-full-frame
        // shot, where expm1(logScale) would blow it far outside the frame.
        let pivot = initialLog > 1e-3
            ? initialCenter + (initialCenter - neutral) / expm1(initialLog)
            : neutral
        let pivotC = SIMD2(clamp(pivot.x, -1, 2), clamp(pivot.y, -1, 2))
        for i in start...last {
            let u = min(Double(i - start) / span, 1)
            let remaining = 1 - u
            let logScale = initialLog * remaining * remaining * remaining * (1 + 3 * u + 6 * u * u)
            let speed = -30 * initialLog * u * u * remaining * remaining / duration
            let acceleration = -60 * initialLog * u * remaining * (1 - 2 * u) / (duration * duration)
            let center = neutral + (pivotC - neutral) * -expm1(-logScale)
            let velocity = (pivotC - center) * speed
            let centerAcceleration = (pivotC - center) * (acceleration - speed * speed)
            track.lz[i] = Float(logScale)
            track.nx[i] = Float(center.x)
            track.ny[i] = Float(center.y)
            track.vz[i] = Float(speed)
            track.vx[i] = Float(velocity.x)
            track.vy[i] = Float(velocity.y)
            track.az[i] = Float(acceleration)
            track.ax[i] = Float(centerAcceleration.x)
            track.ay[i] = Float(centerAcceleration.y)
        }
    }

    private static func blendLoop(_ track: inout CameraTrack, duration: Double?) {
        guard let duration, duration.isFinite, duration > 0 else { return }
        let last = track.lz.count - 1
        let count = max(1, Int(min(duration * track.rate, Double(last))))
        let first = last - count
        for index in first...last {
            let u = Double(index - first) / Double(count)
            let w = Float(u * u * u * (10 + u * (-15 + 6 * u)))
            track.lz[index] += (track.lz[0] - track.lz[index]) * w
            track.nx[index] += (track.nx[0] - track.nx[index]) * w
            track.ny[index] += (track.ny[0] - track.ny[index]) * w
        }
        for index in first...last {
            let a = max(index - 1, 0), b = min(index + 1, last)
            let velocity = Float(track.rate) / Float(b - a)
            track.vz[index] = (track.lz[b] - track.lz[a]) * velocity
            track.vx[index] = (track.nx[b] - track.nx[a]) * velocity
            track.vy[index] = (track.ny[b] - track.ny[a]) * velocity
        }
        for index in first...last {
            let a = max(index - 1, 0), b = min(index + 1, last)
            let acceleration = Float(track.rate) / Float(b - a)
            track.az[index] = (track.vz[b] - track.vz[a]) * acceleration
            track.ax[index] = (track.vx[b] - track.vx[a]) * acceleration
            track.ay[index] = (track.vy[b] - track.vy[a]) * acceleration
        }
    }

    private static func applyTilt(_ track: inout CameraTrack, params: CameraParams) {
        switch params.tilt {
        case .off:
            break
        case .lean:
            let yawLimit = params.maxYaw.isFinite ? clamp(params.maxYaw, 0, 8) : 8
            let pitchLimit = params.maxPitch.isFinite ? clamp(params.maxPitch, 0, 6) : 6
            let omega = params.omegaTilt.isFinite ? clamp(params.omegaTilt, 2, 12) : 5
            var tilt = Spring3(x: .zero)
            for index in track.lz.indices {
                let target = SIMD3(clamp(Double(track.vx[index]) * 6, -yawLimit, yawLimit),
                                   clamp(Double(track.vy[index]) * -4, -pitchLimit, pitchLimit), 0)
                tilt.step(target: target, omega: SIMD3(repeating: omega), dt: 1 / track.rate)
                track.yaw[index] = Float(tilt.x.x)
                track.pitch[index] = Float(tilt.x.y)
            }
        case .reveal:
            for index in 0..<min(Int(track.rate * 0.9) + 1, track.lz.count) {
                let u = min(Double(index) / (track.rate * 0.9), 1)
                track.yaw[index] = Float(12 * (1 - u * u * u * (10 + u * (-15 + 6 * u))))
            }
        }
    }

    private struct Scene {
        var on, off, event, lz, omega: Double
        var center: SIMD2<Double>
        var segment: ZoomSegment
        var path: [(t: Double, c: SIMD2<Double>)]
        var chainStart: Bool // true: this shot starts a fresh chain
    }

    private struct Context {
        let rate: Double
        let dt: Double
        let n: Int
        let src: SIMD2<Double>
        let cropAtTick: [PxRect]
        let full: PxRect
        let aspect: Double?
        let look: Double
        let offset: SIMD2<Double>
        let omegaPan: Double
        let omegaZoomBase: Double
        let exitOmega: Double
        let panThroughGap: Double
        let maxLz: Double
        let followOmega: Double
        let deadZoneHalf: Double
        let leadBase: Double

        init(rate: Double, n: Int, src: SIMD2<Double>, cropAtTick: [PxRect], aspect: Double?, p: CameraParams) {
            self.rate = rate
            self.dt = 1 / rate
            self.src = src
            self.cropAtTick = cropAtTick
            full = PxRect(x: 0, y: 0, w: src.x, h: src.y)
            self.aspect = aspect
            self.n = n
            look = clamp(p.lookahead.isFinite ? p.lookahead : 0.12, 0, 0.5)
            offset = SIMD2(clamp(p.centerOffsetX, -0.25, 0.25), clamp(p.centerOffsetY, -0.25, 0.25))
            omegaPan = max(p.omegaPan.isFinite ? p.omegaPan : 4, 1)
            // The rise omega is hard-coded: omegaZoom is a retired knob and may
            // not reach the recorded bake (CameraAccuracyTests pins this).
            omegaZoomBase = 28
            // `tail` as a release time scale: 0.7 → 20 rad/s → the full-frame
            // return settles inside ~0.5 s, so a 1 s gap really shows the full
            // frame instead of a partial descent. The 22 cap keeps the peak
            // release velocity (Δ·ω/e at Δ≈1.1) under the 0.02/tick gate.
            let tailValue = p.tail.isFinite ? p.tail : 0.7
            exitOmega = clamp(14.0 / max(tailValue, 0.3), 6, 22)
            // Bridge only shots that are close enough to read as one action.
            // A 1 s (or longer) gap must come up for air; panThroughGap is a
            // retired knob and is deliberately ignored here.
            panThroughGap = 0.95
            maxLz = log(max(p.maxScale.isFinite ? p.maxScale : 2, 1.0001))
            // Latency of the causal follow pre-smoother; keep the knob live.
            followOmega = 1 / max(clamp(p.followDelay.isFinite ? p.followDelay : 0.12, 0, 0.5), 0.045)
            deadZoneHalf = clamp(p.deadZone.isFinite ? p.deadZone : 0.28, 0.05, 0.45) / 2
            leadBase = p.leadIn.isFinite ? clamp(p.leadIn, 0, 1.5) : 0.30
        }

        func crop(at tick: Int) -> PxRect {
            cropAtTick.isEmpty ? full : cropAtTick[tick]
        }
    }

    private static func denseCropTicks(_ crop: DenseCropTrack, tm: TimeMap,
                                       rate: Double, outDur: Double, src: SIMD2<Double>) -> [PxRect] {
        guard !crop.rects.isEmpty else { return [] }
        let n = max(Int(outDur * rate) + 1, 2)
        var boxes = [PxRect](repeating: PxRect(x: 0, y: 0, w: src.x, h: src.y), count: n)
        let cropHz = crop.hz.isFinite && crop.hz > 0 ? crop.hz : rate
        let dense = DenseCropTrack(hz: cropHz, rects: crop.rects)
        for k in 0..<n {
            let r = dense.rect(at: tm.source(atOutput: Double(k) / rate))
            if r.isValid, r.w >= 1, r.h >= 1 { boxes[k] = r }
        }
        return boxes
    }

    private static func tickIndex(_ t: Double, rate: Double, n: Int) -> Int {
        min(max(Int((t * rate).rounded()), 0), n - 1)
    }

    private static func normalise(_ sourcePoint: SIMD2<Double>, at tick: Int, ctx: Context) -> SIMD2<Double> {
        let px = sourcePoint * ctx.src
        let c = CropSpace.normalise(px.x, px.y, crop: ctx.crop(at: tick))
        return SIMD2(c.u, c.v)
    }

    private static func clampCenter(_ c: SIMD2<Double>, _ lz: Double, _ k: Int, ctx: Context) -> SIMD2<Double> {
        let box = ctx.crop(at: k)
        let base = CropSpace.baseView(crop: box, aspect: ctx.aspect)
        let z = exp(max(lz, 0))
        let hw = base.w / z / (2 * box.w), hh = base.h / z / (2 * box.h)
        return SIMD2(clamp(c.x, min(hw, 0.5), max(1 - hw, 0.5)),
                     clamp(c.y, min(hh, 0.5), max(1 - hh, 0.5)))
    }

    private static func buildScenes(zoom: [ZoomSegment], tm: TimeMap, ctx: Context,
                                    follow: [UUID: [(t: Double, c: SIMD2<Double>)]]) -> [Scene] {
        func leadFor(_ ease: Double) -> Double { clamp(ctx.leadBase / max(ease, 0.55), 0.20, 1.6) }
        func manualRise(_ ease: Double) -> Double { clamp(0.9 / max(ease, 0.3), 0.25, 2.0) }
        // NaN/infinite times would trap in TimeMap.output — drop them.
        let finiteZoom = zoom.filter { $0.start.isFinite && $0.end.isFinite }
        // Total (on, lz, offset) order keeps the bake bit-for-bit stable.
        return finiteZoom.enumerated().compactMap { offset, z -> (Int, Scene)? in
            let a = tm.output(atSource: z.start), b = tm.output(atSource: z.end)
            guard a.isFinite, b.isFinite, b - a > 0.02, z.scale.isFinite, z.scale > 1.001, a < Double(ctx.n - 1) / ctx.rate else { return nil }
            let easeRaw = z.easing?.omegaScale ?? 1
            let ease = easeRaw.isFinite && easeRaw > 0 ? easeRaw : 1
            let lz = clamp(log(max(z.scale, 1.0001)), 0, ctx.maxLz)
            let path = (follow[z.id] ?? [])
                .filter { $0.t.isFinite && $0.c.x.isFinite && $0.c.y.isFinite }
                .sorted { $0.t < $1.t }
            let event: Double = z.origin == .auto
                ? a : min(a + manualRise(ease), max(b - 0.05, a + 0.05))
            let center: SIMD2<Double>
            switch z.focus {
            case .fixed(let x, let y):
                center = x.isFinite && y.isFinite
                    ? SIMD2(x, y)
                    : SIMD2(0.5, 0.5)
            case .element(let x, let y, let w, let h):
                center = x.isFinite && y.isFinite && w.isFinite && h.isFinite
                    ? SIMD2(x + w / 2, y + h / 2)
                    : SIMD2(0.5, 0.5)
            case .follow:
                center = path.first?.c ?? SIMD2(0.5, 0.5)
            }
            let lead = leadFor(ease)
            let settle = z.origin == .auto ? min(clamp(0.11 / max(ease, 0.6), 0.06, 0.18), 0.35 * lead) : 0
            let on = z.origin == .auto ? max(a - lead - settle, 0) : a
            let omega = clamp(min(clamp(ctx.omegaZoomBase * ease, 2, 40), safeZoomOmega(lz, rate: ctx.rate)), 2, 40)
            return (offset, Scene(on: on, off: max(b, event + 0.02), event: event, lz: lz, omega: omega,
                                  center: center, segment: z, path: path, chainStart: true))
        }
        .sorted { ($0.1.on, $0.1.lz, $0.0) < ($1.1.on, $1.1.lz, $1.0) }
        .map(\.1)
    }

    /// Merge close shots into one move, capped at `chainLimit` — each leg must
    /// stay well under the longest-shot + 4.5 s bake budget.
    private static func assignChains(_ scenes: [Scene], mergeHorizon: Double = 1.25,
                                     chainLimit: Double = 4.0) -> [Scene] {
        var baked = scenes
        guard baked.count > 1 else { return baked }
        baked[0].chainStart = true
        // Merge on the ACTIONS, not on the padded scene windows: a lead-in of
        // ~0.4 s otherwise makes a 1 s gap look like a 0.6 s gap and fuses two
        // distinct shots into one 8 s continuous zoom.
        var chainStart = baked[0].segment.start
        for i in 1..<baked.count {
            let gap = baked[i].segment.start - baked[i - 1].segment.end
            let far = gap > mergeHorizon
            let runOver = baked[i].segment.start - chainStart >= chainLimit
            if far || runOver {
                baked[i].chainStart = true
                chainStart = baked[i].segment.start
                // Lead-ins overlap the previous shot's tail in a dense chain,
                // so `activeAt` never goes idle and the run never breaks. End
                // the previous shot early enough for a real full-frame return
                // before this new chain takes over.
                if i > 0 {
                    let releaseEnd = baked[i].on - 0.18
                    let floor = baked[i - 1].segment.start + 0.1
                    baked[i - 1].off = max(min(baked[i - 1].off, releaseEnd), floor)
                }
            } else {
                baked[i].chainStart = false
            }
        }
        return baked
    }

    /// Largest critically-damped omega under the 0.02 per-tick gate:
    /// peak |v| = Δ·ω/e, so ω ≤ 0.019·rate·e/Δ (5% margin).
    private static func safeZoomOmega(_ amplitude: Double, rate: Double) -> Double {
        amplitude > 1e-3 ? 0.019 * rate * exp(1) / amplitude : 40
    }

    /// Solve `(1 + x)e^-x = target` for x ≥ 0 by Newton.
    private static func globalFollow(cursor: CursorTrack, baked: [Scene], ctx: Context) -> ([Double], [Double]) {
        let needsCursor = baked.contains {
            if case .follow = $0.segment.focus { return $0.path.count < 2 }
            return false
        }
        var followX = [Double](repeating: 0.5, count: ctx.n), followY = followX
        guard needsCursor, min(cursor.x.count, cursor.y.count) > 0 else { return (followX, followY) }
        let halfZone = ctx.deadZoneHalf
        let cx = min(cursor.x.count, cursor.y.count)
        let rawX = (0..<ctx.n).map { i -> Double in
            let j = min(Int(Double(i) * gridRate / ctx.rate), cx - 1), box = ctx.crop(at: i)
            return (Double(cursor.x[j]) - box.x) / box.w
        }
        let rawY = (0..<ctx.n).map { i -> Double in
            let j = min(Int(Double(i) * gridRate / ctx.rate), cx - 1), box = ctx.crop(at: i)
            return (Double(cursor.y[j]) - box.y) / box.h
        }
        followX = causalSpring(centredPlay(rawX, halfZone: halfZone), omega: ctx.followOmega, dt: ctx.dt)
        followY = causalSpring(centredPlay(rawY, halfZone: halfZone), omega: ctx.followOmega, dt: ctx.dt)
        return (followX, followY)
    }

    private static func pathCenters(_ s: Scene, ctx: Context) -> (start: Int, centers: [SIMD2<Double>])? {
        guard s.path.count >= 2 else { return nil }
        let a = tickIndex(s.on, rate: ctx.rate, n: ctx.n)
        let b = min(max(Int((s.off * ctx.rate).rounded()), a), ctx.n - 1)
        guard b > a else { return nil }
        let scale = exp(s.lz), lean = 0.12 / scale
        var xs: [Double] = [], ys: [Double] = []
        xs.reserveCapacity(b - a + 1); ys.reserveCapacity(b - a + 1)
        var j = 0
        for k in a...b {
            let t = Double(k) / ctx.rate + ctx.look
            while j + 1 < s.path.count, s.path[j + 1].t <= t { j += 1 }
            var c = s.path[j].c
            if j + 1 < s.path.count {
                let from = s.path[j], to = s.path[j + 1], gap = to.t - from.t
                if gap <= 0.30 { c = from.c + (to.c - from.c) * clamp((t - from.t) / max(gap, 1e-6), 0, 1) }
            }
            // Waypoints stay attached to their source pixels as the crop moves.
            let box = ctx.crop(at: k)
            xs.append((c.x * ctx.src.x - box.x) / box.w + lean)
            ys.append((c.y * ctx.src.y - box.y) / box.h)
        }
        xs = causalSpring(centredPlay(xs, halfZone: 0.04 / scale), omega: ctx.followOmega, dt: ctx.dt)
        ys = causalSpring(centredPlay(ys, halfZone: 0.06 / scale), omega: ctx.followOmega, dt: ctx.dt)
        var centres: [SIMD2<Double>] = []
        centres.reserveCapacity(xs.count)
        for (i, pair) in zip(xs, ys).enumerated() {
            centres.append(clampCenter(SIMD2(pair.0, pair.1), s.lz, a + i, ctx: ctx))
        }
        return (a, centres)
    }

    private struct Baker {
        let ctx: Context
        let baked: [Scene]
        let followX: [Double], followY: [Double]
        let followTracks: [(start: Int, centers: [SIMD2<Double>])?]
        let n: Int
        let activeAt: [Int]
        let nextAt: [Int]
        let kinds: [UUID: ZoomPlanner.IntentKind]

        init(baked: [Scene], ctx: Context, followX: [Double], followY: [Double],
             followTracks: [(start: Int, centers: [SIMD2<Double>])?],
             kinds: [UUID: ZoomPlanner.IntentKind] = [:]) {
            self.ctx = ctx; self.baked = baked
            self.followX = followX; self.followY = followY
            self.followTracks = followTracks
            self.kinds = kinds
            n = ctx.n
            activeAt = Self.activeSceneIndices(baked: baked, n: ctx.n, rate: ctx.rate)
            nextAt = Self.nextSceneIndices(baked: baked, n: ctx.n, rate: ctx.rate)
        }

        func rawCenter(_ i: Int, _ k: Int) -> SIMD2<Double> {
            let s = baked[i]
            if kinds[s.segment.id] == .typing {
                // Typing holds a stable target: the aim is the resolved field
                // centre in SOURCE space, re-expressed against the current crop
                // each tick, so a jittering AXWebArea crop cannot carry the
                // camera with it while the user types.
                let crop = ctx.crop(at: k)
                let src = SIMD2(s.center.x * ctx.src.x, s.center.y * ctx.src.y)
                return SIMD2((src.x - crop.x) / max(crop.w, 1e-9),
                             (src.y - crop.y) / max(crop.h, 1e-9))
            }
            if i < followTracks.count, let d = followTracks[i], !d.centers.isEmpty {
                let idx = min(max(k - d.start, 0), d.centers.count - 1)
                return d.centers[idx]
            }
            if case .follow = s.segment.focus { return SIMD2(followX[k], followY[k]) }
            return normalise(s.center, at: k, ctx: ctx)
        }

        /// First unarmed scene at this tick (-1 when none); a shot arms one tick late.
        static func nextSceneIndices(baked: [Scene], n: Int, rate: Double) -> [Int] {
            var result = [Int](repeating: -1, count: n)
            func activationTick(_ on: Double) -> Int { min(max(Int((on * rate).rounded()) + 1, 0), n - 1) }
            for k in 0..<n {
                var lo = 0, hi = baked.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if activationTick(baked[mid].on) <= k { lo = mid + 1 } else { hi = mid }
                }
                result[k] = lo < baked.count ? lo : -1
            }
            return result
        }

        static func activeSceneIndices(baked: [Scene], n: Int, rate: Double) -> [Int] {
            var activeAt = [Int](repeating: -1, count: n)
            for (i, s) in baked.enumerated() {
                let a = min(max(Int((s.on * rate).rounded()) + 1, 0), n - 1)
                let b = min(max(Int((s.off * rate).rounded()), a), n - 1)
                for k in a...b {
                    if activeAt[k] == -1 || baked[activeAt[k]].on <= s.on { activeAt[k] = i }
                }
            }
            return activeAt
        }

        /// A close-shot bridge tick, or nil.
        func mergedScene(_ k: Int) -> Int? {
            guard nextAt[k] >= 0 else { return nil }
            let next = baked[nextAt[k]]
            guard !next.chainStart else { return nil }
            let t = Double(k) / ctx.rate
            return next.on - t <= ctx.panThroughGap ? nextAt[k] : nil
        }

        /// A shot's hold targets.
        func holdTarget(_ i: Int, _ k: Int) -> (lz: Double, center: SIMD2<Double>, omega: Double) {
            let s = baked[i]
            let c = clampCenter(rawCenter(i, k) - ctx.offset * exp(-s.lz), s.lz, k, ctx: ctx)
            return (s.lz, c, s.omega)
        }
    }

    /// One tick of target selection.
    private static func tickTargets(_ baker: Baker, activeAt: [Int], k: Int,
                                    scaleSpring: Double,
                                    lastCenter: SIMD2<Double>)
        -> (lzTarget: Double, cx: Double, cy: Double, omega: Double, panOmega: Double, lastCenter: SIMD2<Double>) {
        let ctx = baker.ctx
        let restOmega = ctx.exitOmega
        // Pan floor = zoom-eased omega; a user pan setting above it still wins.
        let restPan = clamp(max(ctx.omegaPan, ctx.omegaZoomBase), 2, 40)
        if activeAt[k] >= 0 {
            let (lz, c, scOmega) = baker.holdTarget(activeAt[k], k)
            return (lz, c.x, c.y, scOmega, clamp(max(ctx.omegaPan, scOmega), 2, 40), c)
        }
        if let mi = baker.mergedScene(k) {
            // Merged shot pair: the next shot pulls the plate up — the
            // camera never falls back to full frame inside the bridge.
            let next = baker.baked[mi]
            let raw = baker.rawCenter(mi, k) - ctx.offset * exp(-next.lz)
            let c = clampCenter(raw, max(next.lz, 0), k, ctx: ctx)
            return (next.lz, c.x, c.y, min(next.omega, 6.0), 1.0, c)
        }
        if scaleSpring > 1e-6 {
            // Release while still zoomed: pin the last subject; the pan
            // stays on it until the plate reaches full frame. Size the
            // return to the silence actually available: a long gap can
            // afford a slow, filmed descent (it must still read as zoomed
            // just after the action), a short gap needs a decisive one.
            let c = clampCenter(lastCenter, max(scaleSpring, 0), k, ctx: ctx)
            var w = restOmega
            if baker.nextAt[k] >= 0 {
                let gap = baker.baked[baker.nextAt[k]].on - Double(k) / ctx.rate
                w = clamp(9.4 / max(gap - 0.05, 0.25), 9, restOmega)
            }
            w = clamp(min(w, safeZoomOmega(scaleSpring, rate: ctx.rate)), 2, 40)
            // The return pan must not snap the subject home; a gentle pan
            // here is what keeps the release jerk bounded.
            return (0.0, c.x, c.y, w, 1.0, c)
        }
        // Fully full frame: drift home and rest.
        return (0.0, 0.5, 0.5, restOmega, restPan, SIMD2(0.5, 0.5))
    }

    /// Bake one continuous response without interrupting the last action.
    private static func bake(_ baked: [Scene], ctx: Context,
                             followX: [Double], followY: [Double],
                             followTracks: [(start: Int, centers: [SIMD2<Double>])?],
                             kinds: [UUID: ZoomPlanner.IntentKind],
                             cancelled: () -> Bool) -> CameraTrack? {
        let n = ctx.n
        let baker = Baker(baked: baked, ctx: ctx, followX: followX, followY: followY,
                          followTracks: followTracks, kinds: kinds)
        let activeAt = baker.activeAt
        var track = CameraTrack(count: n, rate: ctx.rate)
        var scaleSpring = 0.0, panX = 0.5, panY = 0.5
        var scaleVel = 0.0, velX = 0.0, velY = 0.0
        // The subject of the last live shot is held while zoomed, then drifted home.
        var lastCenter = SIMD2<Double>(0.5, 0.5)
        // A zoom is a scale about a fixed pivot. Driving x and y with separate
        // springs lets the centre arrive on a different curve from the scale,
        // which is the sideways/up-down swim people feel as "floating". Track
        // the leg's start state so the centre can be derived from the scale.
        var activeScene = -1
        // P1 target design: for a zoom leg the centre is a pure function of
        // the scale about a fixed pivot, never an independent spring.
        var legStartLog = 0.0, legTargetLog = 0.0
        var legStartCenter = SIMD2<Double>(0.5, 0.5)
        var legTargetCenter = SIMD2<Double>(0.5, 0.5)
        var legPivot = SIMD2<Double>(0.5, 0.5)
        var legS0 = 1.0, legS1 = 1.0
        var legPanOnly = false
        var legStartTime = 0.0, legRiseT = 0.4, legReaimT = 0.4
        var legV0 = SIMD2<Double>.zero, legA0 = SIMD2<Double>.zero
        var legScaleV0 = 0.0
        var panAccelPrev = SIMD2<Double>.zero
        // A sub-pixel velocity-offset spring carries the incoming pan velocity
        // across a leg boundary. The pivot relation stays exact apart from this
        // decaying offset, so continuity no longer needs a hard stop.
        var panOff = SIMD2<Double>.zero, panOffVel = SIMD2<Double>.zero
        let offOmega = 50.0
        for k in 0..<n {
            if (k & 1023) == 0, cancelled() { return nil }
            let activeIndex = activeAt[k]
            if activeIndex != activeScene {
                activeScene = activeIndex
                legStartLog = scaleSpring
                legStartCenter = SIMD2(panX, panY)
                legV0 = SIMD2(velX, velY)
                legA0 = .zero
                legScaleV0 = scaleVel
                panOff = .zero
                panOffVel = SIMD2(velX, velY)
                legStartTime = Double(k) / ctx.rate
                if activeIndex >= 0, activeIndex < baked.count {
                    let scene = baked[activeIndex]
                    let h = baker.holdTarget(activeIndex, k)
                    legTargetLog = min(scene.lz, ctx.maxLz)
                    // A focus outside the feasible box at the leg's smallest
                    // scale would be clamped mid-move then released when the
                    // box opens — a one-tick pan jerk. Aim only at a centre
                    // feasible for the entire leg. The binding constraint is
                    // the leg's END scale (the tightest box for a zoom-in), so
                    // clamp there: a centre feasible at the end is feasible at
                    // every earlier, wider box. Clamping at min() would use the
                    // start scale instead, whose full-frame box is the single
                    // point 0.5 — pinning the target to centre and collapsing
                    // the fixed-pivot relation the whole leg is built on.
                    let aimAtEnd = clampCenter(SIMD2(h.center.x, h.center.y),
                                               legTargetLog, k, ctx: ctx)
                    // Keep a sub-pixel inset from the feasibility boundary.
                    // A target exactly on the edge makes the release clamp
                    // switch on in a single tick (a visible jerk); a hair of
                    // margin keeps the whole leg strictly feasible. The margin
                    // is capped at 0.3 source px — well below the 0.75 px
                    // pixel-exact arrival tolerance — so the shot lands on the
                    // control the click aimed at, not ~3 px short of it.
                    let inset = min(1.5e-3, 0.3 / max(ctx.src.x, 1))
                    let zEnd = exp(max(legTargetLog, 0))
                    let box = ctx.crop(at: k)
                    let base = CropSpace.baseView(crop: box, aspect: ctx.aspect)
                    let hw = base.w / zEnd / (2 * box.w), hh = base.h / zEnd / (2 * box.h)
                    let mx = min(max(hw, 0), 0.5), my = min(max(hh, 0), 0.5)
                    legTargetCenter = mx + inset < 0.5 - inset
                        ? SIMD2(clamp(aimAtEnd.x, mx + inset, 1 - mx - inset),
                                clamp(aimAtEnd.y, my + inset, 1 - my - inset))
                        : aimAtEnd
                    // Reach the target slightly before the event so there is a
                    // real still window at arrival; 0.92 of the runway.
                    let runway = max(scene.event - legStartTime, 0.2)
                    legRiseT = max(0.85 * runway, 0.18)
                } else {
                    legTargetLog = 0
                    legTargetCenter = legStartCenter
                }
                legS0 = exp(legStartLog); legS1 = exp(legTargetLog)
                let rawPivot = abs(legS1 - legS0) > 0.02
                    ? (legTargetCenter * legS1 - legStartCenter * legS0) / (legS1 - legS0)
                    : legStartCenter
                legPivot = SIMD2(clamp(rawPivot.x, -2, 3), clamp(rawPivot.y, -2, 3))
                legPanOnly = abs(legS1 - legS0) < 0.02 ||
                    max(abs(legPivot.x - legStartCenter.x), abs(legPivot.y - legStartCenter.y)) > 0.4
                // A pure re-aim has no scale runway to inherit; give it its own
                // duration that grows with the distance (quintic jerk ~ d/T³).
                let rd = max(abs(legTargetCenter.x - legStartCenter.x),
                             abs(legTargetCenter.y - legStartCenter.y))
                legReaimT = max(legRiseT, 0.35, pow(max(rd, 1e-4), 1.0 / 3.0) * 0.6)
            }
            let sel = tickTargets(baker, activeAt: activeAt, k: k,
                                  scaleSpring: scaleSpring,
                                  lastCenter: lastCenter)
            let lzTarget = sel.lzTarget, cxTarget = sel.cx, cyTarget = sel.cy
            // Size each spring by the distance it must actually travel, not by
            // the shot's nominal amplitude: a bridged shot can hand the camera
            // a smaller target than the scale it is currently showing. Without
            // this cap the per-tick step exceeds the 0.02 teleport gate.
            let omega = min(sel.omega, safeZoomOmega(abs(lzTarget - scaleSpring), rate: ctx.rate))
            let panOmega = min(sel.panOmega,
                               safeZoomOmega(max(abs(cxTarget - panX), abs(cyTarget - panY)), rate: ctx.rate))
            lastCenter = sel.lastCenter
            // A bridge keeps the previous leg active while `sel.cx` already
            // aims at the next shot — never mix those centres into this leg.
            let bridging = activeIndex < 0 && baker.mergedScene(k) != nil
            let onShot = activeIndex >= 0 && !bridging
            var panAccelX: Double? = nil, panAccelY: Double? = nil
            var legScaleAccel: Double? = nil
            if onShot, !legPanOnly, legTargetCenter.x.isFinite, legTargetCenter.y.isFinite {
                // s(t) = exp(lerp(ln s0, ln s1, E(t))) — bounded quintic ease,
                // monotone, zero velocity and acceleration at both endpoints.
                // Inherit a bounded share of the incoming dolly velocity so the
                // handoff is C1 rather than restarting from rest (the visible
                // "stop dead, then move" at a leg boundary), but cap it so the
                // quintic cannot dip far before turning around.
                let v0 = min(max(legScaleV0, -0.25), 0.25)
                let mv = QuinticMove(t0: legStartTime, T: legRiseT,
                                     x0: legStartLog, v0: v0, a0: 0,
                                     x1: legTargetLog)
                let sv = mv.sample(Double(k) / ctx.rate)
                scaleSpring = sv.x
                scaleVel = sv.v
                legScaleAccel = sv.a
                // Fixed pivot: p = (c1 s1 - c0 s0)/(s1 - s0), held for the
                // whole leg. c(t) = p - (p - c0) s0 / s(t) — no lateral swim.
                let s = exp(scaleSpring)
                let kf = legS0 / max(s, 1e-9)
                let a = legPivot - legStartCenter
                panX = legPivot.x - a.x * kf
                panY = legPivot.y - a.y * kf
                velX = a.x * kf * scaleVel
                velY = a.y * kf * scaleVel
                let kAcc = kf * ((legScaleAccel ?? 0) - scaleVel * scaleVel)
                let axOff = offOmega * offOmega * (0 - panOff.x) - 2 * offOmega * panOffVel.x
                let ayOff = offOmega * offOmega * (0 - panOff.y) - 2 * offOmega * panOffVel.y
                springStep(&panOff.x, &panOffVel.x, target: 0, omega: offOmega, dt: ctx.dt)
                springStep(&panOff.y, &panOffVel.y, target: 0, omega: offOmega, dt: ctx.dt)
                panX += panOff.x; panY += panOff.y
                velX += panOffVel.x; velY += panOffVel.y
                panAccelX = a.x * kAcc + axOff; panAccelY = a.y * kAcc + ayOff
            } else {
                springStep(&scaleSpring, &scaleVel, target: lzTarget, omega: omega, dt: ctx.dt)
                if onShot {
                    // Re-aim the pan on a C2 quintic, arriving at rest.
                    let moveX = QuinticMove(t0: legStartTime, T: legReaimT,
                                            x0: legStartCenter.x, v0: legV0.x, a0: legA0.x,
                                            x1: legTargetCenter.x)
                    let moveY = QuinticMove(t0: legStartTime, T: legReaimT,
                                            x0: legStartCenter.y, v0: legV0.y, a0: legA0.y,
                                            x1: legTargetCenter.y)
                    // Sample at the END of the tick, not its start. A leg begins
                    // at legStartTime, so at the leg's first tick u = 0 and the
                    // quintic would hold the pan perfectly still for one tick
                    // while the previous tick was still moving — a one-tick
                    // velocity notch that the jerk bound reads as a spike.
                    let sx = moveX.sample(Double(k) / ctx.rate + ctx.dt)
                    let sy = moveY.sample(Double(k) / ctx.rate + ctx.dt)
                    panX = sx.x; panY = sy.x
                    velX = sx.v; velY = sy.v
                    panAccelX = sx.a; panAccelY = sy.a
                } else {
                    springStep(&panX, &velX, target: cxTarget, omega: panOmega, dt: ctx.dt)
                    springStep(&panY, &velY, target: cyTarget, omega: panOmega, dt: ctx.dt)
                }
            }
            // Quiescence snap: a channel within float-exact distance of target
            // (lz < 2e-4, pan < 1e-4, |v| < 5e-3) is pinned — holds stay stable and
            // arrivals land by construction; the jump is invisible and monotone.
            // A 5e-4 log snap is a 0.05% scale change (invisible) but lands the
            // arrival ~50 ms earlier, so an auto shot is settled >=40 ms before
            // the click it anticipates.
            // Land exactly on target early enough to leave a real still window
            // before the event, even for a fast (snappy) ease whose spring is
            // still moving ~0.08/s at that point.
            let pivotLeg = onShot && !legPanOnly
            if !pivotLeg {
                if abs(scaleSpring - lzTarget) < 5e-4 && abs(scaleVel) < 1e-2 {
                    scaleSpring = lzTarget; scaleVel = 0
                }
                if abs(panX - cxTarget) < 1e-4 && abs(velX) < 5e-3 {
                    panX = cxTarget; velX = 0; panAccelX = nil
                }
                if abs(panY - cyTarget) < 1e-4 && abs(velY) < 5e-3 { panY = cyTarget; velY = 0; panAccelY = nil }
            }
            // The clamp can only move the position sideways to the boundary;
            // the spring keeps its state so there is never a velocity step.
            let clamped = clampCenter(SIMD2(panX, panY), max(scaleSpring, 0), k, ctx: ctx)
            panX = clamped.x; panY = clamped.y
            let lz = clamp(scaleSpring, 0, ctx.maxLz)
            let ax = legScaleAccel ?? (omega * omega * (lzTarget - scaleSpring) - 2 * omega * scaleVel)
            let px = panAccelX ?? (panOmega * panOmega * (cxTarget - panX) - 2 * panOmega * velX)
            let py = panAccelY ?? (panOmega * panOmega * (cyTarget - panY) - 2 * panOmega * velY)
            track.lz[k] = Float(lz); track.nx[k] = Float(panX); track.ny[k] = Float(panY)
            track.vz[k] = Float(scaleVel); track.vx[k] = Float(velX); track.vy[k] = Float(velY)
            track.az[k] = Float(ax); track.ax[k] = Float(px); track.ay[k] = Float(py)
            panAccelPrev = SIMD2(Double(px), Double(py))
        }
        return track
    }

    /// One causal critically damped pass (zero-phase lives in Planner).
    private static func causalSpring(_ input: [Double], omega: Double, dt: Double) -> [Double] {
        guard input.count > 1, omega.isFinite, omega > 0, dt > 0 else { return input }
        var output = [Double](repeating: 0, count: input.count)
        var x = input[0], velocity = 0.0
        for i in input.indices {
            springStep(&x, &velocity, target: input[i], omega: omega, dt: dt)
            output[i] = x
        }
        return output
    }
}
