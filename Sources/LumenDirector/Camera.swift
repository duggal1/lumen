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

        func viewport(_ t: Double) -> PxRect {
            guard !crop.rects.isEmpty, crop.hz.isFinite, crop.hz > 0 else { return full }
            let rect = crop.rect(at: tm.source(atOutput: t)).intersection(full)
            return rect.isValid && rect.w >= 1 && rect.h >= 1 ? rect : full
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
            let rise = clamp(lead / max(easing, 0.5), 0.16, 0.9)
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
            let settle = min(0.04 + 1 / cameraRate, max(a - begin - 1 / cameraRate, 0))
            let arrive = manual ? min(a + rise, a + (b - a) * 0.45) : max(a - settle, begin + 1 / cameraRate)
            let releaseEnd = fixed ? outDur : (manual ? b : min(b + tail, outDur))
            let holdEnd = fixed ? outDur : (manual
                ? max(arrive, b - min(tail, (b - a) * 0.4))
                : max(arrive, b))
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
                              releaseEnd: releaseEnd, target: target, manual: manual, fixed: fixed))
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
        var manualUntil = -Double.infinity
        for shot in shots {
            if cancelled() { return nil }
            if !shot.manual && shot.start < manualUntil { continue }
            if shot.manual { manualUntil = max(manualUntil, shot.releaseEnd) }
            insert(at: shot.start, end: shot.arrive, target: shot.target)
            if !shot.fixed { insert(at: shot.holdEnd, end: shot.releaseEnd, target: Pose(focus: shot.target.focus, logScale: 0)) }
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
        let count = max(Int(ceil(outDur * cameraRate)) + 1, 2)
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
        let rate = cameraRate
        func derivatives(_ values: [Float], velocity: inout [Float], acceleration: inout [Float]) {
            guard values.count > 2 else { return }
            for i in 1..<(values.count - 1) {
                let a = Double(values[i - 1]), b = Double(values[i]), c = Double(values[i + 1])
                velocity[i] = Float((c - a) * rate / 2)
                acceleration[i] = Float((c - 2 * b + a) * rate * rate)
            }
        }
        derivatives(track.nx, velocity: &track.vx, acceleration: &track.ax)
        derivatives(track.ny, velocity: &track.vy, acceleration: &track.ay)
        derivatives(track.lz, velocity: &track.vz, acceleration: &track.az)
        if p.tilt == .lean {
            let yaw = clamp(p.maxYaw.isFinite ? p.maxYaw : 8, 0, 8)
            let pitch = clamp(p.maxPitch.isFinite ? p.maxPitch : 6, 0, 6)
            for i in track.lz.indices {
                track.yaw[i] = Float(clamp(Double(track.vx[i]) * 4, -yaw, yaw))
                track.pitch[i] = Float(clamp(-Double(track.vy[i]) * 3, -pitch, pitch))
            }
        }
        return track
    }
}
