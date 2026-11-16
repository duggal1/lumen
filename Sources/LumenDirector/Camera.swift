import Foundation
import LumenCore
import LumenProject

/// Step targets in centre/log-scale space, interpolated with finite quintics.
///
/// The camera is built as a sequence of rest-to-rest quintic moves: 0 → target
/// over the lead-in, target through the hold, target → 0 over the tail. Every
/// move has zero velocity and acceleration at both ends, so the track is C2 and
/// reaches its target exactly. A bridge replaces the tail with a direct move to
/// the next scene, which is what removes the "double move" at a handoff.
enum CameraSolver {
    /// The camera is baked above the highest output rate so `qhm` always has
    /// headroom: 240 fps output still gets two camera samples per frame.
    static let cameraRate = 480.0

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
        solve(zoom: zoom, tm: tm, cursor: cursor, p: p, src: src, outDur: outDur, loop: loop,
              follow: [:], cancelled: { false }) ?? CameraTrack(count: 2, rate: cameraRate)
    }

    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams,
                      src: SIMD2<Double>, outDur: Double, loop: Double?, cancelled: () -> Bool) -> CameraTrack? {
        solve(zoom: zoom, tm: tm, cursor: cursor, p: p, src: src, outDur: outDur, loop: loop,
              follow: [:], cancelled: cancelled)
    }

    /// Follow paths use output seconds and source-normalised caret coordinates.
    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams,
                      src: SIMD2<Double>, outDur: Double, loop: Double?,
                      follow: [UUID: [(t: Double, c: SIMD2<Double>)]],
                      cancelled: () -> Bool) -> CameraTrack? {
        _ = loop
        let rate = cameraRate, dt = 1 / rate
        guard outDur.isFinite, outDur > 0, src.x.isFinite, src.y.isFinite, src.x > 0, src.y > 0 else {
            return CameraTrack(count: 2, rate: rate)
        }
        let n = max(Int(outDur * rate) + 1, 2)
        let leadBase = p.leadIn.isFinite ? clamp(p.leadIn, 0, 1.5) : 0.30
        let tout = max(p.tail.isFinite ? p.tail : 0.7, 0.25)
        let panGap = max(p.panThroughGap.isFinite ? p.panThroughGap : 1.5, 0.3)
        let look = clamp(p.lookahead.isFinite ? p.lookahead : 0.12, 0, 0.5)
        let offset = SIMD2(clamp(p.centerOffsetX, -0.25, 0.25), clamp(p.centerOffsetY, -0.25, 0.25))
        let omegaPan = max(p.omegaPan.isFinite ? p.omegaPan : 4, 1)

        struct Scene {
            var on: Double
            var event: Double
            var off: Double
            var lz: Double
            var center: SIMD2<Double>
            var segment: ZoomSegment
            var path: [(t: Double, c: SIMD2<Double>)]
        }

        /// Lead-in grows with magnification. A 1.2× move needs less runway than
        /// a 6× move; a constant 0.30 s is either late or early.
        func leadFor(_ lz: Double, _ ease: Double) -> Double {
            let magnitude = 0.22 + 0.16 * (lz / 0.6931471805599453)
            return clamp(max(leadBase, magnitude) / max(ease, 0.55), 0.20, 1.4)
        }
        func manualRise(_ ease: Double) -> Double { clamp(0.9 / max(ease, 0.3), 0.25, 2.0) }

        // Ordered by settle time, not by lead-in start. The camera holds one
        // target at a time and the track is written in a single forward pass,
        // so the pass must follow the order the shots actually land. Sorting by
        // `on` lets a later shot's lead-in begin before an earlier shot's
        // arrival, which reorders the pass and leaves a one-tick cut where the
        // two writes meet.
        let scenes: [Scene] = zoom.compactMap { z -> Scene? in
            let a = tm.output(atSource: z.start), b = tm.output(atSource: z.end)
            guard a.isFinite, b.isFinite, b - a > 0.02, z.scale.isFinite, z.scale > 1.001, a < outDur else { return nil }
            let ease: Double
            if let e = z.easing?.omegaScale, e.isFinite, e > 0 { ease = e } else { ease = 1 }
            let lz = log(min(z.scale, 16))
            let path = (follow[z.id] ?? [])
                .filter { $0.t.isFinite && $0.c.x.isFinite && $0.c.y.isFinite }
                .sorted { $0.t < $1.t }
            let center: SIMD2<Double>
            switch z.focus {
            case .fixed(let x, let y): center = SIMD2(x, y)
            case .element(let x, let y, let w, let h): center = SIMD2(x + w / 2, y + h / 2)
            case .follow: center = path.first.map { $0.c } ?? SIMD2(0.5, 0.5)
            }
            let on: Double, event: Double
            if z.origin == .auto {
                event = a
                on = max(a - leadFor(lz, ease), 0)
            } else {
                on = a
                event = min(a + manualRise(ease), max(b - 0.05, a + 0.05))
            }
            return Scene(on: on, event: event, off: max(b, event + 0.02), lz: lz,
                         center: center, segment: z, path: path)
        }.sorted { $0.event < $1.event }

        // Global cursor track for follow scenes that have no explicit path.
        // A scene with a recorded path is driven by `pathCenters` instead.
        let needsCursor = scenes.contains { scene in
            if case .follow = scene.segment.focus { return scene.path.count < 2 }
            return false
        }
        var followX = [Double](repeating: 0.5, count: n), followY = followX
        if needsCursor, cursor.x.count > 0 {
            let halfZone = clamp(p.deadZone.isFinite ? p.deadZone : 0.28, 0.05, 0.45) / 2
            let followOmega = 1 / max(clamp(p.followDelay.isFinite ? p.followDelay : 0.12, 0, 0.5), 0.045)
            let cx = min(cursor.x.count, cursor.y.count)
            let rawX = (0..<n).map { i in Double(cursor.x[min(Int(Double(i) * gridRate / rate), cx - 1)]) / src.x }
            let rawY = (0..<n).map { i in Double(cursor.y[min(Int(Double(i) * gridRate / rate), cx - 1)]) / src.y }
            followX = zeroPhaseSmooth(centredPlay(rawX, halfZone: halfZone), omega: followOmega, dt: dt)
            followY = zeroPhaseSmooth(centredPlay(rawY, halfZone: halfZone), omega: followOmega, dt: dt)
        }

        func clampCenter(_ c: SIMD2<Double>, _ lz: Double) -> SIMD2<Double> {
            let h = 0.5 / exp(max(lz, 0))
            return SIMD2(clamp(c.x, h, 1 - h), clamp(c.y, h, 1 - h))
        }

        // Continuous follow track for one scene. The path is sampled with
        // look-ahead, pushed through a dead zone so tiny wiggles are ignored,
        // then zero-phase smoothed. Zero phase is safe here: the path itself is
        // already recorded, and it removes the lag a causal filter would add.
        func pathCenters(_ s: Scene) -> (start: Int, centers: [SIMD2<Double>])? {
            guard s.path.count >= 2 else { return nil }
            let a = min(max(Int((s.on * rate).rounded()), 0), n - 1)
            let b = min(max(Int((s.off * rate).rounded()), a), n - 1)
            guard b > a else { return nil }
            let scale = exp(s.lz), lean = 0.12 / scale
            var xs: [Double] = [], ys: [Double] = []
            xs.reserveCapacity(b - a + 1); ys.reserveCapacity(b - a + 1)
            var j = 0
            for k in a...b {
                let t = Double(k) / rate + look
                while j + 1 < s.path.count, s.path[j + 1].t <= t { j += 1 }
                var c = s.path[j].c
                if j + 1 < s.path.count {
                    let from = s.path[j], to = s.path[j + 1], gap = to.t - from.t
                    if gap <= 0.30 { c = from.c + (to.c - from.c) * clamp((t - from.t) / max(gap, 1e-6), 0, 1) }
                }
                xs.append(c.x + lean - offset.x * exp(-s.lz))
                ys.append(c.y - offset.y * exp(-s.lz))
            }
            xs = zeroPhaseSmooth(centredPlay(xs, halfZone: 0.04 / scale), omega: omegaPan, dt: dt)
            ys = zeroPhaseSmooth(centredPlay(ys, halfZone: 0.06 / scale), omega: omegaPan, dt: dt)
            return (a, zip(xs, ys).map { clampCenter(SIMD2($0, $1), s.lz) })
        }

        var tracks: [(start: Int, centers: [SIMD2<Double>])?] = []
        for s in scenes {
            if cancelled() { return nil }
            tracks.append(pathCenters(s))
        }
        func rawCenter(_ i: Int, _ k: Int) -> SIMD2<Double> {
            let s = scenes[i]
            let j = min(max(k, 0), n - 1)
            if let d = tracks[i], !d.centers.isEmpty {
                // Outside the sampled window the path holds its nearest end
                // value. Falling back to `s.center` here would snap the frame
                // back to the shot's *first* centre at the end of a follow, and
                // a finite difference across that seam reports a velocity the
                // camera never had.
                let idx = min(max(j - d.start, 0), d.centers.count - 1)
                return d.centers[idx]
            }
            if case .follow = s.segment.focus { return SIMD2(followX[j], followY[j]) }
            return s.center
        }
        func holdCenter(_ i: Int, _ k: Int) -> SIMD2<Double> {
            clampCenter(rawCenter(i, k) - offset * exp(-scenes[i].lz), scenes[i].lz)
        }
        /// Velocity of the hold at tick `k`. A transition must join the hold
        /// at this velocity; otherwise the camera stops dead on the action and
        /// accelerates again a frame later — a visible jerk impulse.
        func holdVelocity(_ i: Int, _ k: Int) -> SIMD2<Double> {
            let j = min(max(k, 0), n - 1)
            let a = max(j - 3, 0), b = min(j + 3, n - 1)
            guard b > a else { return .zero }
            return (holdCenter(i, b) - holdCenter(i, a)) * rate / Double(b - a)
        }

        var lzT = [Double](repeating: 0, count: n)
        var cxT = [Double](repeating: 0.5, count: n)
        var cyT = [Double](repeating: 0.5, count: n)

        /// Quintic with matched endpoint velocities. With zero velocities this
        /// is smootherstep; the velocity terms let a move flow into a moving
        /// hold (or out of one) without a velocity step.
        func fill(_ a: Double, _ b: Double, _ l0: Double, _ l1: Double,
                  _ c0: SIMD2<Double>, _ c1: SIMD2<Double>,
                  _ v0: SIMD2<Double> = .zero, _ v1: SIMD2<Double> = .zero) {
            let ia = min(max(Int((a * rate).rounded()), 0), n - 1)
            let ib = min(max(Int((b * rate).rounded()), ia), n - 1)
            let T = max(b - a, 1e-3)
            // x(u) = x0 + T·v0·u + c3u³ + c4u⁴ + c5u⁵, zero endpoint accel.
            func coeff(_ x0: Double, _ x1: Double, _ va: Double, _ vb: Double) -> (Double, Double, Double) {
                let dx = x1 - x0 - T * va
                let dv = T * (vb - va)
                return (10 * dx - 4 * dv, 7 * dv - 15 * dx, 6 * dx - 3 * dv)
            }
            let (c3x, c4x, c5x) = coeff(c0.x, c1.x, v0.x, v1.x)
            let (c3y, c4y, c5y) = coeff(c0.y, c1.y, v0.y, v1.y)
            let (c3l, c4l, c5l) = coeff(l0, l1, 0, 0)
            for k in ia...ib {
                let u = clamp((Double(k) / rate - a) / T, 0, 1)
                let u2 = u * u, u3 = u2 * u
                lzT[k] = l0 + c3l * u3 + c4l * u3 * u + c5l * u3 * u2
                cxT[k] = c0.x + T * v0.x * u + c3x * u3 + c4x * u3 * u + c5x * u3 * u2
                cyT[k] = c0.y + T * v0.y * u + c3y * u3 + c4y * u3 * u + c5y * u3 * u2
            }
        }
        func fillHold(_ i: Int, _ a: Double, _ b: Double) {
            let s = scenes[i]
            let ia = min(max(Int((a * rate).rounded()), 0), n - 1)
            let ib = min(max(Int((b * rate).rounded()), ia), n - 1)
            for k in ia...ib {
                lzT[k] = s.lz
                let c = holdCenter(i, k)
                cxT[k] = c.x; cyT[k] = c.y
            }
        }

        var prevOff = 0.0
        var prevLz = 0.0
        var prevC = SIMD2(0.5, 0.5)
        /// The shot whose hold reaches furthest forward. The mandatory final
        /// return to full frame is anchored to this one, not to whichever scene
        /// happened to be written last, so a short trailing shot can never leave
        /// the tail starting inside an earlier, longer shot.
        var tailIdx: Int?
        for i in scenes.indices {
            if cancelled() { return nil }
            let s = scenes[i]
            // A shot is either bridged into the next one or returns to the full
            // frame before it. If the next lead-in starts inside the current
            // hold there is no room for that return — writing a backwards exit
            // would collapse to one sample and cut the camera. Join the new
            // scene directly instead, from the value already on the track.
            let bridged = i > 0 && prevLz > 0 &&
                ((s.event - prevOff) <= max(panGap, tout + 0.3) || s.on < prevOff)
            let transStart: Double
            if i == 0 {
                transStart = s.on
            } else if bridged {
                // The new lead-in may begin before the previous hold ends. The
                // quintic overwrites the tail of the hold, which is exactly the
                // "start early, settle on the action" behaviour.
                transStart = max(min(prevOff, s.on), 0)
            } else {
                let v = holdVelocity(i - 1, Int(clamp((prevOff * rate).rounded(), 0, Double(n - 1))))
                fill(prevOff, min(prevOff + tout, s.on), prevLz, 0, prevC, SIMD2(0.5, 0.5), v, .zero)
                transStart = s.on
            }
            let fromK = Int(clamp((transStart * rate).rounded(), 0, Double(n - 1)))
            let toK = Int(clamp((s.event * rate).rounded(), 0, Double(n - 1)))
            let fromLz = bridged ? lzT[fromK] : 0
            // Join onto the value that is actually on the track, not onto a
            // recomputed hold formula. If an earlier scene wrote a different
            // value at this tick, the recomputed one is wrong and the handoff
            // becomes a one-tick step — a visible cut, not a pan.
            let fromC = bridged ? SIMD2(cxT[fromK], cyT[fromK]) : SIMD2(0.5, 0.5)
            let fromV = bridged ? holdVelocity(i - 1, fromK) : .zero
            let toC = holdCenter(i, toK)
            let toV = holdVelocity(i, toK)
            fill(transStart, s.event, fromLz, s.lz, fromC, toC, fromV, toV)
            fillHold(i, s.event, s.off)
            if tailIdx == nil || s.off > scenes[tailIdx!].off { tailIdx = i }
            prevOff = s.off
            prevLz = s.lz
            prevC = holdCenter(i, min(max(Int((s.off * rate).rounded()), 0), n - 1))
        }
        // The last return to full frame is mandatory, not opportunistic. The
        // planner clamps the final hold to the end of the composition, so
        // `prevOff` can equal or exceed `outDur`. Writing the tail from there
        // to `outDur` degenerates to a single sample and silently leaves the
        // camera zoomed in (worst when activity keeps extending the last shot).
        // Pull the tail back into the available samples so it always has a
        // finite window and lands exactly on the final tick. Starting no
        // earlier than the arrival keeps the zoom-in intact; the quintic then
        // overwrites only the trailing part of the hold, like a bridge does.
        if let last = tailIdx, scenes[last].lz > 0 {
            let finalTick = Double(n - 1) / rate
            let tailStart = min(prevOff, max(scenes[last].event, finalTick - tout))
            let tailEnd = min(tailStart + tout, finalTick)
            let k = min(max(Int((tailStart * rate).rounded()), 0), n - 1)
            fill(tailStart, tailEnd, lzT[k], 0, SIMD2(cxT[k], cyT[k]), SIMD2(0.5, 0.5),
                 holdVelocity(last, k), .zero)
        }

        // Clamp the centre to the feasible range at the final scale. A centre
        // outside it would show empty canvas at the edge of the recording.
        var X = [Double](repeating: 0.5, count: n), Y = X, Z = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let z = max(lzT[k], 0), h = 0.5 / exp(z)
            Z[k] = z
            X[k] = clamp(cxT[k], h, 1 - h)
            Y[k] = clamp(cyT[k], h, 1 - h)
        }
        func derivatives(_ a: [Double]) -> (v: [Double], acc: [Double]) {
            var v = [Double](repeating: 0, count: a.count), acc = v
            for i in 1..<(a.count - 1) {
                v[i] = (a[i + 1] - a[i - 1]) * rate / 2
                acc[i] = (a[i + 1] - 2 * a[i] + a[i - 1]) * rate * rate
            }
            return (v, acc)
        }
        let dX = derivatives(X), dY = derivatives(Y), dZ = derivatives(Z)
        var track = CameraTrack(count: n, rate: rate)
        for i in 0..<n {
            track.nx[i] = Float(X[i]); track.ny[i] = Float(Y[i]); track.lz[i] = Float(Z[i])
            track.vx[i] = Float(dX.v[i]); track.vy[i] = Float(dY.v[i]); track.vz[i] = Float(dZ.v[i])
            track.ax[i] = Float(dX.acc[i]); track.ay[i] = Float(dY.acc[i]); track.az[i] = Float(dZ.acc[i])
        }
        var yaw = p.tilt == .reveal ? 12.0 : 0.0, yawVelocity = 0.0
        var pitch = 0.0, pitchVelocity = 0.0
        func phase(_ channel: Int) -> Double {
            Double((p.tiltSeed >> UInt64(channel * 8)) & 255) / 255 * 2 * .pi
        }
        for sample in 0..<n {
            let time = Double(sample) * dt
            let scale = exp(Z[sample])
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