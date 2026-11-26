import Foundation
import LumenCore
import LumenProject

/// A finite shot schedule. No independent camera springs, no per-keystroke
/// following, no camera motion during a settled shot. The dense CameraTrack
/// output is the compatibility boundary for the existing editor and MCP tools.
enum CameraSolver {
    static let cameraRate = 480.0

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


    private struct Pose {
        var focus: SIMD2<Double>
        var logScale: Double
        static let rest = Pose(focus: SIMD2(repeating: 0.5), logScale: 0)
    }

    private struct Sample {
        var pose: Pose
        var velocity = SIMD3<Double>.zero
        var acceleration = SIMD3<Double>.zero
        static let rest = Sample(pose: .rest)
    }

    private struct Leg {
        let start: Double
        let end: Double
        let target: Pose
        let x, y, z: QuinticMove

        init(start: Double, end: Double, from s: Sample, to target: Pose) {
            self.start = start; self.end = end; self.target = target
            let duration = max(end - start, 1 / CameraSolver.cameraRate)
            x = QuinticMove(t0: start, T: duration, x0: s.pose.focus.x,
                            v0: s.velocity.x, a0: s.acceleration.x, x1: target.focus.x)
            y = QuinticMove(t0: start, T: duration, x0: s.pose.focus.y,
                            v0: s.velocity.y, a0: s.acceleration.y, x1: target.focus.y)
            z = QuinticMove(t0: start, T: duration, x0: s.pose.logScale,
                            v0: s.velocity.z, a0: s.acceleration.z, x1: target.logScale)
        }

        func at(_ time: Double) -> Sample {
            guard time < end else { return Sample(pose: target) }
            let a = x.sample(time), b = y.sample(time), c = z.sample(time)
            return Sample(pose: Pose(focus: SIMD2(a.x, b.x), logScale: c.x),
                          velocity: SIMD3(a.v, b.v, c.v), acceleration: SIMD3(a.a, b.a, c.a))
        }
    }

