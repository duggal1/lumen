import Foundation
import LumenCore
import LumenProject

enum CameraSolver {
    private struct Shot {
        var start: Double
        var off: Double
        var logScale: Double
        var focus: Focus
        var ease: Double
        var isAuto: Bool
        /// SMOOTHNESS: continuous camera target path (source seconds, output
        /// time, normalized centre). The camera follows it instead of being
        /// retargeted every few hundred milliseconds.
        var path: [(t: Double, c: SIMD2<Double>)] = []
        /// The path continues the previous segment's: the camera is already
        /// following it, so the pan hands over without a jump.
        var pathContinues = false
    }

    private struct Move {
        var start: Double
        var duration: Double
        var logScale: Double
        var pan: SIMD2<Double>
        var endVelocity = SIMD2<Double>.zero
        var endAcceleration = SIMD2<Double>.zero
        var followUntil: Double? = nil
        var path: [(t: Double, c: SIMD2<Double>)] = []
        var pathContinues = false
    }

    private struct Channel {
        var move: QuinticMove

        init(_ value: Double) {
            move = QuinticMove(t0: 0, T: 1, x0: value, v0: 0, a0: 0, x1: value)
        }

        mutating func retarget(at time: Double, to target: Double, duration: Double,
                               start: (x: Double, v: Double, a: Double)? = nil,
                               endVelocity: Double = 0, endAcceleration: Double = 0) {
            let state = start ?? move.sample(time)
            move = QuinticMove(t0: time, T: duration, x0: state.x, v0: state.v, a0: state.a,
                               x1: target, v1: endVelocity, a1: endAcceleration)
        }
    }

