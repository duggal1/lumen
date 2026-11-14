import Foundation
import LumenCore
import LumenProject

public struct LiveCamera: Sendable {
    public var maxScale = 2.0, hold = 2.6, omegaZoom = 7.5
    public var cursor = CursorStyle()
    private let src: SIMD2<Double>
    private var t = 0.0, started = false
    private var raw: SIMD2<Double>, rawT = 0.0
    private var shape: UInt16 = 0
    private var down = false
    private var lastActivity = -1e9, lastMove = -1e9, opacity = 1.0, lzShot = 0.0
    private var pointer: Spring3, camera: Spring3, press: Spring3
    private var tgt = SIMD2<Double>(0.5, 0.5)
    private var rings: [(t: Double, x: Float, y: Float)] = []
    private var focusTime = -Double.infinity

    public init(source: SIMD2<Double>) {
        src = source; raw = source / 2
        pointer = Spring3(x: SIMD3(source.x / 2, source.y / 2, 0))
        camera = Spring3(x: SIMD3(0.5, 0.5, 0))
        press = Spring3(x: SIMD3(1, 0, 0))
    }
    private func norm(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(p.x / src.x, p.y / src.y) }
    private mutating func aim(_ point: SIMD2<Double>, scale: Double) {
        let half = 0.5 / scale, c = norm(point)
        tgt = SIMD2(clamp(c.x, half, 1 - half), clamp(c.y, half, 1 - half))
        lzShot = log(scale)
    }
    public mutating func ingest(_ e: InputEvent, focus: AXFrame? = nil) {
        if e.hasPosition {
            let p = SIMD2(Double(e.x), Double(e.y))
            if rawT == 0 { pointer.x = SIMD3(p.x, p.y, 0) }
            raw = p; rawT = e.t; shape = e.cursorShape
            if e.kind != .up && e.kind != .down { lastMove = e.t }
        }
        switch e.kind {
        case .down:
            down = true; lastActivity = e.t; focusTime = e.t
            rings.append((e.t, e.x, e.y))
            if e.button == 0 { aim(raw, scale: min(max(maxScale, 1), 1.7)) }
        case .up: down = false; lastActivity = e.t
        case .keyDown:
            lastActivity = max(lastActivity, e.t)
            guard e.t >= focusTime, let f = focus,
                  f.x.isFinite, f.y.isFinite, f.w.isFinite, f.h.isFinite,
                  f.w > 0, f.h > 0 else { return }
            focusTime = e.t
            if let c = f.caret, c.x.isFinite, c.y.isFinite, c.w.isFinite, c.h.isFinite, c.h > 0 {
                let point = SIMD2(c.w <= 3 ? c.x + c.w / 2 : c.x + c.w, c.y + c.h / 2)
                guard point.x >= 0, point.x <= src.x, point.y >= 0, point.y <= src.y else { return }
                let fieldWidth = min(max(f.w * 1.3, src.x * 0.42), src.x * 0.62)
                aim(point, scale: min(clamp(src.x / fieldWidth, 1.6, 2), max(maxScale, 1)))
            } else if f.h <= src.y * 0.12 {
                let fit = src.x / max(f.w * 1.25, 1)
                if fit >= 1.25 { aim(SIMD2(f.x + f.w / 2, f.y + f.h / 2), scale: min(fit, maxScale, 2)) }
            }
        case .drag, .scroll: lastActivity = e.t
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
        pointer.step(target: SIMD3(raw.x, raw.y, 0), omega: SIMD3(repeating: 110), dt: dt)
        press.step(target: SIMD3(down ? cursor.pressScale : 1, 0, 0), omega: SIMD3(repeating: 38), dt: dt)
        var on = 1.0
        if let idle = cursor.idleHide, tt - max(lastMove, lastActivity) >= idle { on = 0 }
        opacity += clamp(on - opacity, -dt / 0.4, dt / 0.15)
        rings.removeAll { tt - $0.t > max(cursor.clickDuration, 0.05) }
        let active = down || tt - lastActivity <= hold
        let target = active ? SIMD3(tgt.x, tgt.y, lzShot) : SIMD3(0.5, 0.5, 0)
        camera.step(target: target, omega: SIMD3(repeating: omegaZoom), dt: dt)
    }
    private func state(at now: Double) -> FrameState {
        let lz = max(camera.x.z, 0)
        let c = SIMD2(camera.x.x, camera.x.y)
        let scale = Float(exp(lz))
        let half = SIMD2(Float(src.x / 2) / scale, Float(src.y / 2) / scale)
        let center = SIMD2(
            min(max(Float(c.x * src.x), half.x), Float(src.x) - half.x),
            min(max(Float(c.y * src.y), half.y), Float(src.y) - half.y)
        )
        let cs = CursorSample(position: SIMD2(Float(pointer.x.x), Float(pointer.x.y)), velocity: SIMD2(Float(pointer.v.x), Float(pointer.v.y)),
                              opacity: Float(smoothstep(opacity)), press: Float(press.x.x), shape: shape)
        var fx: [ClickRing] = []
        // Mirror the offline gate: no rings when the effect is off, and the
        // window follows clickDuration (not a hardcoded 0.8 s).
        if cursor.clickRing != nil, cursor.clickEffect != .none {
            let dur = max(cursor.clickDuration, 0.05)
            fx = rings.filter { now >= $0.t && now - $0.t <= dur }
                .map { ClickRing(position: SIMD2($0.x, $0.y), progress: Float((now - $0.t) / dur)) }
        }
        return FrameState(cameraCenter: center, cameraScale: scale, cursor: cs,
                          clickFX: fx, webcamCrop: SIMD4(0, 0, 1, 1), sourceTime: now)
    }
}
