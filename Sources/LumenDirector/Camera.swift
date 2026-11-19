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

    /// Follow paths use output seconds and source-normalised caret coordinates.
    /// Each target is normalised into `crop` at ITS OWN time, and every tick's
    /// centre is clamped to that tick's crop (the CropSpace.visible contract).
    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams,
                      src: SIMD2<Double>, outDur: Double, loop: Double?,
                      crop: DenseCropTrack = DenseCropTrack(), aspect: Double? = nil,
                      follow: [UUID: [(t: Double, c: SIMD2<Double>)]],
                      cancelled: () -> Bool) -> CameraTrack? {
        _ = loop
        let rate = cameraRate, dt = 1 / rate
        guard outDur.isFinite, outDur > 0, src.x.isFinite, src.y.isFinite, src.x > 0, src.y > 0 else {
            return CameraTrack(count: 2, rate: rate)
        }
        let n = max(Int(outDur * rate) + 1, 2)
        // F1: the feasible box is crop(t) at each tick's OWN output time, never
        // the full source rect. An empty track falls back to the source rect,
        // so solvers without a browser crop are bit-for-bit unchanged.
        let fullSource = PxRect(x: 0, y: 0, w: src.x, h: src.y)
        var cropAtTick = [PxRect](repeating: fullSource, count: n)
        if !crop.rects.isEmpty {
            let cropHz = crop.hz.isFinite && crop.hz > 0 ? crop.hz : rate
            let dense = DenseCropTrack(hz: cropHz, rects: crop.rects)
            for k in 0..<n {
                let r = dense.rect(at: tm.source(atOutput: Double(k) / rate))
                if r.isValid, r.w >= 1, r.h >= 1 { cropAtTick[k] = r }
            }
        }
        func tickIndex(_ t: Double) -> Int { min(max(Int((t * rate).rounded()), 0), n - 1) }
        func normalise(_ px: Double, _ py: Double, at t: Double) -> SIMD2<Double> {
            let n = CropSpace.normalise(px, py, crop: cropAtTick[tickIndex(t)])
            return SIMD2(n.u, n.v)
        }
        let leadBase = p.leadIn.isFinite ? clamp(p.leadIn, 0, 1.5) : 0.30
        let tout = max(p.tail.isFinite ? p.tail : 0.7, 0.25)
        let look = clamp(p.lookahead.isFinite ? p.lookahead : 0.12, 0, 0.5)
        let offset = SIMD2(clamp(p.centerOffsetX, -0.25, 0.25), clamp(p.centerOffsetY, -0.25, 0.25))
        let omegaPan = max(p.omegaPan.isFinite ? p.omegaPan : 4, 1)
        // maxScale is a hard cap at every stage, not just in the planner. A
        // manually edited or hostile segment must not slip past it, and the
        // cap has to be applied to the *target* so the quintic never aims at
        // a scale the final clamp would flatten into a stop-start plateau.
        let maxLz = log(max(p.maxScale.isFinite ? p.maxScale : 2, 1.0001))

        struct Scene {
            var on: Double
            var arrival: Double                 // where the move lands and the hold begins
            var event: Double                   // the click / keystroke the shot anticipates
            var off: Double
            var lz: Double
            var center: SIMD2<Double>
            var segment: ZoomSegment
            var path: [(t: Double, c: SIMD2<Double>)]
        }

        /// Lead-in grows with magnification and with how far the frame has to
        /// travel. A quintic's peak jerk is 60·d/T³, so a short runway on a
        /// long pan snaps into place — the exact "stop-start" the settle is
        /// meant to avoid. Give the move enough time for a filmed ease-out.
        func leadFor(_ lz: Double, _ ease: Double, _ pan: Double) -> Double {
            let magnitude = 0.22 + 0.16 * (lz / 0.6931471805599453)
            let base = max(leadBase, magnitude) / max(ease, 0.55)
            // 2560 px is a conservative source-width reference (covers 1920 and
            // 2560 masters). Size the runway from the shared jerk limit so the
            // lens never arrives by snapping into place. Do NOT pass the two
            // continuity slopes here: doing so lengthens the lead-in enough that
            // `on` moves earlier than a return runway allows, and chained shots
            // then fail to reach the full frame between them (measured: 1.0036x
            // instead of 1.0x). The headroom for a bridge's slopes comes from
            // cameraJerk (1e6) sitting above filmJerk (7e5), not from this arg.
            let jerkFloor = MotionLimits.minDuration(delta: pan * 2560,
                                                     continuitySlopes: 0,
                                                     maxJerk: MotionLimits.filmJerk)
            return clamp(max(base, jerkFloor), 0.20, 1.6)
        }
        func manualRise(_ ease: Double) -> Double { clamp(0.9 / max(ease, 0.3), 0.25, 2.0) }

        // TimeMap.output converts a source time into an array index; NaN or an
        // infinity there traps before the finite-result guard below can see it.
        // Drop non-finite segment times up front so a corrupt or hostile plan
        // degrades to a still frame instead of killing the process.
        let finiteZoom = zoom.filter { $0.start.isFinite && $0.end.isFinite }
        // Ordered by settle time, not by lead-in start. The camera holds one
        // target at a time and the track is written in a single forward pass,
        // so the pass must follow the order the shots actually land. Sorting by
        // `on` lets a later shot's lead-in begin before an earlier shot's
        // arrival, which reorders the pass and leaves a one-tick cut where the
        // two writes meet.
        let scenes: [Scene] = finiteZoom.compactMap { z -> Scene? in
            let a = tm.output(atSource: z.start), b = tm.output(atSource: z.end)
            guard a.isFinite, b.isFinite, b - a > 0.02, z.scale.isFinite, z.scale > 1.001, a < outDur else { return nil }
            let ease: Double
            if let e = z.easing?.omegaScale, e.isFinite, e > 0 { ease = e } else { ease = 1 }
            let lz = clamp(log(max(z.scale, 1.0001)), 0, maxLz)
            let path = (follow[z.id] ?? [])
                .filter { $0.t.isFinite && $0.c.x.isFinite && $0.c.y.isFinite }
                .sorted { $0.t < $1.t }
            // The event time is independent of the lead-in, so every target can
            // be normalised into the crop that is actually on screen WHEN IT
            // HAPPENS — never at shot start or at "now".
            let event: Double = z.origin == .auto
                ? a : min(a + manualRise(ease), max(b - 0.05, a + 0.05))
            let center: SIMD2<Double>
            switch z.focus {
            case .fixed(let x, let y): center = normalise(x * src.x, y * src.y, at: event)
            case .element(let x, let y, let w, let h):
                center = normalise((x + w / 2) * src.x, (y + h / 2) * src.y, at: event)
            case .follow:
                center = path.first.map { normalise($0.c.x * src.x, $0.c.y * src.y, at: $0.t) }
                    ?? SIMD2(0.5, 0.5)
            }
            // Anticipation budget. The lead-in must cover BOTH the move and the
            // still settle before the action; subtracting settle from a fixed
            // lead would shorten the quintic's runway and spike its jerk.
            let pan = max(abs(center.x - 0.5), abs(center.y - 0.5))
            let lead = leadFor(lz, ease, pan)
            let settle = z.origin == .auto
                ? min(clamp(0.11 / max(ease, 0.6), 0.06, 0.18), 0.35 * lead)
                : 0
            let on: Double = z.origin == .auto ? max(a - lead - settle, 0) : a
            // The lead-in is the anticipation; the settle is the breath at the
            // end of it. Land a little *before* the action so the frame is
            // already composed and perfectly still when the click/typing lands.
            let arrival = max(on + 0.04, event - settle)
            return Scene(on: on, arrival: arrival, event: event, off: max(b, event + 0.02), lz: lz,
                         center: center, segment: z, path: path)
        }.sorted { $0.arrival < $1.arrival }

        // Global cursor track for follow scenes that have no explicit path.
        // A scene with a recorded path is driven by `pathCenters` instead.
        let needsCursor = scenes.contains { scene in
            if case .follow = scene.segment.focus { return scene.path.count < 2 }
            return false
        }
        var followX = [Double](repeating: 0.5, count: n), followY = followX
        if needsCursor, min(cursor.x.count, cursor.y.count) > 0 {
            let halfZone = clamp(p.deadZone.isFinite ? p.deadZone : 0.28, 0.05, 0.45) / 2
            let followOmega = 1 / max(clamp(p.followDelay.isFinite ? p.followDelay : 0.12, 0, 0.5), 0.045)
            let cx = min(cursor.x.count, cursor.y.count)
            let rawX = (0..<n).map { i -> Double in
                let j = min(Int(Double(i) * gridRate / rate), cx - 1), box = cropAtTick[i]
                return (Double(cursor.x[j]) - box.x) / box.w
            }
            let rawY = (0..<n).map { i -> Double in
                let j = min(Int(Double(i) * gridRate / rate), cx - 1), box = cropAtTick[i]
                return (Double(cursor.y[j]) - box.y) / box.h
            }
            followX = zeroPhaseSmooth(centredPlay(rawX, halfZone: halfZone), omega: followOmega, dt: dt)
            followY = zeroPhaseSmooth(centredPlay(rawY, halfZone: halfZone), omega: followOmega, dt: dt)
        }

        /// Crop-normalised twin of CropSpace.visible's centre clamp: the visible
        /// viewport (base view / scale) must fit inside crop(t) at tick `k`.
        func clampCenter(_ c: SIMD2<Double>, _ lz: Double, _ k: Int) -> SIMD2<Double> {
            let box = cropAtTick[k]
            let base = CropSpace.baseView(crop: box, aspect: aspect)
            let z = exp(max(lz, 0))
            let hw = base.w / z / (2 * box.w), hh = base.h / z / (2 * box.h)
            return SIMD2(clamp(c.x, min(hw, 0.5), max(1 - hw, 0.5)),
                         clamp(c.y, min(hh, 0.5), max(1 - hh, 0.5)))
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
                // The recorded caret is source-normalised; re-aim it into the
                // crop that is actually on screen at this tick. `centerOffset`
                // is applied once in `holdCenter`; `lean` stays a follow bias.
                let box = cropAtTick[k]
                xs.append((c.x * src.x - box.x) / box.w + lean)
                ys.append((c.y * src.y - box.y) / box.h)
            }
            xs = zeroPhaseSmooth(centredPlay(xs, halfZone: 0.04 / scale), omega: omegaPan, dt: dt)
            ys = zeroPhaseSmooth(centredPlay(ys, halfZone: 0.06 / scale), omega: omegaPan, dt: dt)
            var centres: [SIMD2<Double>] = []
            centres.reserveCapacity(xs.count)
            for (i, pair) in zip(xs, ys).enumerated() {
                centres.append(clampCenter(SIMD2(pair.0, pair.1), s.lz, a + i))
            }
            return (a, centres)
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
            clampCenter(rawCenter(i, k) - offset * exp(-scenes[i].lz), scenes[i].lz, k)
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

        /// One camera move, one curve. Pan and dolly are driven by the same
        /// quintic envelope so they accelerate and settle as a single filmed
        /// gesture. A Hermite slope term adds only the velocity continuity a
        /// handoff needs; it never moves the endpoints and, at rest, it is zero
        /// so the move is the pure monotone envelope with no overshoot.
        func fill(_ a: Double, _ b: Double, _ l0: Double, _ l1: Double,
                  _ c0: SIMD2<Double>, _ c1: SIMD2<Double>,
                  _ v0: SIMD2<Double> = .zero, _ v1: SIMD2<Double> = .zero,
                  _ vl0: Double = 0, _ vl1: Double = 0) {
            let ia = min(max(Int((a * rate).rounded()), 0), n - 1)
            let ib = min(max(Int((b * rate).rounded()), ia), n - 1)
            let T = max(b - a, 1e-3)
            let dl = l1 - l0
            let dc = c1 - c0
            // A noisy follow velocity must not turn the settle into a stop-start
            // or push the pan past its target. Cap the continuity slopes at a
            // fraction of the distance actually being travelled this move.
            func bounded(_ v: Double, _ delta: Double) -> Double {
                let cap = abs(delta) / T * 1.5 + 0.02
                return clamp(v, -cap, cap)
            }
            let va = SIMD2(bounded(v0.x, dc.x), bounded(v0.y, dc.y))
            let vb = SIMD2(bounded(v1.x, dc.x), bounded(v1.y, dc.y))
            // The dolly needs the same continuity slopes as the pan. When a
            // bridge starts inside the previous move, the lens is still moving;
            // restarting it from rest kills that momentum in one tick — a
            // scale stop-start the viewer reads as a pump. The slope terms carry
            // the incoming (and outgoing) log-scale velocity across the join.
            // They are zero at both ends, so normal rest-to-rest moves are
            // bit-for-bit unchanged and the target is still hit exactly.
            let vla = bounded(vl0, dl), vlbb = bounded(vl1, dl)
            for k in ia...ib {
                let u = clamp((Double(k) / rate - a) / T, 0, 1)
                let s = QuinticMove.envelope(u)
                let lead = QuinticMove.leadSlope(u), trail = QuinticMove.trailSlope(u)
                lzT[k] = l0 + dl * s + T * (vla * lead + vlbb * trail)
                cxT[k] = c0.x + dc.x * s + T * (va.x * lead + vb.x * trail)
                cyT[k] = c0.y + dc.y * s + T * (va.y * lead + vb.y * trail)
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
        /// Velocity of the camera as it is actually written on the track at
        /// tick `k`. A bridge must leave from this velocity, not from a freshly
        /// recomputed hold formula: an earlier scene may have overwritten the
        /// value here, and joining to a different slope is the one-tick cut a
        /// viewer reads as a jerk.
        func trackVelocity(_ k: Int) -> SIMD2<Double> {
            let j = min(max(k, 0), n - 1)
            let a = max(j - 4, 0), b = min(j + 4, n - 1)
            guard b > a else { return .zero }
            return (SIMD2(cxT[b], cyT[b]) - SIMD2(cxT[a], cyT[a])) * rate / Double(b - a)
        }
        /// Log-scale twin of `trackVelocity`. A bridge that begins before the
        /// previous lens move has settled must inherit its scale velocity too,
        /// or the dolly stops dead for one tick while the pan keeps going.
        func trackZVelocity(_ k: Int) -> Double {
            let j = min(max(k, 0), n - 1)
            let a = max(j - 4, 0), b = min(j + 4, n - 1)
            guard b > a else { return 0 }
            return (lzT[b] - lzT[a]) * rate / Double(b - a)
        }

        // A complete return to full frame needs the tail plus a beat of stillness
        // before the next lead-in. Geometry, not a time window, decides whether
        // two shots are one camera move: the old "panGap + tail" rule fused shots
        // a second or two apart into one continuous 8-10 s zoom.
        let returnRoom = tout + 0.12
        // A gap this large between two planned actions means the camera is meant
        // to come back to the full frame in between. `minHold` keeps a real,
        // finite hold even when the next action arrives close behind.
        let distinctGap = 0.95
        // A truncated hold still needs a real, finite beat before the exit.
        // Below this the return would be squeezed into a few ticks and spike.
        let minHold = 0.25
        // A chain of genuinely tight shots may bridge, but never for longer
        // than this: the outgoing hold is then shortened to make room.
        let bridgedRunLimit = max(5.0, 3 * (p.hold.isFinite ? p.hold : 0.9))

        var prevOff = 0.0
        var prevLz = 0.0
        var prevArrival = 0.0
        /// First arrival of the current bridged run. Nil when the camera is at
        /// the full frame between shots.
        var runStart: Double?
        /// The shot whose hold reaches furthest forward. The mandatory final
        /// return to full frame is anchored to this one, not to whichever scene
        /// happened to be written last, so a short trailing shot can never leave
        /// the tail starting inside an earlier, longer shot.
        var tailIdx: Int?
        var tailHoldEnd = 0.0
        for i in scenes.indices {
            if cancelled() { return nil }
            let s = scenes[i]

            // Hold only as long as this action needs. When the next action
            // starts a beat later, give the return its room by ending the hold
            // early — a solver never stretches a shot just because the planner
            // handed it a long segment.
            var holdEnd = s.off
            if i + 1 < scenes.count, scenes[i + 1].event - s.off >= distinctGap {
                let roomForNext = scenes[i + 1].on - returnRoom - 0.02
                holdEnd = min(s.off, max(s.arrival + minHold, roomForNext))
            }

            let room = s.on - prevOff
            // Measure the run from the arrival that would start it, not only
            // from an already-open run. Otherwise the first bridge after a
            // return is always "short" and two long shots fuse into 16 s.
            let candidateRunStart = runStart ?? prevArrival
            let runLength = i > 0 && prevLz > 0 ? s.arrival - candidateRunStart : 0
            let runTooLong = runLength > bridgedRunLimit
            // A break is possible when part of the previous hold can be given
            // back while leaving a finite, bounded-jerk return runway.
            // A forced return needs a runway long enough for the pan it must
            // cover: a 1000 px move squeezed into 0.25 s spikes jerk well past
            // the bound. The jerk floor is a limit, so a break simply is not
            // taken when there is no room for a filmed return.
            let pk = min(max(Int((prevArrival * rate).rounded()), 0), n - 1)
            let pkBox = cropAtTick[pk]
            let panPx = hypot(Double(cxT[pk]) - 0.5, Double(cyT[pk]) - 0.5) * max(pkBox.w, pkBox.h)
            let returnRunway = max(0.25,
                                   MotionLimits.minDuration(delta: panPx,
                                                            continuitySlopes: 1,
                                                            maxJerk: MotionLimits.filmJerk))
            let forcedEnd = max(prevArrival + returnRunway,
                                min(prevOff, s.on - returnRoom))
            var previousFollows = false
            if i > 0, case .follow = scenes[i - 1].segment.focus { previousFollows = true }
            // A follow shot is one continuous gesture with a live centre. A
            // forced return out of it would join a moving hold at zero
            // acceleration — an acceleration step and a jerk spike. Keep such
            // shots bridged; the run cap applies to static subjects.
            let canBreak = i > 0 && prevLz > 0 && !previousFollows &&
                           forcedEnd < prevOff - 0.02 &&
                           max(s.on, forcedEnd) < s.arrival - 0.05
            let bridged = i > 0 && prevLz > 0 && room < returnRoom &&
                          (!runTooLong || !canBreak)

            let transStart: Double
            if i == 0 {
                transStart = s.on
            } else if bridged {
                // The new lead-in may begin before the previous hold ends. The
                // quintic overwrites the tail of the hold, which is exactly the
                // "start early, settle on the action" behaviour.
                if runStart == nil { runStart = prevArrival }
                transStart = max(min(prevOff, s.on), 0)
            } else {
                // Full return to 1x before the next lead-in. The normal exit
                // starts where the hold ended; only an overlong run is broken
                // by pulling the return back into the hold. Joining the value
                // already on the track preserves velocity at both ends, so
                // there is no per-tick cut, no stop-start, no jerk impulse.
                let returnEnd: Double
                if canBreak {
                    let returnStart = max(prevArrival, forcedEnd - tout)
                    let rk = min(max(Int((returnStart * rate).rounded()), 0), n - 1)
                    fill(returnStart, forcedEnd, lzT[rk], 0, SIMD2(cxT[rk], cyT[rk]),
                         SIMD2(0.5, 0.5), trackVelocity(rk), .zero, trackZVelocity(rk), 0)
                    returnEnd = forcedEnd
                    transStart = max(s.on, forcedEnd)
                } else {
                    returnEnd = min(prevOff + tout, s.on)
                    let rk = min(max(Int((prevOff * rate).rounded()), 0), n - 1)
                    fill(prevOff, returnEnd, lzT[rk], 0, SIMD2(cxT[rk], cyT[rk]),
                         SIMD2(0.5, 0.5), trackVelocity(rk), .zero, trackZVelocity(rk), 0)
                    transStart = s.on
                }
                // Ticks between the end of the return and this lead-in are
                // full frame. Clear any hold that still occupies them so the
                // next move starts from a genuinely still, centred camera.
                let ke = min(max(Int((returnEnd * rate).rounded()), 0), n - 1)
                let kt = min(max(Int((transStart * rate).rounded()), 0), n - 1)
                if kt > ke { for k in (ke + 1)...kt { lzT[k] = 0; cxT[k] = 0.5; cyT[k] = 0.5 } }
                runStart = nil
            }
            let fromK = Int(clamp((transStart * rate).rounded(), 0, Double(n - 1)))
            let toK = Int(clamp((s.arrival * rate).rounded(), 0, Double(n - 1)))
            let fromLz = bridged ? lzT[fromK] : 0
            // Join onto the value that is actually on the track, not onto a
            // recomputed hold formula. If an earlier scene wrote a different
            // value at this tick, the recomputed one is wrong and the handoff
            // becomes a one-tick step — a visible cut, not a pan.
            let fromC = bridged ? SIMD2(cxT[fromK], cyT[fromK]) : SIMD2(0.5, 0.5)
            let fromV = bridged ? trackVelocity(fromK) : .zero
            let toC = holdCenter(i, toK)
            let toV = holdVelocity(i, toK)
            fill(transStart, s.arrival, fromLz, s.lz, fromC, toC, fromV, toV,
                 bridged ? trackZVelocity(fromK) : 0, 0)
            fillHold(i, s.arrival, holdEnd)
            if tailIdx == nil || holdEnd > tailHoldEnd { tailIdx = i; tailHoldEnd = holdEnd }
            prevOff = holdEnd
            prevLz = s.lz
            prevArrival = s.arrival
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
            let tailStart = min(tailHoldEnd, max(scenes[last].event, finalTick - tout))
            let tailEnd = min(tailStart + tout, finalTick)
            let k = min(max(Int((tailStart * rate).rounded()), 0), n - 1)
            fill(tailStart, tailEnd, lzT[k], 0, SIMD2(cxT[k], cyT[k]), SIMD2(0.5, 0.5),
                 holdVelocity(last, k), .zero)
        }

        // Clamp the centre to the feasible box of crop(k) at EVERY tick, at the
        // final scale. This is the solver-side twin of CropSpace.visible, so a
        // moving crop can never make a settled camera drift outside the frame.
        var X = [Double](repeating: 0.5, count: n), Y = X, Z = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let z = clamp(lzT[k], 0, maxLz)
            Z[k] = z
            let c = clampCenter(SIMD2(cxT[k], cyT[k]), z, k)
            X[k] = c.x; Y[k] = c.y
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
        // Tilt is deterministic and shot-driven: `.lean` follows pan velocity,
        // `.reveal` is a one-shot entrance, `.off` is flat. The old causeless
        // oscillator is gone; nothing moves without a move that asks for it.
        let tiltOmega = clamp(p.omegaTilt.isFinite ? p.omegaTilt : 5, 0.5, 60)
        let tiltYaw = p.maxYaw.isFinite ? max(p.maxYaw, 0) : 8
        let tiltPitch = p.maxPitch.isFinite ? max(p.maxPitch, 0) : 6
        var yaw = p.tilt == .reveal ? 12.0 : 0.0, yawVelocity = 0.0
        var pitch = 0.0, pitchVelocity = 0.0
        for sample in 0..<n {
            let scale = exp(Z[sample])
            var yawTarget = 0.0, pitchTarget = 0.0
            switch p.tilt {
            case .lean:
                yawTarget = clamp(Double(track.vx[sample]) * scale * 12, -tiltYaw, tiltYaw)
                pitchTarget = clamp(-Double(track.vy[sample]) * scale * 9, -tiltPitch, tiltPitch)
            case .reveal, .off:
                break
            }
            springStep(&yaw, &yawVelocity, target: yawTarget, omega: tiltOmega, dt: dt)
            springStep(&pitch, &pitchVelocity, target: pitchTarget, omega: tiltOmega, dt: dt)
            track.yaw[sample] = Float(yaw)
            track.pitch[sample] = Float(pitch)
        }
        return track
    }
}