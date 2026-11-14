import Foundation
import Testing
@testable import LumenProject
@testable import LumenDirector
import LumenCore

private func scriptedTimeline(diagonal: Bool = false) throws -> Timeline {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 12, backingScale: 2, originX: 0, originY: 0)
    var tl = Timeline(duration: 12)
    tl.camera.autoZoom = true
    tl.camera.minScale = 1.1
    tl.camera.maxScale = 3.5
    tl.audio.speedRampsAuto = false
    tl.style.padding = 0
    return try Director.derive(tl, input: DirectorInput(
        events: (0..<8).map {
            InputEvent(t: Double($0) + 0.5, kind: .down, x: 400 + Float($0 * 150),
                       y: diagonal ? ($0.isMultiple(of: 2) ? 400 : 700) : 540, button: 0)
        },
        source: src, ax: [AXFrame(x: 400, y: 440, w: 200, h: 100)],
        transcript: Transcript(words: [WordToken(text: "hello", start: 2.0, end: 2.3)], locale: "en")
    ), revision: 1)
}

/// A one-click timeline: zoom in at 2 s, hold, then one finite zoom-out.
private func singleClickTimeline() throws -> Timeline {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 8, backingScale: 1, originX: 0, originY: 0)
    var tl = Timeline(duration: 8)
    tl.audio.speedRampsAuto = false
    return try Director.derive(tl, input: DirectorInput(
        events: [InputEvent(t: 2, kind: .down, x: 700, y: 400)], source: src), revision: 1)
}

/// Bounded-motion metric: peak of |acceleration| and 10·|jerk|, the jerk term
/// dominating so a spiky curve is caught even when acceleration is modest.
private func maxJerk(_ x: [Double], fs: Double) -> Double {
    guard x.count > 4 else { return 0 }
    var m = 0.0
    for i in 2..<(x.count - 1) {
        let v0 = (x[i - 1] - x[i - 2]) * fs, v1 = (x[i] - x[i - 1]) * fs, v2 = (x[i + 1] - x[i]) * fs
        let acc = (v2 - v0) / 2
        let jerk = (v2 - 2 * v1 + v0) * fs * fs
        m = max(m, abs(acc), abs(jerk) * 10)
    }
    return m
}

private func logZoomDFTEnergy(_ x: [Double], fs: Double) -> (total: Double, hi: Double) {
    var n = 1
    while n < x.count { n <<= 1 }
    let mean = x.reduce(0, +) / Double(x.count)
    var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
    for i in 0..<x.count {
        let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(max(x.count - 1, 1)))
        re[i] = (x[i] - mean) * w
    }
    var j = 0
    for i in 1..<n {
        var bit = n >> 1
        while j & bit != 0 { j ^= bit; bit >>= 1 }
        j ^= bit
        if i < j { re.swapAt(i, j); im.swapAt(i, j) }
    }
    var len = 2
    while len <= n {
        let ang = -2 * Double.pi / Double(len)
        for s in stride(from: 0, to: n, by: len) {
            for k in 0..<(len / 2) {
                let wr = cos(ang * Double(k)), wi = sin(ang * Double(k))
                let a = s + k, b = a + len / 2
                let tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr
                re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti
            }
        }
        len <<= 1
    }
    var total = 0.0, hi = 0.0
    for k in 1..<(n / 2) {
        let e = re[k] * re[k] + im[k] * im[k]
        total += e
        if Double(k) * fs / Double(n) > 8 { hi += e }
    }
    return (total, hi)
}

@Test func motionTracesAreSmooth() throws {
    let tl = try scriptedTimeline()
    let fs = 240.0
    let n = Int(tl.compositionDuration * fs)
    var cx = [Double](), cy = [Double](), lz = [Double]()
    for i in 0..<n {
        let t = Double(i) / fs
        let f = tl.evaluate(at: t)
        cx.append(Double(f.cameraCenter.x)); cy.append(Double(f.cameraCenter.y)); lz.append(log(Double(f.cameraScale)))
    }
    // No position discontinuities >40px per frame step at 240Hz
    func maxStep(_ x: [Double]) -> Double {
        var m = 0.0
        for i in 1..<x.count { m = max(m, abs(x[i] - x[i - 1])) }
        return m
    }
    #expect(maxStep(cx) < 40, "camX step \(maxStep(cx))px")
    #expect(maxStep(cy) < 40, "camY step \(maxStep(cy))px")
    // Energy above 8Hz via DFT on log-zoom
    let m = logZoomDFTEnergy(lz, fs: fs)
    #expect(m.hi / max(m.total, 1e-9) < 0.01, "hi-freq energy fraction \(m.hi / max(m.total, 1e-9))")
    // Bounded motion: the camera is a deliberate move, not a spiky track.
    // A quintic of distance d over T has peak acceleration ~5.77·d/T² and
    // peak jerk ~60·d/T³; a 1000 px move over 0.55 s is ~1.9e4 px/s² and
    // ~3.6e5 px/s³. The ×10 jerk term puts the bound at ~3.6e6; a track whose
    // acceleration is forced to zero at every stored sample spikes well past it.
    #expect(maxJerk(cx, fs: fs) < 1e7, "pan jerk \(maxJerk(cx, fs: fs))")
    #expect(maxJerk(cy, fs: fs) < 1e7, "pan jerk \(maxJerk(cy, fs: fs))")
    #expect(maxJerk(lz, fs: fs) < 1e7, "zoom jerk \(maxJerk(lz, fs: fs))")
}

