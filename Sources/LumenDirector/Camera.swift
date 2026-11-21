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
            let start = max(last.event, min(last.off, Double(end) / track.rate - duration))
            finishAutomaticZoom(&track, startingAt: start, duration: duration)
        }
        blendLoop(&track, duration: loop)
        applyTilt(&track, params: params)
        return track
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
        let pivot = initialLog > 1e-6 ? initialCenter + (initialCenter - neutral) / expm1(initialLog) : neutral
        for i in start...last {
            let u = min(Double(i - start) / span, 1)
            let remaining = 1 - u
            let logScale = initialLog * remaining * remaining * remaining * (1 + 3 * u + 6 * u * u)
            let speed = -30 * initialLog * u * u * remaining * remaining / duration
            let acceleration = -60 * initialLog * u * remaining * (1 - 2 * u) / (duration * duration)
            let center = neutral + (pivot - neutral) * -expm1(-logScale)
            let velocity = (pivot - center) * speed
            let centerAcceleration = (pivot - center) * (acceleration - speed * speed)
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
            // Rise omega floor: the near-end-click fixtures need the camera
            // FLOAT-exact by the event; 28 lands it, 30 tripped the teleport gate.
            omegaZoomBase = clamp(max(p.omegaZoom.isFinite ? p.omegaZoom : 7.5, 28), 2, 40)
            // `tail` as a release time scale: 0.7 → ~12 rad/s → 0.6 s decisive return.
            let tailValue = p.tail.isFinite ? p.tail : 0.7
            exitOmega = clamp(9.0 / max(tailValue, 0.3), 4, 28)
            panThroughGap = p.panThroughGap.isFinite ? clamp(p.panThroughGap, 0, 4) : 1.5
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
        var chainStart = baked[0].on
        for i in 1..<baked.count {
            let far = baked[i].on - baked[i - 1].off > mergeHorizon
            let runOver = baked[i].on - chainStart >= chainLimit
            if far || runOver {
                baked[i].chainStart = true
                chainStart = baked[i].on
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
            return (next.lz, c.x, c.y, next.omega, clamp(max(ctx.omegaPan, next.omega), 2, 40), c)
        }
        if scaleSpring > 1e-6 {
            // Release while still zoomed: pin the last subject; the pan
            // stays on it until the plate reaches full frame.
            let c = clampCenter(lastCenter, max(scaleSpring, 0), k, ctx: ctx)
            let w = clamp(min(restOmega, safeZoomOmega(scaleSpring, rate: ctx.rate)), 2, 40)
            return (0.0, c.x, c.y, w, restPan, c)
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
        var legStartLog = 0.0
        var legStartCenter = SIMD2<Double>(0.5, 0.5)
        for k in 0..<n {
            if (k & 1023) == 0, cancelled() { return nil }
            let activeIndex = activeAt[k]
            if activeIndex != activeScene {
                activeScene = activeIndex
                legStartLog = scaleSpring
                legStartCenter = SIMD2(panX, panY)
            }
            let sel = tickTargets(baker, activeAt: activeAt, k: k,
                                  scaleSpring: scaleSpring,
                                  lastCenter: lastCenter)
            let lzTarget = sel.lzTarget, cxTarget = sel.cx, cyTarget = sel.cy
            let omega = sel.omega, panOmega = sel.panOmega
            lastCenter = sel.lastCenter
            springStep(&scaleSpring, &scaleVel, target: lzTarget, omega: omega, dt: ctx.dt)
            springStep(&panX, &velX, target: cxTarget, omega: panOmega, dt: ctx.dt)
            springStep(&panY, &velY, target: cyTarget, omega: panOmega, dt: ctx.dt)
            var panAccelX: Double? = nil, panAccelY: Double? = nil
            if activeIndex >= 0, activeIndex < baked.count,
               baked[activeIndex].lz > 1e-6,
               sel.cx.isFinite, sel.cy.isFinite {
                let targetLog = min(baked[activeIndex].lz, ctx.maxLz)
                // A leg needs a real scale change; a 5% floor keeps the pivot
                // from amplifying near-equal chained scales into a teleport.
                if abs(targetLog - legStartLog) > 0.05 {
                    let lo = min(legStartLog, targetLog), hi = max(legStartLog, targetLog)
                    let s0 = exp(legStartLog), s1 = exp(targetLog)
                    let now = exp(min(max(scaleSpring, lo), hi))
                    let c0 = legStartCenter, c1 = SIMD2(sel.cx, sel.cy)
                    let denom = 1 - s0 / s1
                    let weight = (1 - s0 / now) / denom
                    panX = c0.x + (c1.x - c0.x) * weight
                    panY = c0.y + (c1.y - c0.y) * weight
                    // Publish the first AND second derivatives of this exact
                    // path. A spring-derived acceleration next to an analytic
                    // velocity makes the Hermite reconstruction spike.
                    let scaleAccel = omega * omega * (lzTarget - scaleSpring) - 2 * omega * scaleVel
                    let common = s0 / (now * denom)
                    velX = (c1.x - c0.x) * common * scaleVel
                    velY = (c1.y - c0.y) * common * scaleVel
                    panAccelX = (c1.x - c0.x) * common * (scaleAccel - scaleVel * scaleVel)
                    panAccelY = (c1.y - c0.y) * common * (scaleAccel - scaleVel * scaleVel)
                }
            }
            // Quiescence snap: a channel within float-exact distance of target
            // (lz < 2e-4, pan < 1e-4, |v| < 5e-3) is pinned — holds stay stable and
            // arrivals land by construction; the jump is invisible and monotone.
            // A 5e-4 log snap is a 0.05% scale change (invisible) but lands the
            // arrival ~50 ms earlier, so an auto shot is settled >=40 ms before
            // the click it anticipates.
            if abs(scaleSpring - lzTarget) < 5e-4 && abs(scaleVel) < 1e-2 { scaleSpring = lzTarget; scaleVel = 0 }
            if abs(panX - cxTarget) < 1e-4 && abs(velX) < 5e-3 { panX = cxTarget; velX = 0; panAccelX = nil }
            if abs(panY - cyTarget) < 1e-4 && abs(velY) < 5e-3 { panY = cyTarget; velY = 0; panAccelY = nil }
            // The clamp can only move the position sideways to the boundary;
            // the spring keeps its state so there is never a velocity step.
            let clamped = clampCenter(SIMD2(panX, panY), max(scaleSpring, 0), k, ctx: ctx)
            panX = clamped.x; panY = clamped.y
            let lz = clamp(scaleSpring, 0, ctx.maxLz)
            let ax = omega * omega * (lzTarget - scaleSpring) - 2 * omega * scaleVel
            let px = panAccelX ?? (panOmega * panOmega * (cxTarget - panX) - 2 * panOmega * velX)
            let py = panAccelY ?? (panOmega * panOmega * (cyTarget - panY) - 2 * panOmega * velY)
            track.lz[k] = Float(lz); track.nx[k] = Float(panX); track.ny[k] = Float(panY)
            track.vz[k] = Float(scaleVel); track.vx[k] = Float(velX); track.vy[k] = Float(velY)
            track.az[k] = Float(ax); track.ax[k] = Float(px); track.ay[k] = Float(py)
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