    private struct Shot {
        let start: Double
        let arrive: Double
        let holdEnd: Double
        let actionStart: Double
        let actionEnd: Double
        let releaseEnd: Double
        let target: Pose
        let manual: Bool
        let fixed: Bool
    }

    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams,
                      src: SIMD2<Double>, outDur: Double, loop: Double?,
                      crop: DenseCropTrack = DenseCropTrack(), aspect: Double? = nil) -> CameraTrack {
        solve(zoom: zoom, tm: tm, cursor: cursor, p: p, src: src, outDur: outDur, loop: loop,
              crop: crop, aspect: aspect, follow: [:], cancelled: { false })
            ?? CameraTrack(count: 2, rate: cameraRate)
    }

    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams,
                      src: SIMD2<Double>, outDur: Double, loop: Double?,
                      crop: DenseCropTrack = DenseCropTrack(), aspect: Double? = nil,
                      cancelled: () -> Bool) -> CameraTrack? {
        solve(zoom: zoom, tm: tm, cursor: cursor, p: p, src: src, outDur: outDur, loop: loop,
              crop: crop, aspect: aspect, follow: [:], cancelled: cancelled)
    }

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
        let maxLog = log(max(p.maxScale.isFinite ? p.maxScale : 2, 1))
        let tail = clamp(p.tail.isFinite ? p.tail : 0.7, 0.25, 1.5)
        let lead = clamp(p.leadIn.isFinite ? p.leadIn : 0.3, 0.18, 0.9)
        let bias = SIMD2(clamp(p.centerOffsetX.isFinite ? p.centerOffsetX : 0, -0.25, 0.25),
                         clamp(p.centerOffsetY.isFinite ? p.centerOffsetY : 0, -0.25, 0.25))
        let full = PxRect(x: 0, y: 0, w: src.x, h: src.y)

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

        func cursorPoint(_ t: Double) -> SIMD2<Double> {
            guard !cursor.x.isEmpty, cursor.x.count == cursor.y.count else { return SIMD2(repeating: 0.5) }
            let i = Int(clamp((t * gridRate).rounded(), 0, Double(cursor.x.count - 1)))
            return SIMD2(Double(cursor.x[i]) / src.x, Double(cursor.y[i]) / src.y)
        }

        var shots: [Shot] = []
        shots.reserveCapacity(zoom.count)
        for z in zoom {
            if cancelled() { return nil }
            guard z.start.isFinite, z.end.isFinite, z.scale.isFinite, z.end > z.start,
                  z.scale > 1, !tm.isCut(z.start) || z.origin == .manual else { continue }
            let a = clamp(tm.output(atSource: z.start), 0, outDur)
            let b = clamp(tm.output(atSource: z.end), 0, outDur)
            guard b > a + 0.025, a < outDur else { continue }
            let manual = z.origin == .manual
            let fixed = p.preset == .fixed && !manual
            let easing = z.easing?.omegaScale ?? 1
            let rise = clamp(lead / max(easing, 0.5), 0.45, 0.9)
            let focus: SIMD2<Double>
            switch z.focus {
            case let .fixed(x, y): focus = SIMD2(x, y)
            case let .element(x, y, w, h): focus = SIMD2(x + w / 2, y + h / 2)
            case .follow:
                // One observed anchor per shot. Typing cannot drag the camera
                // with the caret. A different observed interaction creates a new shot.
                let evidence = follow[z.id]?.filter { $0.t.isFinite && $0.c.x.isFinite && $0.c.y.isFinite }
                focus = evidence?.min(by: { abs($0.t - a) < abs($1.t - a) })?.c ?? cursorPoint(a)
            }
            guard focus.x.isFinite, focus.y.isFinite else { continue }
            let logScale = clamp(log(z.scale), 0, maxLog)
            guard logScale > 1e-6 else { continue }
            let begin = manual ? a : max(a - rise, 0)
            // Reserve a real stationary interval before the event. At the
            // beginning of a recording there is no history to anticipate.
            let settle = min(0.06 + 1 / cameraRate, max(a - begin - 1 / cameraRate, 0))
            let arrive = manual ? min(a + clamp(0.9 / max(easing, 0.3), 0.25, 2), max(b - 0.05, a + 0.05)) : max(a - settle, begin + 0.3)
            let releaseEnd = fixed ? outDur : (manual ? b : min(b + tail, outDur))
            let holdEnd = fixed ? outDur : (manual
                ? max(arrive, b - min(tail, (b - a) * 0.4))
                : max(0, min(b, outDur - tail)))
            // Store the optical pivot, not a second independently eased pan.
            // At the target scale, project the requested center into the
            // feasible viewport and solve C(s) = P + (C(1)-P)/s.
            let box = viewport(min(arrive, outDur))
            let base = CropSpace.baseView(crop: box, aspect: aspect)
            let scale = exp(logScale)
            let q = CropSpace.normalise(clamp(focus.x, 0, 1) * src.x,
                                        clamp(focus.y, 0, 1) * src.y, crop: box)
            let halfX = min(base.w / (2 * box.w * scale), 0.5)
            let halfY = min(base.h / (2 * box.h * scale), 0.5)
            let center = SIMD2(clamp(q.u - bias.x / scale, halfX, 1 - halfX),
                               clamp(q.v - bias.y / scale, halfY, 1 - halfY))
            let pivot = SIMD2<Double>(repeating: 0.5) + (center - SIMD2<Double>(repeating: 0.5)) / (1 - 1 / scale)
            let target = Pose(focus: pivot, logScale: logScale)
            shots.append(Shot(start: begin, arrive: min(arrive, outDur), holdEnd: holdEnd,
                              actionStart: a, actionEnd: b, releaseEnd: releaseEnd, target: target, manual: manual, fixed: fixed))
        }
        shots.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            if a.manual != b.manual { return !a.manual }
            return a.arrive < b.arrive
        }
        guard !shots.isEmpty || p.tilt == .reveal else { return CameraTrack(count: 2, rate: cameraRate) }

        // The last leg before t is authoritative. Cutting an in-flight leg
        // evaluates its boundary state first, preserving C2 at the handoff.
        var legs: [Leg] = []
        func insert(at start: Double, end: Double, target: Pose) {
            guard end > start else { return }
            while let last = legs.last, last.start >= start { legs.removeLast() }
            var sample = legs.last?.at(start) ?? .rest
            // At 1× the pivot is unobservable. Choose the upcoming pivot
            // while stationary so the first zoom has no sideways drift.
            if abs(sample.pose.logScale) < 1e-9, abs(sample.velocity.z) < 1e-9,
               abs(sample.acceleration.z) < 1e-9 {
                sample.pose.focus = target.focus
                sample.velocity.x = 0; sample.velocity.y = 0
                sample.acceleration.x = 0; sample.acceleration.y = 0
            }
            legs.append(Leg(start: start, end: end, from: sample, to: target))
        }
        // Plan bridges before inserting legs. A short gap belongs to the
        // same action, while separated shots and overlong chains must return
        // to 1x. Never schedule a zero-duration final release.
        var selected: [Shot] = []
        var manualUntil = -Double.infinity
        for shot in shots {
            if cancelled() { return nil }
            if !shot.manual && shot.start < manualUntil { continue }
            if shot.manual { manualUntil = max(manualUntil, shot.releaseEnd) }
            selected.append(shot)
        }
        var chainStart = selected.first?.actionStart ?? 0
        var previousReleaseEnd = 0.0
        for i in selected.indices {
            if cancelled() { return nil }
            let shot = selected[i]
            let next = i + 1 < selected.count ? selected[i + 1] : nil
            let gap = next.map { $0.actionStart - shot.actionEnd } ?? .infinity
            let bridge = !shot.manual && !shot.fixed && next.map {
                !$0.manual && gap < 0.95 && $0.actionStart - chainStart < 4
            } == true
            let start = min(max(shot.start, previousReleaseEnd), max(0, outDur - tail - 0.3))
            var arrive = max(shot.arrive, min(start + 0.3, outDur))
            if !shot.manual && !shot.fixed {
                // A late click cannot consume the final release runway.
                arrive = min(arrive, max(start, outDur - min(tail, outDur * 0.4)))
            }
            if arrive > start + 1 / cameraRate {
                insert(at: start, end: arrive, target: shot.target)
            }
            if shot.fixed || bridge { continue }
            var releaseEnd = shot.releaseEnd
            var holdEnd = max(arrive, shot.holdEnd)
            if let next, !shot.manual {
                // Separate shots own distinct non-overlapping legs. On dense
                // chains reserve part of the preceding hold for a clean break.
                let boundary = max(start, next.start)
                releaseEnd = min(releaseEnd, boundary)
                if gap >= 0.95 {
                    releaseEnd = min(releaseEnd, shot.actionEnd + gap * 0.5)
                }
                holdEnd = min(holdEnd, releaseEnd - min(tail, 0.35))
                holdEnd = max(start, holdEnd)
                chainStart = next.actionStart
            }
            if !shot.manual {
                holdEnd = min(holdEnd, releaseEnd - min(tail, max(0.25, releaseEnd - start)))
                holdEnd = max(start, holdEnd)
            }
            if releaseEnd > holdEnd + 1 / cameraRate {
                insert(at: holdEnd, end: releaseEnd, target: Pose(focus: shot.target.focus, logScale: 0))
                previousReleaseEnd = releaseEnd
            }
        }
        if let loop, loop.isFinite, loop > 0 {
            let start = max(0, outDur - min(loop, tail))
            let pivot = legs.last(where: { $0.start <= start })?.at(start).pose.focus ?? Pose.rest.focus
            insert(at: start, end: outDur, target: Pose(focus: pivot, logScale: 0))
        }
        if cancelled() { return nil }

        // Bake only the published compatibility track. The underlying
        // trajectory is evaluated directly, not repeatedly integrated or
        // smoothed. All stationary samples are exact and repeatable.
        let trackDuration = shots.isEmpty ? min(outDur, 0.6 + 1 / cameraRate) : outDur
        let count = max(Int(ceil(trackDuration * cameraRate)) + 1, 2)
        var track = CameraTrack(count: count, rate: cameraRate)
        var index = -1
        for i in 0..<count {
            if (i & 1023) == 0 && cancelled() { return nil }
            let time = min(Double(i) / cameraRate, outDur)
            while index + 1 < legs.count, legs[index + 1].start <= time { index += 1 }
            let state = index >= 0 ? legs[index].at(time) : .rest
            let lz = clamp(state.pose.logScale, 0, maxLog)
            let box = viewport(time)
            let base = CropSpace.baseView(crop: box, aspect: aspect)
            let scale = exp(lz)
            let halfX = min(base.w / (2 * box.w * scale), 0.5)
            let halfY = min(base.h / (2 * box.h * scale), 0.5)
            let travel = 1 - 1 / scale
            let x = clamp(0.5 + (state.pose.focus.x - 0.5) * travel, halfX, 1 - halfX)
            let y = clamp(0.5 + (state.pose.focus.y - 0.5) * travel, halfY, 1 - halfY)
            track.nx[i] = Float(x); track.ny[i] = Float(y); track.lz[i] = Float(lz)
            // 3D reveal is intentional, finite and opt-in; no idle float.
            if p.tilt == .reveal, time < 0.6 {
                track.yaw[i] = Float(12 * (1 - QuinticMove.envelope(time / 0.6)))
            }
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
        }
        return track
    }
}
