import Foundation
import LumenCore
import LumenProject

public let faceGridRate: Double = 120

enum WebcamFraming {
    static func solve(_ s: [FaceSample], tm: TimeMap, camera: CameraTrack, layout: WebcamLayout?) -> [SIMD3<Float>] {
        guard let lay = layout, lay.autoFrame || lay.faceZoom > 0 else { return [] }
        let fill = clamp(lay.faceFill, 0.15, 0.6)
        let raw = (lay.autoFrame && !s.isEmpty) ? s : [FaceSample(t: 0, cx: 0.5, cy: 0.45, h: Float(fill))]
        var f = raw
        func med(_ a: Float, _ b: Float, _ c: Float) -> Float { max(min(a, b), min(max(a, b), c)) }
        if raw.count >= 3 {
            for i in 1..<(raw.count - 1) {
                f[i].cx = med(raw[i - 1].cx, raw[i].cx, raw[i + 1].cx)
                f[i].cy = med(raw[i - 1].cy, raw[i].cy, raw[i + 1].cy)
                f[i].h = med(raw[i - 1].h, raw[i].h, raw[i + 1].h)
            }
        }
        func cropH(_ h: Float) -> Double { clamp(Double(h) / fill, 0.3, 1) }
        let dt = 1 / faceGridRate, n = Int(tm.outputDuration * faceGridRate) + 2
        var a = Spring3(x: SIMD3(Double(f[0].cx), Double(f[0].cy), cropH(f[0].h))), b = a
        let w = SIMD3<Double>(4.5, 4.5, 3.2)
        var out = [SIMD3<Float>](); out.reserveCapacity(n)
        var k = 0
        for i in 0..<n {
            let t = Double(i) * dt, st = tm.source(atOutput: t)
            while k < f.count - 1 && f[k + 1].t <= st { k += 1 }
            var tg = SIMD3(Double(f[k].cx), Double(f[k].cy), cropH(f[k].h))
            if k < f.count - 1, st > f[k].t {
                let gap = f[k + 1].t - f[k].t
                if gap < 0.6 {
                    let nx = SIMD3(Double(f[k + 1].cx), Double(f[k + 1].cy), cropH(f[k + 1].h))
                    tg += (nx - tg) * ((st - f[k].t) / gap)
                }
            }
            let ci = min(Int(t * gridRate), camera.lz.count - 1)
            let e = clamp(Double(camera.lz[ci]) / 0.79, 0, 1)
            tg.z = max(tg.z * (1 - 0.4 * lay.faceZoom * e), 0.28)
            a.step(target: tg, omega: w, dt: dt)
            b.step(target: a.x, omega: w, dt: dt)
            out.append(SIMD3(Float(b.x.x), Float(b.x.y), Float(b.x.z)))
        }
        return out
    }
}
