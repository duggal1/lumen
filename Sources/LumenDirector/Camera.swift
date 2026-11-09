import Foundation
import LumenCore
import LumenProject

enum CameraSolver {
    private struct Shot { var on: Double, off: Double, lz: Double, focus: Focus, ease: Double }
    /// Two equal critically-damped springs in series (a cascade) = 4 equal
    /// real poles. Monotonic (no overshoot), and 95 % arrival at ω·t ≈ 7.75.
    private struct Cascade {
        var a: Double, av = 0.0, b: Double, bv = 0.0
        init(_ x: Double) { a = x; b = x }
        mutating func step(to target: Double, omega: Double, dt: Double) {
            springStep(&a, &av, target: target, omega: omega, dt: dt)
            springStep(&b, &bv, target: a, omega: omega, dt: dt)
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

    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams, src: SIMD2<Double>, outDur: Double, loop: Double?) -> CameraTrack {
        _ = loop
        let n = max(Int(outDur * gridRate) + 1, 2), dt = 1 / gridRate
        var tr = CameraTrack(count: n)
        let omegaIn = 7.75 / max(p.leadIn, 0.2), omegaOut = omegaIn * 0.62

        // Output-time shots. Auto shots activate `leadIn` early; manual shots
        // exactly where the user put them.
        let shots: [Shot] = zoom.compactMap { z in
            let a = tm.output(atSource: z.start), b = tm.output(atSource: z.end)
            guard b - a > 0.1, z.scale > 1.001, a < outDur else { return nil }
            return Shot(on: a - (z.origin == .auto ? p.leadIn : 0), off: b, lz: log(min(z.scale, 16)),
                        focus: z.focus, ease: z.easing?.omegaScale ?? 1)
        }.sorted { $0.on < $1.on }

        // .follow shots (manual only now) still need the dead-zone cursor path.
        var fx: [Double] = [], fy: [Double] = []
        if shots.contains(where: { if case .follow = $0.focus { true } else { false } }) {
            let halfZone = clamp(p.deadZone, 0.05, 0.45) / 2.0
            let followOmega = 1 / max(clamp(p.followDelay, 0, 0.5), 0.045)
            let rawX = (0..<n).map { Double(cursor.x[min($0, cursor.x.count - 1)]) / src.x }
            let rawY = (0..<n).map { Double(cursor.y[min($0, cursor.y.count - 1)]) / src.y }
            fx = zeroPhaseSmooth(centredPlay(rawX, halfZone: halfZone), omega: followOmega, dt: dt)
            fy = zeroPhaseSmooth(centredPlay(rawY, halfZone: halfZone), omega: followOmega, dt: dt)
        }
        func targetCenter(_ s: Shot, _ i: Int) -> SIMD2<Double> {
            var c: SIMD2<Double>
            switch s.focus {
            case .fixed(let x, let y): c = SIMD2(x, y)
            case .element(let x, let y, let w, let h): c = SIMD2(x + w / 2, y + h / 2)
            case .follow: c = SIMD2(fx[min(i, fx.count - 1)], fy[min(i, fy.count - 1)])
            }
            c -= SIMD2(clamp(p.centerOffsetX, -0.25, 0.25), clamp(p.centerOffsetY, -0.25, 0.25)) * exp(-s.lz)
            let h = 0.5 / exp(s.lz)
            return SIMD2(clamp(c.x, h, 1 - h), clamp(c.y, h, 1 - h))      // pre-clamped to the TARGET view
        }

        var cz = Cascade(0), cx = Cascade(0.5), cy = Cascade(0.5)
        var si = -1, omega = omegaIn, lastLz = 0.0
        var X = [Double](repeating: 0.5, count: n), Y = X, Z = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) * dt
            while si + 1 < shots.count, shots[si + 1].on <= t {           // latest shot wins; contiguous shots = pan, no rest in between
                si += 1
                let lz = shots[si].lz
                omega = (lz < lastLz - 1e-4 ? omegaOut : omegaIn) * shots[si].ease
                lastLz = lz
            }
            var tlz = 0.0, tc = SIMD2(0.5, 0.5)
            if si >= 0, t < shots[si].off { tlz = shots[si].lz; tc = targetCenter(shots[si], i) }
            else if lastLz != 0 { omega = omegaOut; lastLz = 0 }          // rest: zoom back out, slowly
            cx.step(to: tc.x, omega: omega, dt: dt); cy.step(to: tc.y, omega: omega, dt: dt); cz.step(to: tlz, omega: omega, dt: dt)
            let h = 0.5 / exp(cz.b)
            X[i] = clamp(cx.b, h, 1 - h); Y[i] = clamp(cy.b, h, 1 - h); Z[i] = cz.b   // safety clamp only
        }
        func deriv(_ a: [Double]) -> [Float] {
            var v = [Float](repeating: 0, count: a.count)
            if a.count > 2 {
                for i in 1..<(a.count - 1) { v[i] = Float((a[i + 1] - a[i - 1]) * gridRate / 2) }
                v[0] = v[1]; v[a.count - 1] = v[a.count - 2]
            }
            return v
        }
        tr.nx = X.map { Float($0) }; tr.ny = Y.map { Float($0) }; tr.lz = Z.map { Float($0) }
        tr.vx = deriv(X); tr.vy = deriv(Y); tr.vz = deriv(Z)
        var yaw = p.tilt == .reveal ? 12.0 : 0.0, yawV = 0.0, pitch = 0.0, pitchV = 0.0
        func phase(_ k: Int) -> Double { Double((p.tiltSeed >> UInt64(k * 8)) & 255) / 255 * 2 * .pi }
        for i in 0..<n {
            let t = Double(i) * dt, z = exp(Z[i])
            var yT = 0.0, pT = 0.0
            switch p.tilt {
            case .lean: yT = clamp(Double(tr.vx[i]) * z * 12, -p.maxYaw, p.maxYaw); pT = clamp(-Double(tr.vy[i]) * z * 9, -p.maxPitch, p.maxPitch)
            case .float:
                yT = p.floatDeg * (0.6 * sin(2 * .pi * 0.11 * t + phase(0)) + 0.4 * sin(2 * .pi * 0.07 * t + phase(1)))
                pT = p.floatDeg * (0.6 * sin(2 * .pi * 0.09 * t + phase(2)) + 0.4 * sin(2 * .pi * 0.05 * t + phase(3)))
            case .reveal, .off: break
            }
            springStep(&yaw, &yawV, target: yT, omega: p.omegaTilt, dt: dt)
            springStep(&pitch, &pitchV, target: pT, omega: p.omegaTilt, dt: dt)
            tr.yaw[i] = Float(yaw); tr.pitch[i] = Float(pitch)
        }
        return tr
    }
}
