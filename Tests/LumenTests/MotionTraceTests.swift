import Foundation
import Testing
@testable import LumenProject
@testable import LumenDirector
import LumenCore

private func scriptedTimeline() throws -> Timeline {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 12, backingScale: 2, originX: 0, originY: 0)
    var tl = Timeline(duration: 12)
    tl.camera.autoZoom = true
    tl.camera.minScale = 1.1
    tl.camera.maxScale = 3.5
    tl.audio.speedRampsAuto = false
    tl.style.padding = 0
    return try Director.derive(tl, input: DirectorInput(
        events: (0..<8).map { InputEvent(t: Double($0) + 0.5, kind: .down, x: 400 + Float($0 * 150), y: 540, button: 0) },
        source: src, ax: [AXFrame(x: 400, y: 440, w: 200, h: 100, isPasswordField: false)],
        transcript: Transcript(words: [WordToken(text: "hello", start: 2.0, end: 2.3)], locale: "en")
    ), revision: 1)
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
    func maxJerk(_ x: [Double]) -> Double {
        guard x.count > 4 else { return 0 }
        var m = 0.0
        for i in 1..<(x.count - 1) {
            let v0 = (x[i - 1] - x[i - 2]) * fs, v1 = (x[i] - x[i - 1]) * fs, v2 = (x[i + 1] - x[i]) * fs
            let acc = (v2 - v0) / 2
            let jerk = (v2 - 2 * v1 + v0) * fs * fs
            m = max(m, abs(acc), abs(jerk) * 10)
        }
        return m
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
    var total = 0.0, hi = 0.0
    let m = logZoomDFTEnergy(lz, fs: fs)
    #expect(m.hi / max(m.total, 1e-9) < 0.01, "hi-freq energy fraction \(m.hi / max(m.total, 1e-9))")
    _ = maxJerk
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
