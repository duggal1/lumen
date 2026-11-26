import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - Composition with the other agents
//
// Visual autofocus is the passive layer. Explicit input (Agents 1 and 3) is fed
// to `VisualAutofocus.intents` as the `input` argument and suppresses nearby
// passive shots; hover-only evidence never opens a camera move.

@Suite struct VisualAutofocusCompositionTests {
    private let W = 1920.0, H = 1080.0

    private func source(_ dur: Double = 20) -> SourceInfo {
        SourceInfo(width: Int(W), height: Int(H), fps: 60, duration: dur,
                   backingScale: 1, originX: 0, originY: 0)
    }
    private func tm(_ dur: Double = 20) -> TimeMap { TimeMap(sourceDuration: dur) }

    private func marked(_ cells: [UInt8], _ r: CGRect) -> [UInt8] {
        var out = cells
        let cw = W / Double(ActivityConst.gw), ch = H / Double(ActivityConst.gh)
        let x0 = max(0, Int(floor(r.minX / cw)))
        let x1 = min(ActivityConst.gw - 1, Int(ceil(r.maxX / cw)) - 1)
        let y0 = max(0, Int(floor(r.minY / ch)))
        let y1 = min(ActivityConst.gh - 1, Int(ceil(r.maxY / ch)) - 1)
        guard x0 <= x1, y0 <= y1 else { return out }
        for y in y0...y1 {
            for x in x0...x1 { out[y * ActivityConst.gw + x] = 255 }
        }
        return out
    }

    private func grids(from: Double, to: Double, dt: Double = 0.1,
                       active: [(Double, CGRect)] = []) -> [ActivityGrid] {
        let n = max(1, Int(round((to - from) / dt)))
        return (0...n).map { i in
            let t = from + Double(i) * dt
            var cells = [UInt8](repeating: 0, count: ActivityConst.cells)
            for (at, r) in active where abs(t - at) < dt / 2 { cells = marked(cells, r) }
            return ActivityGrid(t: t, cells: cells)
        }
    }

    private func stable(_ t0: Double, _ r: CGRect, count: Int = 6,
                        dt: Double = 0.1) -> [ActivityGrid] {
        let active = (0..<count).map { (t0 + Double($0) * dt, r) }
        return grids(from: t0, to: t0 + Double(count - 1) * dt, dt: dt, active: active)
    }

    private func build(_ grids: [ActivityGrid], events: [InputEvent] = []) -> ActivityResult {
        ActivityShotBuilder.build(grids: grids.sorted { $0.t < $1.t },
                                  source: (W, H),
                                  inputs: ActivityInputs.make(events: events),
                                  settings: ActivitySettings())
    }

    private func intents(_ grids: [ActivityGrid], events: [InputEvent] = [],
                         input: [ZoomPlanner.Intent] = [], dur: Double = 20) -> [ZoomPlanner.Intent] {
        let result = build(grids, events: events)
        return VisualAutofocus.intents(shots: result.shots, input: input,
                                       src: source(dur), tm: tm(dur))
    }

    @Test func clickAndTypingIntentsSuppressNearbyVisualBeats() {
        let r1 = CGRect(x: 1300, y: 600, width: 300, height: 220)
        let r2 = CGRect(x: 500, y: 500, width: 320, height: 200)
        var active: [(Double, CGRect)] = (0..<5).map { (5.0 + Double($0) * 0.1, r1) }
        active += (0..<5).map { (6.2 + Double($0) * 0.1, r2) }
        let g = grids(from: 5.0, to: 6.6, active: active)
        let click = ZoomPlanner.Intent(kind: .click, t: 5.1, tEnd: 5.1, x: 1400, y: 700)
        let typing = ZoomPlanner.Intent(kind: .typing, t: 6.0, tEnd: 6.9, x: 600, y: 560,
                                        rect: r2, frameRect: r2)
        #expect((build(g).shots.first?.waypoints.count ?? 0) >= 2,
                "precondition: two passive subjects chain into one shot")
        let out = intents(g, input: [click, typing])
        #expect(out.isEmpty, "explicit input outranks passive pixels: \(out)")
    }

    @Test func ownBeatWinsOverBaselineWithoutProducingTwoShots() {
        let r = CGRect(x: 1200, y: 600, width: 320, height: 240)
        let out = intents(stable(5.0, r))
        #expect(out.count == 1, "one passive subject must produce one shot: \(out)")
        guard let one = out.first else { return }
        #expect(one.kind == .visual)
        let framed = one.rect.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) }
        let covers: Bool
        if let f = framed {
            let leftOK = f.minX <= r.minX + 2
            let topOK = f.minY <= r.minY + 2
            let rightOK = f.maxX >= r.maxX - 2
            let bottomOK = f.maxY >= r.maxY - 2
            covers = leftOK && topOK && rightOK && bottomOK
        } else { covers = false }
        let rectDesc = String(describing: one.rect)
        #expect(covers, "whole-subject framing must win over a centre shot: \(rectDesc)")
    }

    @Test func legacyAndGridPathsRejectHoverWithoutDisablingAutonomousResults() {
        let r = CGRect(x: 1050, y: 590, width: 140, height: 100)
        let pts = (0..<4).map { index in
            ActivityPoint(t: 5.0 + Double(index) * 0.2, x: r.midX, y: r.midY, region: r, coverage: 0.04)
        }
        let moves = [InputEvent(t: 1, kind: .move, x: 1090, y: 630)]
        #expect(VisualZoom.intents(pts, events: [], input: [], src: source(), tm: tm()).count == 1)
        #expect(VisualZoom.intents(pts, events: moves, input: [], src: source(), tm: tm()).isEmpty)
        #expect(VisualAutofocus.intents(pts, events: moves, src: source(), tm: tm()).isEmpty)
        #expect(intents(stable(5.0, r, count: 5), events: moves).isEmpty)
    }

    @Test func cooldownPreventsCameraPumping() {
        let a = CGRect(x: 1300, y: 600, width: 240, height: 180)
        let b = CGRect(x: 400, y: 300, width: 240, height: 180)
        var active: [(Double, CGRect)] = (0..<5).map { (5.0 + Double($0) * 0.1, a) }
        active += (0..<5).map { (6.6 + Double($0) * 0.1, b) }
        let result = build(grids(from: 5.0, to: 7.6, active: active))
        #expect(result.shots.count == 1, "two nearby results must chain into one shot: \(result.shots)")
        #expect((result.shots.first?.waypoints.count ?? 0) >= 2,
                "the second result becomes an in-shot pan, not a second segment")
    }

    @Test func emptyAndMalformedEvidenceProducesNothing() {
        let emptyCells = [UInt8](repeating: 0, count: ActivityConst.cells)
        let emptyCells2 = [UInt8](repeating: 0, count: ActivityConst.cells)
        #expect(build([]).shots.isEmpty)
        let bad = [
            ActivityGrid(t: .nan, cells: emptyCells),
            ActivityGrid(t: 2, cells: emptyCells2),
            ActivityGrid(t: .infinity, cells: emptyCells2),
            ActivityGrid(t: 4, cells: emptyCells2),
        ]
        let result = build(bad)
        #expect(result.shots.isEmpty)
        #expect(intents(bad).isEmpty)
        let repeated = (0..<5).map { _ in ActivityGrid(t: 3, cells: emptyCells2) }
        #expect(build(repeated).shots.isEmpty)
    }
}