/// DEFECT 1: the camera track must publish the derivatives of the trajectory
/// it actually generated. A zeroed acceleration array makes `qhm` manufacture
/// a zero-acceleration endpoint at every stored sample, which steps the
/// acceleration 240 times a second (the "robotic" feel).
@Test func cameraTrackPublishesAcceleration() throws {
    // A horizontal-only scene has no vertical motion, so its y derivative is
    // legitimately zero. Drive both axes here: the assertion is about the
    // published derivatives, not about inventing motion.
    let tl = try scriptedTimeline(diagonal: true)
    guard let cam = tl.derived?.camera else {
        Issue.record("no derived camera")
        return
    }
    #expect(cam.ax.contains { abs($0) > 1e-4 }, "camera track publishes no x acceleration")
    #expect(cam.ay.contains { abs($0) > 1e-4 }, "camera track publishes no y acceleration")
    #expect(cam.az.contains { abs($0) > 1e-4 }, "camera track publishes no log-zoom acceleration")
    // The published velocity and acceleration must be consistent with the
    // stored positions (a finite-difference sanity check, not a copy).
    let i = cam.ax.indices.dropFirst().first { abs(cam.ax[$0]) > 1e-3 } ?? 0
    if i > 0, i + 1 < cam.ax.count {
        let fd = (Double(cam.nx[i + 1]) - 2 * Double(cam.nx[i]) + Double(cam.nx[i - 1])) * cam.rate * cam.rate
        #expect(abs(Double(cam.ax[i]) - fd) < 50, "ax \(cam.ax[i]) vs finite-diff \(fd)")
    }
}

/// DEFECT 1 (sub-sample): sample the EVALUATED trajectory between stored
/// ticks. A smooth curve has no special acceleration discontinuity at the
/// 240 Hz sample boundaries. The old zero-acceleration reconstruction forces
/// acceleration to zero at every tick, so the boundary step dwarfs the
/// interior step.
@Test func evaluatedAccelerationHasNoTickBoundaryStep() throws {
    let tl = try scriptedTimeline()
    let fs = 960.0                       // 4× the 240 Hz camera tick
    let n = Int(tl.compositionDuration * fs)
    guard n > 16 else { return }
    var lz = [Double](repeating: 0, count: n)
    var cx = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let f = tl.evaluate(at: Double(i) / fs)
        lz[i] = log(Double(f.cameraScale)); cx[i] = Double(f.cameraCenter.x)
    }
    func accel(_ x: [Double], _ i: Int) -> Double { (x[i + 1] - 2 * x[i] + x[i - 1]) * fs * fs }
    var boundary = 0.0, interior = 0.0, moving = 0.0
    for i in 2..<(n - 2) {
        let speed = abs(lz[i + 1] - lz[i - 1]) * fs + abs(cx[i + 1] - cx[i - 1]) * fs / 1000
        guard speed > 0.02 else { continue }
        moving += 1
        let step = max(abs(accel(lz, i + 1) - accel(lz, i - 1)),
                       abs(accel(cx, i + 1) - accel(cx, i - 1)) / 1000)
        if i % 4 == 0 { boundary = max(boundary, step) } else { interior = max(interior, step) }
    }
    #expect(moving > 20, "no moving samples to check")
    #expect(interior > 1e-6, "no interior acceleration to compare against")
    // The boundary step must be the same order as the interior step.
    #expect(boundary <= interior * 1.6 + 1e-3,
            "tick-boundary acceleration step \(boundary) vs interior \(interior)")
}

