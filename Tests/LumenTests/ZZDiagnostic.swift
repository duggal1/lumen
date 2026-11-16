import Foundation
import Testing
@testable import LumenProject
@testable import LumenDirector
import LumenCore

@Test func zzDiagnosticJerk() throws {
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 12, backingScale: 2, originX: 0, originY: 0)
    var tl = Timeline(duration: 12)
    tl.camera.autoZoom = true
    tl.camera.minScale = 1.1
    tl.camera.maxScale = 3.5
    tl.audio.speedRampsAuto = false
    tl.style.padding = 0
    tl = try Director.derive(tl, input: DirectorInput(
        events: (0..<8).map {
            InputEvent(t: Double($0) + 0.5, kind: .down, x: 400 + Float($0 * 150),
                       y: 540, button: 0)
        },
        source: src, ax: [AXFrame(x: 400, y: 440, w: 200, h: 100)],
        transcript: Transcript(words: [WordToken(text: "hello", start: 2.0, end: 2.3)], locale: "en")
    ), revision: 1)
    let fs = 240.0
    let n = Int(tl.compositionDuration * fs)
    var cx = [Double]()
    for i in 0..<n {
        let f = tl.evaluate(at: Double(i) / fs)
        cx.append(Double(f.cameraCenter.x))
    }
    var worst: [(j: Double, t: Double, acc: Double, x0: Double, x1: Double, x2: Double, x3: Double)] = []
    for i in 2..<(n - 1) {
        let v0 = (cx[i-1] - cx[i-2]) * fs, v1 = (cx[i] - cx[i-1]) * fs, v2 = (cx[i+1] - cx[i]) * fs
        let acc = (v2 - v0) / 2
        let jerk = (v2 - 2*v1 + v0) * fs * fs
        worst.append((max(abs(acc), abs(jerk)*10), Double(i)/fs, acc, cx[i-2], cx[i-1], cx[i], cx[i+1]))
    }
    worst.sort { $0.j > $1.j }
    for w in worst.prefix(12) {
        print("DIAG t=\(String(format: "%.4f", w.t)) metric=\(String(format: "%.3e", w.j)) acc=\(String(format: "%.3e", w.acc)) xs=\(w.x0),\(w.x1),\(w.x2),\(w.x3)")
    }
    print("DIAG zoom count=\(tl.zoom.count) camera rate=\(tl.derived?.camera.rate ?? -1)")
    for z in tl.zoom { print("DIAG zoom \(z.start)...\(z.end) scale=\(z.scale) focus=\(z.focus)") }
}