    /// Forward and backward dead-zone tracking. The average does not bias
    /// the target toward where the pointer came from.
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
                      src: SIMD2<Double>, outDur: Double, loop: Double?) -> CameraTrack {
        solve(zoom: zoom, tm: tm, cursor: cursor, p: p, src: src, outDur: outDur, loop: loop, cancelled: { false })
            ?? CameraTrack(count: 2, rate: 240)
    }

    /// SMOOTHNESS: cancellable variant. The solve is the longest stage of a
    /// derive; a cancelled edit must be able to abandon it instead of
    /// blocking the next one.
    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams,
                      src: SIMD2<Double>, outDur: Double, loop: Double?, cancelled: () -> Bool) -> CameraTrack? {
        solve(zoom: zoom, tm: tm, cursor: cursor, p: p, src: src, outDur: outDur, loop: loop,
              follow: [:], followContinues: [:], cancelled: cancelled)
    }

    /// SMOOTHNESS: `follow` carries the continuous camera target paths (the
    /// caret path of a typing scene). The camera glides along them instead of
    /// being retargeted — and the scene split — every few hundred milliseconds.
    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams,
                      src: SIMD2<Double>, outDur: Double, loop: Double?,
                      follow: [UUID: [(t: Double, c: SIMD2<Double>)]],
                      followContinues: [UUID: Bool] = [:], cancelled: () -> Bool) -> CameraTrack? {
        _ = loop
        let rate = 240.0
        guard outDur.isFinite, outDur > 0, src.x.isFinite, src.y.isFinite, src.x > 0, src.y > 0 else {
            return CameraTrack(count: 2, rate: rate)
        }
        let dt = 1 / rate
        let n = max(Int(outDur * rate) + 1, 2)
        var track = CameraTrack(count: n, rate: rate)
        let rest = SIMD2<Double>(repeating: 0.5)

        func index(_ time: Double) -> Int {
            min(max(Int((time * rate).rounded()), 0), n - 1)
        }
        func isFollow(_ focus: Focus) -> Bool {
            if case .follow = focus { return true }
            return false
        }

        let shots: [Shot] = zoom.compactMap { segment in
            let start = tm.output(atSource: segment.start)
            let off = tm.output(atSource: segment.end)
            guard start.isFinite, off.isFinite, off - start > 0.02,
                  segment.scale.isFinite, segment.scale > 1.001, start < outDur else { return nil }
            let rawEase = segment.easing?.omegaScale ?? 1
            let ease = max(rawEase.isFinite ? rawEase : 1, 0.2)
            let logScale = log(min(segment.scale, 16))
            // SMOOTHNESS: the caret path of a typing scene becomes a
            // continuous camera target, in output time and with the same
            // centre offset the fixed focus uses.
            var path: [(t: Double, c: SIMD2<Double>)] = []
            var pathContinues = false
            if let points = follow[segment.id], !points.isEmpty {
                let offset = SIMD2(clamp(p.centerOffsetX, -0.25, 0.25), clamp(p.centerOffsetY, -0.25, 0.25))
                let shift = offset * exp(-logScale)
                path = points.compactMap { point in
                    let out = tm.output(atSource: point.t)
                    guard out.isFinite, point.c.x.isFinite, point.c.y.isFinite else { return nil }
                    return (out, point.c - shift)
                }
                path.sort { $0.0 < $1.0 }
                pathContinues = followContinues[segment.id] ?? false
            }
            return Shot(start: start, off: off, logScale: logScale, focus: segment.focus, ease: ease,
                        isAuto: segment.origin == .auto, path: path, pathContinues: pathContinues)
        }.sorted { $0.start < $1.start }

        let hasFollow = shots.contains { isFollow($0.focus) }
        var followX = [Double](repeating: 0.5, count: n)
        var followY = followX
        let cursorCount = min(cursor.x.count, cursor.y.count)
        if hasFollow, cursorCount > 0 {
            let halfZone = clamp(p.deadZone.isFinite ? p.deadZone : 0.28, 0.05, 0.45) / 2
            let followOmega = 1 / max(clamp(p.followDelay.isFinite ? p.followDelay : 0.12, 0, 0.5), 0.045)
            let rawX = (0..<n).map { i in
                let cursorIndex = min(Int(Double(i) * gridRate / rate), cursorCount - 1)
                return Double(cursor.x[cursorIndex]) / src.x
            }
            let rawY = (0..<n).map { i in
                let cursorIndex = min(Int(Double(i) * gridRate / rate), cursorCount - 1)
                return Double(cursor.y[cursorIndex]) / src.y
            }
            followX = zeroPhaseSmooth(centredPlay(rawX, halfZone: halfZone), omega: followOmega, dt: dt)
            followY = zeroPhaseSmooth(centredPlay(rawY, halfZone: halfZone), omega: followOmega, dt: dt)
        }

        func targetCenter(_ shot: Shot, at sample: Int) -> SIMD2<Double> {
            var center: SIMD2<Double>
            switch shot.focus {
            case .fixed(let x, let y): center = SIMD2(x, y)
            case .element(let x, let y, let width, let height): center = SIMD2(x + width / 2, y + height / 2)
            case .follow: center = SIMD2(followX[sample], followY[sample])
            }
            let offset = SIMD2(clamp(p.centerOffsetX, -0.25, 0.25), clamp(p.centerOffsetY, -0.25, 0.25))
            center -= offset * exp(-shot.logScale)
            let half = 0.5 / exp(shot.logScale)
            return SIMD2(clamp(center.x, half, 1 - half), clamp(center.y, half, 1 - half))
        }

        func panCoordinate(for center: SIMD2<Double>, logScale: Double) -> SIMD2<Double> {
            panPosition(center: center, logScale: logScale)
        }

        // MARK: Continuous path sampling

        /// Position, velocity and acceleration of a cubic Hermite through a
        /// (time, value) path. C1 at the knots (position and velocity match),
        /// with bounded acceleration — enough for a camera target that was
        /// already smoothed by the planner, and it never invents a stop.
        func scalarState(_ values: [Double], at time: Double) -> (x: Double, v: Double, a: Double) {
            guard values.count > 1 else { return (values.first ?? 0.5, 0, 0) }
            let lastTime = Double(values.count - 1) * dt
            let t = clamp(time, 0, lastTime)
            let f = t * rate
            let lo = min(Int(f), values.count - 2)
            let span = dt
            let u = clamp((t - Double(lo) * dt) / span, 0, 1)
            func tangent(_ i: Int) -> Double {
                if i <= 0 { return (values[1] - values[0]) * rate }
                if i >= values.count - 1 { return (values[values.count - 1] - values[values.count - 2]) * rate }
                return (values[i + 1] - values[i - 1]) * rate / 2
            }
            let m0 = tangent(lo) * span, m1 = tangent(lo + 1) * span
            let p0 = values[lo], p1 = values[lo + 1]
            let u2 = u * u, u3 = u2 * u
            let h00 = 2 * u3 - 3 * u2 + 1, h10 = u3 - 2 * u2 + u, h01 = -2 * u3 + 3 * u2, h11 = u3 - u2
            let x = p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11
            let dh00 = (6 * u2 - 6 * u) / span, dh10 = (3 * u2 - 4 * u + 1) / span
            let dh01 = (-6 * u2 + 6 * u) / span, dh11 = (3 * u2 - 2 * u) / span
            let v = p0 * dh00 + m0 * dh10 + p1 * dh01 + m1 * dh11
            let s2 = span * span
            let ddh00 = (12 * u - 6) / s2, ddh10 = (6 * u - 4) / s2, ddh01 = (-12 * u + 6) / s2, ddh11 = (6 * u - 2) / s2
            let a = p0 * ddh00 + m0 * ddh10 + p1 * ddh01 + m1 * ddh11
            return (x, v, a)
        }

        /// Position, velocity and acceleration of a continuous target path at
        /// an output time. The path is a polyline of (time, normalized centre);
        /// a cubic Hermite keeps the camera moving through the knots instead of
        /// stopping at every target.
        func pathState(_ path: [(t: Double, c: SIMD2<Double>)], at time: Double) -> (c: SIMD2<Double>, v: SIMD2<Double>, a: SIMD2<Double>) {
            guard let first = path.first else { return (SIMD2<Double>(repeating: 0.5), .zero, .zero) }
            guard path.count > 1 else { return (first.c, .zero, .zero) }
            let last = path[path.count - 1]
            if time <= first.t { return (first.c, .zero, .zero) }
            if time >= last.t { return (last.c, .zero, .zero) }
            var lo = 0, hi = path.count - 1
            while lo + 1 < hi {
                let mid = (lo + hi) / 2
                if path[mid].t <= time { lo = mid } else { hi = mid }
            }
            let p0 = path[lo], p1 = path[lo + 1]
            let span = p1.t - p0.t
            guard span > 1e-9 else { return (p1.c, .zero, .zero) }
            let u = clamp((time - p0.t) / span, 0, 1)
            func tangent(_ i: Int) -> SIMD2<Double> {
                if i <= 0 { return (path[1].c - path[0].c) / max(path[1].t - path[0].t, 1e-9) }
                if i >= path.count - 1 { return (path[path.count - 1].c - path[path.count - 2].c) / max(path[path.count - 1].t - path[path.count - 2].t, 1e-9) }
                return (path[i + 1].c - path[i - 1].c) / max(path[i + 1].t - path[i - 1].t, 1e-9)
            }
            let m0 = tangent(lo) * span, m1 = tangent(lo + 1) * span
            let u2 = u * u, u3 = u2 * u
            let h00 = 2 * u3 - 3 * u2 + 1, h10 = u3 - 2 * u2 + u, h01 = -2 * u3 + 3 * u2, h11 = u3 - u2
            let c = p0.c * h00 + m0 * h10 + p1.c * h01 + m1 * h11
            let dh00 = (6 * u2 - 6 * u) / span, dh10 = (3 * u2 - 4 * u + 1) / span
            let dh01 = (-6 * u2 + 6 * u) / span, dh11 = (3 * u2 - 2 * u) / span
            let v = p0.c * dh00 + m0 * dh10 + p1.c * dh01 + m1 * dh11
            let s2 = span * span
            let ddh00 = (12 * u - 6) / s2, ddh10 = (6 * u - 4) / s2, ddh01 = (-12 * u + 6) / s2, ddh11 = (6 * u - 2) / s2
            let a = p0.c * ddh00 + m0 * ddh10 + p1.c * ddh01 + m1 * ddh11
            return (c, v, a)
        }

        // MARK: Moves

        // Tuning policy (Docs/ZOOM-MOTION-PLAN.md): a typical 1.5–2x zoom-in
        // reviews at 550 ms, a zoom-out at 750 ms, and an ordinary nearby
        // reframe at 350 ms. The segment's own easing scales these, and a
        // modest distance term stays inside the measured bounds. `omegaZoom`
        // is a physical spring frequency (the live camera), not a duration.
        let zoomInBase = 0.55, zoomOutBase = 0.75, reframeBase = 0.35

        var moves: [Move] = []
        var previousLogScale = 0.0
        var previousCenter = rest
        var lastStart = -Double.infinity
        var previousIntentTime: Double?

        for shot in shots {
            let estimate = shot.path.first?.c ?? targetCenter(shot, at: index(shot.start))
            let scaleChange = abs(shot.logScale - previousLogScale)
            let panDistance = hypot(estimate.x - previousCenter.x, estimate.y - previousCenter.y)
                * exp(max(shot.logScale, previousLogScale))
            let reframe = scaleChange <= 0.03
            let base = reframe ? reframeBase : zoomInBase
            let distanceGrow = 1 + clamp(panDistance, 0, 1.5) * 0.18
            let duration = clamp(base / shot.ease * distanceGrow, 0.22, 0.95)
            let earliestStart = max(lastStart + 1 / rate, (previousIntentTime ?? -Double.infinity) + 1 / rate)
            let nominalStart = shot.isAuto
                ? shot.start - max(p.leadIn.isFinite ? p.leadIn : 0.6, duration)
                : shot.start
            let start = max(nominalStart, earliestStart, 0)
            let end = start + duration
            // Pan and scale share the one transition interval, so the camera
            // never zooms first and drags the subject in afterwards.
            let endCenter: SIMD2<Double>
            if !shot.path.isEmpty {
                endCenter = pathState(shot.path, at: end).c
            } else {
                endCenter = targetCenter(shot, at: index(end))
            }
            let endPan = panCoordinate(for: endCenter, logScale: shot.logScale)
            var endVelocity = SIMD2<Double>.zero
            var endAcceleration = SIMD2<Double>.zero
            if isFollow(shot.focus) {
                let margin = max(panMargin(logScale: shot.logScale), 1e-8)
                let x = scalarState(followX, at: end), y = scalarState(followY, at: end)
                endVelocity = SIMD2(x.v / margin, y.v / margin)
                endAcceleration = SIMD2(x.a / margin, y.a / margin)
            } else if !shot.path.isEmpty {
                // Hand the follow over from the caret path with the caret's
                // own velocity and acceleration, not a fresh rest.
                let margin = max(panMargin(logScale: shot.logScale), 1e-8)
                let state = pathState(shot.path, at: end)
                endVelocity = state.v / margin
                endAcceleration = state.a / margin
            }
            moves.append(Move(start: start, duration: duration, logScale: shot.logScale, pan: endPan,
                              endVelocity: endVelocity, endAcceleration: endAcceleration,
                              followUntil: (isFollow(shot.focus) || !shot.path.isEmpty) ? shot.off : nil,
                              path: shot.path, pathContinues: shot.pathContinues))
            lastStart = start
            previousIntentTime = shot.start
            previousLogScale = shot.logScale
            previousCenter = endCenter
        }

        // Zoom-out: one finite curve back to full frame. Skipped when the next
        // scene's move already begins at or before this scene ends (a related
        // action makes staying zoomed more useful than a flash to full frame).
        let entranceCount = moves.count
        for (index, shot) in shots.enumerated() {
            if index + 1 < entranceCount, moves[index + 1].start <= shot.off + 1e-3 { continue }
            moves.append(Move(start: shot.off, duration: zoomOutBase / shot.ease, logScale: 0, pan: .zero))
        }
        moves.sort { $0.start < $1.start }

        // MARK: Sample the generated trajectory

        var logScale = Channel(0)
        var panX = Channel(0), panY = Channel(0)
        var centersX = [Double](repeating: 0.5, count: n)
        var centersY = centersX
        var scales = [Double](repeating: 0, count: n)
        var velX = [Double](repeating: 0, count: n), velY = velX, velZ = velX
        var accX = [Double](repeating: 0, count: n), accY = accX, accZ = accX
        var moveIndex = 0
        var followMove: Move?

        for sample in 0..<n {
            // SMOOTHNESS: a cancelled derive abandons the solve here instead
            // of running the whole grid to completion.
            if sample % 4096 == 0, cancelled() { return nil }
            let time = Double(sample) * dt

            while moveIndex < moves.count, moves[moveIndex].start <= time {
                let move = moves[moveIndex]
                moveIndex += 1
                var startX: (x: Double, v: Double, a: Double)?
                var startY: (x: Double, v: Double, a: Double)?
                // Seed the next move from the ACTUAL displayed trajectory at
                // the handoff, not from a stale channel or the raw target path.
                // Before the follow has taken over the entrance quintic owns
                // the pan, so the channel state is already the displayed one.
                if let current = followMove {
                    if move.start >= current.start + current.duration {
                        if !current.path.isEmpty {
                            let state = pathState(current.path, at: move.start)
                            let m = max(panMargin(logScale: current.logScale), 1e-8)
                            startX = (x: panCoordinate(for: SIMD2(state.c.x, 0.5), logScale: current.logScale).x,
                                      v: state.v.x / m, a: state.a.x / m)
                            startY = (x: panCoordinate(for: SIMD2(0.5, state.c.y), logScale: current.logScale).y,
                                      v: state.v.y / m, a: state.a.y / m)
                        } else if current.followUntil != nil {
                            let x = scalarState(followX, at: move.start), y = scalarState(followY, at: move.start)
                            let m = max(panMargin(logScale: current.logScale), 1e-8)
                            startX = (x: panCoordinate(for: SIMD2(x.x, 0.5), logScale: current.logScale).x, v: x.v / m, a: x.a / m)
                            startY = (x: panCoordinate(for: SIMD2(0.5, y.x), logScale: current.logScale).y, v: y.v / m, a: y.a / m)
                        }
                    }
                    followMove = nil
                }
                logScale.retarget(at: move.start, to: move.logScale, duration: move.duration)
                panX.retarget(at: move.start, to: move.pan.x, duration: move.duration, start: startX,
                              endVelocity: move.endVelocity.x, endAcceleration: move.endAcceleration.x)
                panY.retarget(at: move.start, to: move.pan.y, duration: move.duration, start: startY,
                              endVelocity: move.endVelocity.y, endAcceleration: move.endAcceleration.y)
                followMove = move.followUntil == nil ? nil : move
            }

            var lzState = logScale.move.sample(time)
            var panXState = panX.move.sample(time)
            var panYState = panY.move.sample(time)

            // The follow path drives the pan directly once the entrance has
            // arrived. There is no downstream follower easing it a second time.
            if let current = followMove, let until = current.followUntil,
               time >= current.start + current.duration, time < until {
                if !current.path.isEmpty {
                    let state = pathState(current.path, at: time)
                    let m = max(panMargin(logScale: max(lzState.x, 0)), 1e-8)
                    panXState = (x: panCoordinate(for: SIMD2(state.c.x, 0.5), logScale: max(lzState.x, 0)).x,
                                 v: state.v.x / m, a: state.a.x / m)
                    panYState = (x: panCoordinate(for: SIMD2(0.5, state.c.y), logScale: max(lzState.x, 0)).y,
                                 v: state.v.y / m, a: state.a.y / m)
                } else {
                    let i = min(max(sample, 1), n - 2)
                    let m = max(panMargin(logScale: max(lzState.x, 0)), 1e-8)
                    let x = (followX[i], (followX[i + 1] - followX[i - 1]) * rate / 2,
                             (followX[i + 1] - 2 * followX[i] + followX[i - 1]) * rate * rate)
                    let y = (followY[i], (followY[i + 1] - followY[i - 1]) * rate / 2,
                             (followY[i + 1] - 2 * followY[i] + followY[i - 1]) * rate * rate)
                    panXState = (x: panCoordinate(for: SIMD2(x.0, 0.5), logScale: max(lzState.x, 0)).x, v: x.1 / m, a: x.2 / m)
                    panYState = (x: panCoordinate(for: SIMD2(0.5, y.0), logScale: max(lzState.x, 0)).y, v: y.1 / m, a: y.2 / m)
                }
            }

            // Log-scale is clamped at 1x: a clamped axis has no rate.
            let lz = max(lzState.x, 0)
            if lzState.x <= 0 { lzState.v = 0; lzState.a = 0 }

            // Pan is clamped to the legal range; a clamped axis has no rate.
            var px = clamp(panXState.x, -1, 1), py = clamp(panYState.x, -1, 1)
            var pvx = panXState.v, pvy = panYState.v
            var pax = panXState.a, pay = panYState.a
            if px != panXState.x { pvx = 0; pax = 0 }
            if py != panYState.x { pvy = 0; pay = 0 }

            // Centre = 0.5 + pan · margin(lz). Differentiate the product so
            // the stored velocity and acceleration belong to the centre the
            // evaluator actually displays.
            let e = exp(-lz)
            let m = 0.5 - 0.5 * e
            let m1 = 0.5 * e
            let m2 = -0.5 * e
            let cx = 0.5 + px * m, cy = 0.5 + py * m
            let vcx = pvx * m + px * m1 * lzState.v
            let vcy = pvy * m + py * m1 * lzState.v
            let acx = pax * m + 2 * pvx * m1 * lzState.v + px * (m2 * lzState.v * lzState.v + m1 * lzState.a)
            let acy = pay * m + 2 * pvy * m1 * lzState.v + py * (m2 * lzState.v * lzState.v + m1 * lzState.a)

            centersX[sample] = cx
            centersY[sample] = cy
            scales[sample] = lz
            velX[sample] = vcx; velY[sample] = vcy; velZ[sample] = lzState.v
            accX[sample] = acx; accY[sample] = acy; accZ[sample] = lzState.a
        }

        track.nx = centersX.map(Float.init)
        track.ny = centersY.map(Float.init)
        track.lz = scales.map(Float.init)
        track.vx = velX.map(Float.init)
        track.vy = velY.map(Float.init)
        track.vz = velZ.map(Float.init)
        track.ax = accX.map(Float.init)
        track.ay = accY.map(Float.init)
        track.az = accZ.map(Float.init)

        var yaw = p.tilt == .reveal ? 12.0 : 0.0, yawVelocity = 0.0
        var pitch = 0.0, pitchVelocity = 0.0
        func phase(_ channel: Int) -> Double {
            Double((p.tiltSeed >> UInt64(channel * 8)) & 255) / 255 * 2 * .pi
        }
        for sample in 0..<n {
            let time = Double(sample) * dt
            let scale = exp(scales[sample])
            var yawTarget = 0.0, pitchTarget = 0.0
            switch p.tilt {
            case .lean:
                yawTarget = clamp(Double(track.vx[sample]) * scale * 12, -p.maxYaw, p.maxYaw)
                pitchTarget = clamp(-Double(track.vy[sample]) * scale * 9, -p.maxPitch, p.maxPitch)
            case .float:
                yawTarget = p.floatDeg * (0.6 * sin(2 * .pi * 0.11 * time + phase(0)) + 0.4 * sin(2 * .pi * 0.07 * time + phase(1)))
                pitchTarget = p.floatDeg * (0.6 * sin(2 * .pi * 0.09 * time + phase(2)) + 0.4 * sin(2 * .pi * 0.05 * time + phase(3)))
            case .reveal, .off: break
            }
            springStep(&yaw, &yawVelocity, target: yawTarget, omega: p.omegaTilt, dt: dt)
            springStep(&pitch, &pitchVelocity, target: pitchTarget, omega: p.omegaTilt, dt: dt)
            track.yaw[sample] = Float(yaw)
            track.pitch[sample] = Float(pitch)
        }
        return track
    }
}