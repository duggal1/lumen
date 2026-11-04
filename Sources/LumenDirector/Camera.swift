import Foundation
import LumenCore
import LumenProject

@inline(__always) func smootherstep(_ x: Double) -> Double {
    let t = clamp(x, 0, 1); return t * t * t * t * (35 + t * (-84 + t * (70 - 20 * t)))
}

@inline(__always) func scaledSpring(_ x: inout Double, _ v: inout Double, target: Double, omega w: Double, dt: Double, scale s: Double) {
    let d = (x - target) * s, vs = v * s, e = exp(-w * dt)
    let nd = (d + (vs + w * d) * dt) * e
    let nv = (vs - w * (vs + w * d) * dt) * e
    x = target + nd / s; v = nv / s
}

enum CameraSolver {
    private struct Shot { var start: Double, end: Double, lz: Double, focus: Focus }
    private struct Key { var t: Double; var shot: Int }

    static func solve(zoom: [ZoomSegment], tm: TimeMap, cursor: CursorTrack, p: CameraParams, src: SIMD2<Double>, outDur: Double, loop: Double?) -> CameraTrack {
        let zoom = zoom.map { z in ZoomSegment(id: z.id, start: tm.output(atSource: z.start), end: tm.output(atSource: z.end), scale: z.scale, focus: z.focus, easing: z.easing, origin: z.origin) }
        _ = loop
        let n = max(Int(outDur * gridRate) + 1, 2), dt = 1 / gridRate
        var tr = CameraTrack(count: n)
        let soft = 8 / src.x, base = 4.5 / max(p.omegaZoom, 1)
        func cursorN(_ t: Double) -> SIMD2<Double> {
            let i = min(max(Int(t * gridRate), 0), cursor.x.count - 1)
            return SIMD2(Double(cursor.x[i]) / src.x, Double(cursor.y[i]) / src.y)
        }
        let shots: [Shot] = zoom.filter { $0.end - $0.start > 0.1 && $0.scale > 1.001 && $0.start < outDur }
            .sorted { $0.start < $1.start }
            .map { Shot(start: max($0.start, 0), end: min($0.end, outDur), lz: log(min($0.scale, 8)), focus: $0.focus) }
        func staticCenter(_ s: Shot, _ t: Double) -> SIMD2<Double> {
            switch s.focus {
            case .fixed(let x, let y): return SIMD2(x, y)
            case .element(let x, let y, let w, let h): return SIMD2(x + w / 2, y + h / 2)
            case .follow: return cursorN(t)
            }
        }
        func trans(_ from: Int, _ to: Int, _ t: Double) -> Double {
            let lzA = from >= 0 ? shots[from].lz : 0, lzB = to >= 0 ? shots[to].lz : 0
            let cA = from >= 0 ? staticCenter(shots[from], t) : SIMD2(0.5, 0.5)
            let cB = to >= 0 ? staticCenter(shots[to], t) : SIMD2(0.5, 0.5)
            let pan = min(hypot(cB.x - cA.x, cB.y - cA.y) / exp(-max(lzA, lzB)), 2)
            let zm = min(abs(lzB - lzA) / 0.693, 1.5)
            return base * (0.75 + 0.2 * zm + 0.2 * pan)
        }
        var keys = [Key(t: 0, shot: -1)]
        var lastT = 0.0, lastShot = -1
        for j in shots.indices {
            let s = max(shots[j].start, lastT), T = trans(lastShot, j, s)
            if s > lastT + 1e-6 { keys.append(Key(t: s, shot: lastShot)) }
            keys.append(Key(t: s + T, shot: j))
            var e = max(shots[j].end, s + T)
            let tout = 1.1 * trans(j, -1, e)
            if j + 1 < shots.count, shots[j + 1].start < e + tout + 0.25 {
                e = max(min(e, shots[j + 1].start), s + T)
                keys.append(Key(t: e, shot: j)); lastT = e; lastShot = j
            } else {
                keys.append(Key(t: e, shot: j)); keys.append(Key(t: e + tout, shot: -1))
                lastT = e + tout; lastShot = -1
            }
        }
        func center(_ s: Int, _ f: SIMD2<Double>) -> SIMD2<Double> {
            guard s >= 0 else { return SIMD2(0.5, 0.5) }
            let sh = shots[s], hw = 0.5 / exp(sh.lz)
            let c: SIMD2<Double>
            switch sh.focus {
            case .follow: c = f
            case .fixed(let x, let y): c = SIMD2(x, y)
            case .element(let x, let y, let w, let h): c = SIMD2(x + w / 2, y + h / 2)
            }
            return SIMD2(softClamp(c.x, hw, 1 - hw, soft), softClamp(c.y, hw, 1 - hw, soft))
        }
        var cx = [Double](repeating: 0.5, count: n), cy = cx, cz = [Double](repeating: 0, count: n)
        var x1 = SIMD2<Double>(0.5, 0.5), v1 = SIMD2<Double>.zero, x2 = x1, v2 = SIMD2<Double>.zero
        var tgt = SIMD2<Double>(0.5, 0.5), ki = 0
        for i in 0..<n {
            let t = Double(i) * dt
            while ki + 1 < keys.count && keys[ki + 1].t <= t { ki += 1 }
            let k0 = keys[ki], k1 = ki + 1 < keys.count ? keys[ki + 1] : keys[ki]
            let pr = k1.t > k0.t ? smootherstep((t - k0.t) / (k1.t - k0.t)) : 0
            let a = k0.shot, b = k1.shot
            let lzA = a >= 0 ? shots[a].lz : 0, lzB = b >= 0 ? shots[b].lz : 0
            let lz = lerp(lzA, lzB, pr)
            var lzc = lz
            for sh in shots { if sh.start - 1.0 > t { break }; if t <= sh.end { lzc = max(lzc, sh.lz) } }
            let sc = exp(lzc), half = p.deadZone / sc, hw = 0.5 / sc
            let cur = cursorN(t)
            for k in 0..<2 {
                let d = cur[k] - tgt[k]
                if d > half { tgt[k] = cur[k] - half } else if d < -half { tgt[k] = cur[k] + half }
                let lim = clamp(tgt[k], hw, 1 - hw)
                scaledSpring(&x1[k], &v1[k], target: lim, omega: p.omegaPan, dt: dt, scale: sc)
                scaledSpring(&x2[k], &v2[k], target: x1[k], omega: p.omegaPan, dt: dt, scale: sc)
            }
            let cA = center(a, x2), cB = center(b, x2)
            let wA = exp(-lzA), wB = exp(-lzB), w = exp(-lz)
            let q = abs(wB - wA) > 1e-5 ? (w - wA) / (wB - wA) : pr
            let c = cA + (cB - cA) * q, h = 0.5 / exp(lz)
            cx[i] = clamp(c.x, h, 1 - h); cy[i] = clamp(c.y, h, 1 - h); cz[i] = lz
        }
        func deriv(_ a: [Double]) -> [Float] {
            var v = [Float](repeating: 0, count: a.count)
            if a.count > 2 {
                for i in 1..<(a.count - 1) { v[i] = Float((a[i + 1] - a[i - 1]) * gridRate / 2) }
                v[0] = v[1]; v[a.count - 1] = v[a.count - 2]
            }
            return v
        }
        tr.nx = cx.map { Float($0) }; tr.ny = cy.map { Float($0) }; tr.lz = cz.map { Float($0) }
        tr.vx = deriv(cx); tr.vy = deriv(cy); tr.vz = deriv(cz)
        var yaw = p.tilt == .reveal ? 12.0 : 0.0, yawV = 0.0, pitch = 0.0, pitchV = 0.0
        func phase(_ k: Int) -> Double { Double((p.tiltSeed >> UInt64(k * 8)) & 255) / 255 * 2 * .pi }
        for i in 0..<n {
            let t = Double(i) * dt, z = exp(cz[i])
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

    static func softClamp(_ v: Double, _ lo: Double, _ hi: Double, _ s: Double) -> Double {
        func f(_ d: Double) -> Double { d >= s ? d : s * exp(d / s - 1) }
        let mid = (lo + hi) / 2
        let a = lo + f(v - lo), c = hi - f(hi - a)
        return lerp(mid, c, smoothstep((hi - lo) / (2 * s)))
    }
}