/// DEFECT 7: the exit is the same quality as the entrance. One finite curve
/// reaches scale 1 and stays there — no snap, no crawl, no bounce.
@Test func zoomOutReachesFullFrameAndStays() throws {
    let tl = try singleClickTimeline()
    // The scene ends ~3 s; the 750 ms zoom-out is done well before 4.2 s.
    let a = Double(tl.evaluate(at: 4.2).cameraScale)
    let b = Double(tl.evaluate(at: 5.2).cameraScale)
    let c = Double(tl.evaluate(at: 6.5).cameraScale)
    #expect(abs(a - 1) < 1e-3, "scale at 4.2 = \(a)")
    #expect(abs(b - 1) < 1e-3, "scale at 5.2 = \(b)")
    #expect(abs(c - 1) < 1e-3, "scale at 6.5 = \(c)")
    // Monotonic zoom-out: no overshoot below 1 and no bounce back above 1.
    let fs = 240.0
    var prev = Double(tl.evaluate(at: 3.0).cameraScale)
    for i in 1...Int(2.0 * fs) {
        let s = Double(tl.evaluate(at: 3.0 + Double(i) / fs).cameraScale)
        #expect(s >= 1 - 1e-6, "scale dipped below 1: \(s)")
        #expect(s <= prev + 1e-4, "scale rose during zoom-out: \(s) > \(prev)")
        prev = s
    }
}

/// DEFECT 2/3: during typing the camera follows one continuous target path;
/// it does not re-ease a smoothed path and does not stop-then-lurch on a
/// multi-second gate. The camera keeps the caret in the reading band while
/// the caret moves.
@Test func typingKeepsCaretFramedWithoutTrailing() throws {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 12,
                         backingScale: 1, originX: 0, originY: 0)
    var events: [InputEvent] = []
    for i in 0..<20 { events.append(InputEvent(t: 3.0 + Double(i) * 0.25, kind: .keyDown, keyCode: 7)) }
    // A caret that walks steadily right, inside one field.
    let samples = (0..<20).map { TypingTrace.Sample(t: 3.0 + Double($0) * 0.25,
                                                    x: 300 + Double($0) * 55, y: 540) }
    let trace = TypingTrace(t0: 3.0, t1: 7.75, rect: CGRect(x: 280, y: 520, width: 1400, height: 36), samples: samples)
    var tl = Timeline(duration: 12)
    tl.audio.speedRampsAuto = false
    let out = Director.derive(tl, input: DirectorInput(events: events, source: src, typing: [trace]), revision: 1)
    let scenes = out.zoom.filter { $0.end >= 3.0 && $0.start <= 7.75 }
    #expect(scenes.count - 1 <= 3, "typing split into \(scenes.count) scenes")
    for s in samples where s.t >= 3.0 && s.t <= 7.75 {
        let f = out.evaluate(at: s.t)
        let scale = Double(f.cameraScale)
        let halfX = 1920.0 / (2 * scale), halfY = 1080.0 / (2 * scale)
        let dx = (s.x - Double(f.cameraCenter.x)) / halfX
        let dy = (s.y - Double(f.cameraCenter.y)) / halfY
        #expect(abs(dx) < 1.0, "caret left the viewport: dx=\(dx) at t=\(s.t)")
        #expect(abs(dy) <= 0.62, "dy=\(dy) at t=\(s.t)")
    }
}
/// C2 at semantic handoffs: where one shot's move ends and the next begins,
/// position, velocity and acceleration must match. A retarget that restarts
/// from rest, or a handoff that re-eases an already-smoothed path, shows up as
/// an acceleration outlier between two stored ticks. Sampled five times finer
/// than the 240 Hz track, so the check reads the generating curve rather than
/// its endpoints.
@Test func handoffsKeepAccelerationContinuous() throws {
    let tl = try scriptedTimeline(diagonal: true)
    guard let cam = tl.derived?.camera, cam.rate > 0 else {
        Issue.record("no derived camera")
        return
    }
    let fs = 1200.0
    let n = Int(tl.compositionDuration * fs)
    guard n > 16 else { return }
    var cx = [Double](repeating: 0, count: n), cy = cx
    for i in 0..<n {
        let f = tl.evaluate(at: Double(i) / fs)
        cx[i] = Double(f.cameraCenter.x); cy[i] = Double(f.cameraCenter.y)
    }
    // Published acceleration is the bound the generating curve obeys.
    let bound = Double((cam.ax.map { abs($0) }.max() ?? 0))
        * Double(tl.derived?.sourceSize.x ?? 1) * 2 + 1
    var peak = 0.0
    for i in 1..<(n - 1) {
        let ax = (cx[i + 1] - 2 * cx[i] + cx[i - 1]) * fs * fs
        let ay = (cy[i + 1] - 2 * cy[i] + cy[i - 1]) * fs * fs
        peak = max(peak, hypot(ax, ay))
    }
    #expect(peak > 1, "the camera never moves; the fixture proves nothing")
    #expect(peak <= bound, "acceleration spike \(peak) px/s² exceeds the published bound \(bound)")
}
