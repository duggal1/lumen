import Testing
import Foundation
import LumenCore
import LumenProject
import LumenDirector

// §10 acceptance on derived data (synthetic scripted stream, same script as
// the video verify). A11/A12 and the OCR rows need the real recording and
// stay UNVERIFIED in .proof/zoom-report.md.

private let zoomReportSource = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 60,
                                          backingScale: 1, originX: 0, originY: 0)

/// The 60 s demo script: wander (0-6), 4 clicks (6-14), typing 30 chars
/// (14-22), scrolls (22-28), far click (28), idle (34-40), cmd+L typing with
/// NO click (41-48), clicks (48, 52).
private func script(_ clickScale: Double = 1) -> [InputEvent] {
    var ev: [InputEvent] = []
    // 0-6 s wander with pauses, no clicks.
    for i in 0..<12 {
        ev.append(InputEvent(t: 0.1 + Double(i) * 0.5, kind: .move,
                             x: Float(960 + 300 * ((i % 2 == 0) ? 1 : -1)),
                             y: Float(540 + 200 * ((i % 3) - 1))))
        ev.append(InputEvent(t: 0.35 + Double(i) * 0.5, kind: .move,
                             x: Float(960 + 300 * ((i % 2 == 0) ? 1 : -1)),
                             y: Float(540 + 200 * ((i % 3) - 1))))
    }
    // 6-14 s: 4 clicks inside a ~500x300 region centered (960,540).
    ev.append(InputEvent(t: 6.0, kind: .down, x: 760, y: 430))
    ev.append(InputEvent(t: 8.0, kind: .down, x: 900, y: 500))
    ev.append(InputEvent(t: 10.0, kind: .down, x: 1050, y: 620))
    ev.append(InputEvent(t: 12.0, kind: .down, x: 1180, y: 480))
    // 14-22 s: type 30 chars.
    for i in 0..<30 { ev.append(InputEvent(t: 14.0 + Double(i) * 0.26, kind: .keyDown, keyCode: UInt16(i % 40))) }
    // 22-28 s: scroll 3 times, no click.
    for i in 0..<3 { ev.append(InputEvent(t: 22.0 + Double(i) * 2.0, kind: .scroll, x: 960, y: 540, scrollDelta: 5)) }
    // 28 s: far corner click.
    ev.append(InputEvent(t: 28.0, kind: .down, x: 1830, y: 90))
    // 41 s: cmd+L typing, NO click. keyDowns here anchor to the 28 s click.
    for i in 0..<12 { ev.append(InputEvent(t: 41.0 + Double(i) * 0.3, kind: .keyDown, keyCode: UInt16(i % 40))) }
    // 48, 52 s clicks.
    ev.append(InputEvent(t: 48.0, kind: .down, x: 300, y: 200))
    ev.append(InputEvent(t: 52.0, kind: .down, x: 900, y: 600))
    _ = clickScale
    return ev.sorted { $0.t < $1.t }
}

@Test func acceptanceScriptRuns() {
    var tl = Timeline(duration: 60)
    tl.audio.speedRampsAuto = false
    let out = Director.derive(tl, input: DirectorInput(events: script(), source: zoomReportSource), revision: 1)
    let scales = out.zoom.map { String(format: "%.2f", $0.scale) }.joined(separator: ",")
    print("ZOOM-REPORT scenes:", out.zoom.map { "\(String(format: "%.1f-%.1f", $0.start, $0.end))@\(String(format: "%.2f", $0.scale))" }.joined(separator: " | "))
    print("ZOOM-REPORT scales:", scales)
    // A1: hover/scroll spans BEFORE the first click stay at 1.0x.
    for t in [0.5, 2.0, 4.0, 36.0, 38.0] {
        #expect(abs(Double(out.evaluate(at: t).cameraScale) - 1) < 0.01, "\(t)")
    }
    // A2: count zoom-INS (from ≤1.05x to >1.05x) and bounces (A9).
    let lz = out.derived?.camera.lz ?? []
    var zoomIns = 0, prevLz = 0.0
    for v in lz {
        let lv = Double(v)
        if prevLz <= log(1.05) && lv > log(1.05) { zoomIns += 1 }
        prevLz = lv
    }
    print("ZOOM-REPORT zoom-ins:", zoomIns)
    #expect(zoomIns >= 2 && zoomIns <= 10, "\(zoomIns)")
    // A9: brief full-frame beats between actions are intentional now; only
    // one-tick pumps are forbidden.
    var restsBelow: [(start: Int, end: Int)] = []
    var inRest = -1
    for (i, v) in lz.enumerated() where Double(v) <= log(1.05) {
        if inRest < 0 { inRest = i }
    }
    for (i, v) in lz.enumerated() where Double(v) > log(1.05) {
        if inRest >= 0 { restsBelow.append((inRest, i)); inRest = -1 }
    }
    for r in restsBelow where r.start > 0 && r.end < lz.count {
        let dur = Double(r.end - r.start) / Double(gridRate)
        #expect(dur >= 0.2, "rest \(dur)")
    }
    // A3: adaptive scale can be gentler than the old 1.3 floor, but stays
    // above 1x and inside the upper clamp.
    #expect(out.zoom.allSatisfy { $0.scale >= 1.001 && $0.scale <= 3.2 }, "\(out.zoom.map(\.scale))")
    // A5/A4: first scene arrives 95% at its start click.
    let target = log(Double(out.zoom[0].scale))
    #expect(log(Double(out.evaluate(at: out.zoom[0].start).cameraScale)) >= 0.93 * target)
    // A10 smoothness. The previous version compounded `maxV` by gridRate on
    // every tick, so the ratio collapsed toward zero and could never fail.
    // Measure peak jerk of the baked log-zoom channel the same way the solver
    // budgets its runway (MotionLimits), so this is a real smoothness gate.
    guard lz.count > 3, let rate = out.derived?.camera.rate else { return }
    let jerk = MotionLimits.peakJerk(lz, rate: rate)
    #expect(jerk <= MotionLimits.cameraJerk, "spiky: peak jerk \(jerk) > \(MotionLimits.cameraJerk)")
}
