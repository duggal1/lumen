import Foundation
import LumenCore
import LumenProject

/// The live (real-time) camera for the capture overlay: same critically
/// damped model as the recorded solver, driven causally from the event
/// stream instead of baked. Not wired into the offline derive; used by the
/// capture-time preview.
/// Threading/ownership: value type, mutated only from the capture queue that
/// ingests events (`ingest`/`step` are serialised by that queue). `Sendable`
/// for hand-off to the render side, which treats the returned `FrameState`
/// as read-only.
public struct LiveCamera: Sendable {
    public var maxScale = 2.0, hold = 2.6, omegaZoom = 7.5
    /// Minimum gap between aims. A second press inside this dwell is the same
    /// intent (double-click / rapid re-trigger) and must not move the camera.
    /// Pointer movement and scroll never aim, so they cannot reset this clock.
    public var zoomInDwell = 0.2
    public var cursor = CursorStyle()
    private let src: SIMD2<Double>
    private var t = 0.0, started = false
    private var raw: SIMD2<Double>, rawT = 0.0
    private var shape: UInt16 = 0
    private var down = false, primaryDown = false
    private var lastActivity = -1e9, lastMove = -1e9, opacity = 1.0, lzShot = 0.0
    private var lastShotActivity = -Double.infinity
    /// Timestamp of the last successful aim (click or typing-field change).
    private var lastAim = -Double.infinity
    private var pointer: Spring3, camera: Spring3, press: Spring3
    private var tgt = SIMD2<Double>(0.5, 0.5)
    private var rings: [(t: Double, x: Float, y: Float)] = []
    private var typingField: TypingFocus.Field?
    private var lastTyping = -Double.infinity
    /// Causal intelligent crop. No future events: a revealed rect is held for
    /// a fixed window and then springs back to the content ROI.
    private var cropConfig: SmartCropConfig?
    private var roiPx = CGRect.zero
    private var cropTarget = CGRect.zero
    private var cropCurrent = CGRect.zero
    private var cropUntil = -Double.infinity

    public init(source: SIMD2<Double>, smartCrop: SmartCropConfig? = nil) {
        src = source; raw = source / 2
        if let c = smartCrop, c.isActive, let r = c.roi {
            cropConfig = c
            roiPx = SmartCropPlanner.aspectFit(
                CGRect(x: r.minX * source.x, y: r.minY * source.y,
                       width: r.width * source.x, height: r.height * source.y),
                source: CGRect(x: 0, y: 0, width: source.x, height: source.y))
            cropTarget = roiPx; cropCurrent = roiPx
        }
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
        guard e.t.isFinite else { return }
        // AX replies can arrive after another key or a newer primary click.
        // Reject before crop handling as well as aiming; neither may reopen
        // the old field. Equal-time bare and resolved replies remain valid.
        if e.kind == .keyDown, e.t < max(lastTyping, lastAim) { return }
        // Integrate the previous target up to the input timestamp before
        // changing it. Late AX replies may update the current target, but
        // must never rewind the physical simulation.
        integrate(to: e.t)
        let explicit = (e.kind == .down && e.button == 0) || (e.kind == .keyDown && e.isTypingKey)
        if let config = cropConfig, explicit {
            var rect: CGRect?
            if e.kind == .keyDown, let f = focus,
               let field = TypingFocus.field(f, at: e.t, bounds: CGRect(x: 0, y: 0, width: src.x, height: src.y), backing: 1) {
                rect = field.rect
            } else if e.kind == .down, let f = focus, f.anchor?.resolved == true,
                      f.x.isFinite, f.y.isFinite, f.w.isFinite, f.h.isFinite, f.w > 0, f.h > 0 {
                rect = CGRect(x: f.x, y: f.y, width: f.w, height: f.h)
            } else if e.kind == .down, e.hasPosition, e.x.isFinite, e.y.isFinite {
                let p = SIMD2(Double(e.x), Double(e.y))
                if p.x < roiPx.minX || p.x > roiPx.maxX || p.y < roiPx.minY || p.y > roiPx.maxY {
                    rect = CGRect(x: p.x - 100, y: p.y - 20, width: 200, height: 40)
                }
            }
            if let r = rect, r.intersection(roiPx).isNull {
                let bounds = CGRect(x: 0, y: 0, width: src.x, height: src.y)
                cropTarget = SmartCropPlanner.aspectFit(
                    SmartCropPlanner.revealRect(for: r, roi: roiPx, config: config, backingScale: 1)
                        .intersection(bounds), source: bounds)
                cropUntil = e.t + max(config.returnSeconds, 0.05)
            }
        }
        if e.hasPosition, e.x.isFinite, e.y.isFinite {
            let p = SIMD2(Double(e.x), Double(e.y))
            if rawT == 0 { pointer.x = SIMD3(p.x, p.y, 0) }
            raw = p; rawT = e.t; shape = e.cursorShape
            if e.kind != .up && e.kind != .down { lastMove = e.t }
        }
        switch e.kind {
        case .down:
            down = true; lastActivity = e.t
            if e.button == 0 { primaryDown = true; typingField = nil }
            if e.x.isFinite, e.y.isFinite { rings.append((e.t, e.x, e.y)) }
            // Dwell / hysteresis: a rapid second press is the same intent, not a
            // new subject. Only the first aim in a burst gets to move the lens.
            if e.button == 0, e.hasPosition, e.x.isFinite, e.y.isFinite {
                if e.t - lastAim >= zoomInDwell {
                    aim(raw, scale: min(max(maxScale.isFinite ? maxScale : 2, 1), 1.7))
                    lastAim = e.t
                }
                if lzShot > 0 { lastShotActivity = max(lastShotActivity, e.t) }
            }
        case .up:
            down = false; lastActivity = e.t
            if e.button == 0 {
                primaryDown = false
                if lzShot > 0 { lastShotActivity = max(lastShotActivity, e.t) }
            }
        case .keyDown:
            guard e.isTypingKey, e.t >= lastTyping else { return }
            let sameRun = e.t - lastTyping <= 1.5
            lastTyping = e.t
            if !sameRun { typingField = nil }
            let bounds = CGRect(x: 0, y: 0, width: src.x, height: src.y)
            if let focus, let field = TypingFocus.field(focus, at: e.t, bounds: bounds, backing: 1),
               typingField?.matches(field, backing: 1) != true {
                let rect = field.rect
                let fit = min(src.x / (rect.width * 1.25), src.y / (rect.height * 1.25))
                let scale = max(1, min(fit, maxScale.isFinite ? maxScale : 2))
                aim(SIMD2(rect.midX, rect.midY), scale: scale)
                lastAim = e.t
                typingField = field
            }
            lastActivity = e.t
            if typingField != nil, lzShot > 0 { lastShotActivity = max(lastShotActivity, e.t) }
        case .drag, .scroll:
            lastActivity = e.t
            // Navigation can sustain an existing shot, never resurrect an
            // expired subject from a previous click.
            if lzShot > 0, primaryDown || e.t - lastShotActivity <= hold {
                lastShotActivity = max(lastShotActivity, e.t)
            }
        default: break
        }
    }
    public mutating func step(to now: Double) -> FrameState {
        integrate(to: now)
        return state(at: t)
    }

