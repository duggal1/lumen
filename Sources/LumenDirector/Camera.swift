import Foundation
import LumenCore
import LumenProject

/// Step targets in centre/log-scale space, smoothed with one zero-phase response.
enum CameraSolver {
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
              follow: [:], cancelled: { false }) ?? CameraTrack(count: 2, rate: 240)
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
        let rate = 240.0, dt = 1 / rate
        guard outDur.isFinite, outDur > 0, src.x.isFinite, src.y.isFinite, src.x > 0, src.y > 0 else {
            return CameraTrack(count: 2, rate: rate)
        }
        let n = max(Int(outDur * rate) + 1, 2)
        let pad = Int(2 * rate), total = n + 2 * pad
        func gi(_ t: Double) -> Int { Int((t * rate).rounded()) + pad }
        struct Scene {
            var on: Double, off: Double, lz: Double
            var segment: ZoomSegment
            var path: [(t: Double, c: SIMD2<Double>)]
        }
        let lead = p.leadIn.isFinite ? max(p.leadIn, 0) : 0.30
        let scenes: [Scene] = zoom.compactMap { z -> Scene? in
            let a = tm.output(atSource: z.start), b = tm.output(atSource: z.end)
            guard a.isFinite, b.isFinite, b - a > 0.02, z.scale.isFinite, z.scale > 1.001, a < outDur else { return nil }
            let path = (follow[z.id] ?? [])
                .filter { $0.t.isFinite && $0.c.x.isFinite && $0.c.y.isFinite }
                .sorted { $0.t < $1.t }
            return Scene(on: a - (z.origin == .auto ? lead : 0), off: b + 0.15,
                         lz: log(min(z.scale, 16)), segment: z, path: path)
        }.sorted { $0.on < $1.on }

        var followX = [Double](repeating: 0.5, count: n), followY = followX
        let needsCursor = scenes.contains { s in
            if case .follow = s.segment.focus { return true }
            return false
        }
        let cursorCount = min(cursor.x.count, cursor.y.count)
        if needsCursor, cursorCount > 0 {
            let halfZone = clamp(p.deadZone.isFinite ? p.deadZone : 0.28, 0.05, 0.45) / 2
            let followOmega = 1 / max(clamp(p.followDelay.isFinite ? p.followDelay : 0.12, 0, 0.5), 0.045)
            let rawX = (0..<n).map { i in Double(cursor.x[min(Int(Double(i) * gridRate / rate), cursorCount - 1)]) / src.x }
            let rawY = (0..<n).map { i in Double(cursor.y[min(Int(Double(i) * gridRate / rate), cursorCount - 1)]) / src.y }
            followX = zeroPhaseSmooth(centredPlay(rawX, halfZone: halfZone), omega: followOmega, dt: dt)
            followY = zeroPhaseSmooth(centredPlay(rawY, halfZone: halfZone), omega: followOmega, dt: dt)
        }
        let offset = SIMD2(clamp(p.centerOffsetX, -0.25, 0.25), clamp(p.centerOffsetY, -0.25, 0.25))
        func clampCenter(_ c: SIMD2<Double>, _ lz: Double) -> SIMD2<Double> {
            let h = 0.5 / exp(lz)
            return SIMD2(clamp(c.x, h, 1 - h), clamp(c.y, h, 1 - h))
        }
        func focusCenter(_ s: Scene, grid k: Int) -> SIMD2<Double> {
            var c: SIMD2<Double>
            switch s.segment.focus {
            case .fixed(let x, let y): c = SIMD2(x, y)
            case .element(let x, let y, let w, let h): c = SIMD2(x + w / 2, y + h / 2)
            case .follow:
                let i = min(max(k - pad, 0), n - 1)
                c = SIMD2(followX[i], followY[i])
            }
            return clampCenter(c - offset * exp(-s.lz), s.lz)
        }
        func pathCenters(_ s: Scene) -> (start: Int, centers: [SIMD2<Double>])? {
            guard s.path.count >= 2, let first = s.path.first, let last = s.path.last else { return nil }
            let a = gi(first.t), b = gi(last.t)
            guard a >= 0, b < total, b > a else { return nil }
            let scale = exp(s.lz), lean = 0.12 / scale
            var xs: [Double] = [], ys: [Double] = []
            xs.reserveCapacity(b - a + 1); ys.reserveCapacity(b - a + 1)
            var j = 0
            for k in a...b {
                let t = Double(k - pad) * dt
                while j + 1 < s.path.count, s.path[j + 1].t <= t { j += 1 }
                var c = s.path[j].c
                if j + 1 < s.path.count {
                    let from = s.path[j], to = s.path[j + 1], gap = to.t - from.t
                    if gap <= 0.25 { c = from.c + (to.c - from.c) * clamp((t - from.t) / max(gap, 1e-6), 0, 1) }
                }
                xs.append(c.x + lean); ys.append(c.y)
            }
            let omega = max(p.omegaPan.isFinite ? p.omegaPan : 4, 1)
            xs = zeroPhaseSmooth(centredPlay(xs, halfZone: 0.10 / scale), omega: omega, dt: dt)
            ys = zeroPhaseSmooth(centredPlay(ys, halfZone: 0.16 / scale), omega: omega, dt: dt)
            return (a, zip(xs, ys).map { clampCenter(SIMD2($0, $1), s.lz) })
        }

        var lzT = [Double](repeating: 0, count: total)
        var cxT = [Double](repeating: 0.5, count: total), cyT = cxT
        let bridge = 1.6
        for (i, s) in scenes.enumerated() {
            if cancelled() { return nil }
            let until = (i + 1 < scenes.count && scenes[i + 1].on - s.off < bridge) ? scenes[i + 1].on : s.off
            let from = max(gi(s.on), 0), to = min(gi(until), total)
            guard to > from else { continue }
            let driven = pathCenters(s)
            for k in from..<to {
                var c = focusCenter(s, grid: k)
                if let d = driven, k >= d.start { c = d.centers[min(k - d.start, d.centers.count - 1)] }
                lzT[k] = s.lz; cxT[k] = c.x; cyT[k] = c.y
            }
        }
        let eases = zoom.compactMap { $0.easing?.omegaScale }.filter { $0.isFinite && $0 > 0 }
        let feel = eases.isEmpty ? 1 : exp(eases.map { log($0) }.reduce(0, +) / Double(eases.count))
        let omega = max((p.omegaZoom.isFinite ? p.omegaZoom : 7.5) * feel, 1)
        if cancelled() { return nil }
        let lz = zeroPhaseSmooth(lzT, omega: omega, dt: dt)
        if cancelled() { return nil }
        let cx = zeroPhaseSmooth(cxT, omega: omega, dt: dt)
        let cy = zeroPhaseSmooth(cyT, omega: omega, dt: dt)
        var X = [Double](repeating: 0.5, count: total), Y = X
        var Z = [Double](repeating: 0, count: total)
        for k in 0..<total {
            let z = max(lz[k], 0), h = 0.5 / exp(z)
            Z[k] = z
            X[k] = clamp(cx[k], h, 1 - h)
            Y[k] = clamp(cy[k], h, 1 - h)
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
            let j = i + pad
            track.nx[i] = Float(X[j]); track.ny[i] = Float(Y[j]); track.lz[i] = Float(Z[j])
            track.vx[i] = Float(dX.v[j]); track.vy[i] = Float(dY.v[j]); track.vz[i] = Float(dZ.v[j])
            track.ax[i] = Float(dX.acc[j]); track.ay[i] = Float(dY.acc[j]); track.az[i] = Float(dZ.acc[j])
        }
        var yaw = p.tilt == .reveal ? 12.0 : 0.0, yawVelocity = 0.0
        var pitch = 0.0, pitchVelocity = 0.0
        func phase(_ channel: Int) -> Double {
            Double((p.tiltSeed >> UInt64(channel * 8)) & 255) / 255 * 2 * .pi
        }
        for sample in 0..<n {
            let time = Double(sample) * dt
            let scale = exp(Z[sample + pad])
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