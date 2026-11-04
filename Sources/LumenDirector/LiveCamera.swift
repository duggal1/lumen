import Foundation
import LumenCore
import LumenProject

/// Causal camera. The owner serializes event ingestion and display updates.
public struct LiveCamera: Sendable {
    public var maxScale = 2.2, hold = 1.6, omegaZoom = 8.0, omegaPan = 7.0, lookahead = 0.15, deadZone = 0.28
    public var cursor = CursorStyle()
    private let src: SIMD2<Double>
    private var t = 0.0, started = false
    private var raw: SIMD2<Double>, rawT = 0.0, vel = SIMD2<Double>.zero
    private var shape: UInt16 = 0
    private var down = false, zoomed = false
    private var lastActivity = -1e9, lastMove = -1e9, opacity = 1.0, lzShot = 0.0
    private var cur1: Spring3, cur2: Spring3, zoom1: Spring3, zoom2: Spring3, press: Spring3
    private var tgt = SIMD2<Double>(0.5, 0.5)
    private var fx1 = SIMD2<Double>(0.5, 0.5), fv1 = SIMD2<Double>.zero, fx2 = SIMD2<Double>(0.5, 0.5), fv2 = SIMD2<Double>.zero
    private var rings: [(t: Double, x: Float, y: Float)] = []

    public init(source: SIMD2<Double>) {
        src = source; raw = source / 2
        cur1 = Spring3(x: SIMD3(source.x / 2, source.y / 2, 0)); cur2 = cur1
        zoom1 = Spring3(x: .zero); zoom2 = zoom1
        press = Spring3(x: SIMD3(1, 0, 0))
    }
    private func norm(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(p.x / src.x, p.y / src.y) }
    public mutating func ingest(_ e: InputEvent) {
        if e.hasPosition {
            let p = SIMD2(Double(e.x), Double(e.y))
            if rawT == 0 { cur1.x = SIMD3(p.x, p.y, 0); cur2.x = cur1.x }
            else if e.t > rawT { vel += ((p - raw) / max(e.t - rawT, 0.004) - vel) * 0.3 }
            raw = p; rawT = e.t; shape = e.cursorShape
            if e.kind != .up && e.kind != .down { lastMove = e.t }
        }
        switch e.kind {
        case .down:
            down = true; lastActivity = e.t; rings.append((e.t, e.x, e.y))
            if !zoomed {
                let atRest = zoom2.x.x < 0.03
                zoomed = true; lzShot = log(maxScale)
                let c = norm(SIMD2(Double(e.x), Double(e.y))), hw = 0.5 / maxScale
                tgt = SIMD2(clamp(c.x, hw, 1 - hw), clamp(c.y, hw, 1 - hw))
                if atRest { fx1 = tgt; fx2 = tgt; fv1 = .zero; fv2 = .zero }
            }
        case .up: down = false; lastActivity = e.t
        case .drag, .scroll, .keyDown: lastActivity = e.t
        default: break
        }
    }
    public mutating func step(to now: Double) -> FrameState {
        if !started { t = now; started = true }
        if now - t > 0.25 { t = now - 0.25 }
        while t < now - 1e-9 { let dt = min(1.0 / 240, now - t); t += dt; advance(dt) }
        return state(at: now)
    }
    private mutating func advance(_ dt: Double) {
        let tt = t
        vel *= exp(-dt / 0.08)
        let wc = SIMD3<Double>(repeating: 110)
        cur1.step(target: SIMD3(raw.x, raw.y, 0), omega: wc, dt: dt)
        cur2.step(target: cur1.x, omega: wc, dt: dt)
        press.step(target: SIMD3(down ? cursor.pressScale : 1, 0, 0), omega: SIMD3(repeating: 38), dt: dt)
        var on = 1.0
        if let idle = cursor.idleHide, tt - max(lastMove, lastActivity) >= idle { on = 0 }
        opacity += clamp(on - opacity, -dt / 0.4, dt / 0.15)
        rings.removeAll { tt - $0.t > 0.8 }
        if zoomed && !down && tt - lastActivity > hold { zoomed = false }
        let wz = SIMD3<Double>(repeating: omegaZoom)
        zoom1.step(target: SIMD3(zoomed ? 1 : 0, 0, 0), omega: wz, dt: dt)
        zoom2.step(target: zoom1.x, omega: wz, dt: dt)
        let sc = exp(lzShot), hw = 0.5 / sc
        if zoomed {
            let pred = norm(raw + vel * lookahead), half = deadZone / sc
            for k in 0..<2 {
                let d = pred[k] - tgt[k]
                if d > half { tgt[k] = pred[k] - half } else if d < -half { tgt[k] = pred[k] + half }
                tgt[k] = clamp(tgt[k], hw, 1 - hw)
            }
        }
        for k in 0..<2 {
            scaledSpring(&fx1[k], &fv1[k], target: tgt[k], omega: omegaPan, dt: dt, scale: sc)
            scaledSpring(&fx2[k], &fv2[k], target: fx1[k], omega: omegaPan, dt: dt, scale: sc)
        }
    }
    private func state(at now: Double) -> FrameState {
        let z = clamp(zoom2.x.x, 0, 1), lz = lzShot * z
        let wS = exp(-lzShot), w = exp(-lz)
        let q = abs(wS - 1) > 1e-5 ? (w - 1) / (wS - 1) : z
        let hw = 0.5 / exp(lzShot), soft = 8 / src.x
        let f = SIMD2(CameraSolver.softClamp(fx2.x, hw, 1 - hw, soft), CameraSolver.softClamp(fx2.y, hw, 1 - hw, soft))
        let c = SIMD2(0.5, 0.5) + (f - SIMD2(0.5, 0.5)) * q
        let cs = CursorSample(position: SIMD2(Float(cur2.x.x), Float(cur2.x.y)), velocity: SIMD2(Float(cur2.v.x), Float(cur2.v.y)),
                              opacity: Float(smoothstep(opacity)), press: Float(press.x.x), shape: shape)
        var fx: [ClickRing] = []
        if let dur = cursor.clickRing {
            fx = rings.filter { now >= $0.t && now - $0.t <= dur }
                .map { ClickRing(position: SIMD2($0.x, $0.y), progress: Float((now - $0.t) / dur)) }
        }
        return FrameState(cameraCenter: SIMD2(Float(c.x * src.x), Float(c.y * src.y)), cameraScale: Float(exp(lz)), cursor: cs,
                          clickFX: fx, webcamCrop: SIMD4(0, 0, 1, 1), sourceTime: now)
    }
}