    private mutating func integrate(to now: Double) {
        guard now.isFinite else { return }
        if !started { t = now; started = true }
        guard now > t else { return }
        // A slow display callback must not turn 0.5 real seconds into 0.25
        // simulation seconds. Bound only extreme suspension gaps, where an
        // eight-second integration is more than enough for the live lens.
        if now - t > 8 { t = now - 8 }
        while t < now - 1e-9 {
            let dt = min(1.0 / 240, now - t)
            t += dt
            advance(dt)
        }
    }
    private mutating func advance(_ dt: Double) {
        let tt = t
        pointer.step(target: SIMD3(raw.x, raw.y, 0), omega: SIMD3(repeating: 110), dt: dt)
        press.step(target: SIMD3(down ? cursor.pressScale : 1, 0, 0), omega: SIMD3(repeating: 38), dt: dt)
        var on = 1.0
        if let idle = cursor.idleHide, tt - max(lastMove, lastActivity) >= idle { on = 0 }
        opacity += clamp(on - opacity, -dt / 0.4, dt / 0.15)
        rings.removeAll { tt - $0.t > max(cursor.clickDuration, 0.05) }
        let active = lzShot > 0 && (primaryDown || tt - lastShotActivity <= hold)
        if !active { lzShot = 0; typingField = nil }
        let target = active ? SIMD3(tgt.x, tgt.y, lzShot) : SIMD3(0.5, 0.5, 0)
        let omega = clamp(omegaZoom.isFinite ? omegaZoom : 7.5, 2, 16)
        camera.step(target: target, omega: SIMD3(repeating: active ? omega : min(omega, 6.5)), dt: dt)
        if cropConfig != nil {
            let targetCrop = tt > cropUntil ? roiPx : cropTarget
            let a = 1 - exp(-dt / 0.12)
            func approach(_ x: Double, _ y: Double) -> Double { x + (y - x) * a }
            cropCurrent = CGRect(
                x: approach(cropCurrent.minX, targetCrop.minX),
                y: approach(cropCurrent.minY, targetCrop.minY),
                width: approach(cropCurrent.width, targetCrop.width),
                height: approach(cropCurrent.height, targetCrop.height))
        }
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
        if cursor.clickEffect != .none {
            let dur = max(cursor.clickDuration, 0.05)
            fx = rings.filter { now >= $0.t && now - $0.t <= dur }
                .map { ClickRing(position: SIMD2($0.x, $0.y), progress: Float((now - $0.t) / dur)) }
        }
        return FrameState(cameraCenter: center, cameraScale: scale,
                          cropRect: cropConfig == nil ? .zero : cropCurrent,
                          cursor: cs,
                          clickFX: fx, webcamCrop: SIMD4(0, 0, 1, 1), sourceTime: now)
    }
}
