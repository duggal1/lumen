import Foundation
import LumenCore
import LumenProject

enum CameraSolver {
    /// Cascade of two critically damped springs (C2). Zoom in log space, pan in source-normalized coords. Runs in OUTPUT time.
    static func solve(zoom: [ZoomSegment], cursor: CursorTrack, p: CameraParams, src: SIMD2<Double>, outDur: Double) -> CameraTrack {
        let n = max(Int(outDur * gridRate) + 1, 2), dt = 1 / gridRate
        var tr = CameraTrack(count: n)
        let zs = zoom.sorted { $0.start < $1.start }
        var s1 = Spring3(x: [0.5, 0.5, 0]), s2 = s1
        let omega = SIMD3<Double>(p.omegaPan, p.omegaPan, p.omegaZoom)
        var prev = SIMD2<Double>(0.5, 0.5), lastID: UUID? = nil, si = 0
        let soft = 8 / src.x
        func cursorN(_ t: Double) -> SIMD2<Double> {
            let i = min(max(Int(t * gridRate), 0), cursor.x.count - 1)
            return SIMD2(Double(cursor.x[i]) / src.x, Double(cursor.y[i]) / src.y)
        }
        for i in 0..<n {
            let t = Double(i) * dt
            while si < zs.count && zs[si].end <= t { si += 1 }
            var active: ZoomSegment?, k = si
            while k < zs.count && zs[k].start <= t { if zs[k].end > t { active = zs[k] }; k += 1 }
            let lz = active.map { log($0.scale) } ?? 0
            var tgt = SIMD2<Double>(0.5, 0.5)
            if let a = active {
                switch a.focus {
                case .fixed(let x, let y): tgt = SIMD2(x, y)
                case .element(let x, let y, let w, let h): tgt = SIMD2(x + w / 2, y + h / 2)
                case .follow:
                    let c = cursorN(t + p.lookahead)                     // lookahead: camera arrives with the cursor
                    if a.id != lastID { tgt = c } else {
                        let half = p.deadZone / exp(s2.x.z)              // dead-zone hysteresis around current center
                        let cc = SIMD2<Double>(s2.x.x, s2.x.y)
                        tgt = prev
                        for j in 0..<2 {
                            let d = c[j] - cc[j]
                            if d > half { tgt[j] = c[j] - half } else if d < -half { tgt[j] = c[j] + half }
                        }
                    }
                }
            }
            lastID = active?.id
            let hz = 0.5 / exp(lz)
            tgt = SIMD2(clamp(tgt.x, hz, 1 - hz), clamp(tgt.y, hz, 1 - hz)); prev = tgt
            s1.step(target: SIMD3(tgt.x, tgt.y, lz), omega: omega, dt: dt)
            s2.step(target: s1.x, omega: omega, dt: dt)
            let h = 0.5 / exp(s2.x.z)
            tr.nx[i] = Float(softClamp(s2.x.x, h, 1 - h, soft))
            tr.ny[i] = Float(softClamp(s2.x.y, h, 1 - h, soft))
            tr.lz[i] = Float(s2.x.z); tr.vx[i] = Float(s2.v.x); tr.vy[i] = Float(s2.v.y); tr.vz[i] = Float(s2.v.z)
        }
        return tr
    }

    /// C1 soft clamp: the view rect can never leave the source.
    static func softClamp(_ v: Double, _ lo: Double, _ hi: Double, _ s: Double) -> Double {
        func f(_ d: Double) -> Double { d >= s ? d : s * exp(d / s - 1) }
        let mid = (lo + hi) / 2
        let a = lo + f(v - lo)
        let c = hi - f(hi - a)
        return lerp(mid, c, smoothstep((hi - lo) / (2 * s)))
    }
}