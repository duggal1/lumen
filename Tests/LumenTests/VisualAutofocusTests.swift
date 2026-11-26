import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - Passive visual autofocus
//
// Synthetic 10 Hz `ActivityGrid` streams (48x27 energy cells) are fed to
// `ActivityShotBuilder` and mapped by `VisualAutofocus.intents`. No window, no
// pixels decoded, no GUI. These are the behaviours the camera must get from a
// demo where the user never clicks and never hovers.

private struct IntentFingerprint: Equatable {
    let t: Double, tEnd: Double, x: Double, y: Double, w: Double
}

@Suite struct VisualAutofocusTests {
    private let W = 1920.0, H = 1080.0

    private func source(_ dur: Double = 20) -> SourceInfo {
        SourceInfo(width: Int(W), height: Int(H), fps: 60, duration: dur,
                   backingScale: 1, originX: 0, originY: 0)
    }

    private func tm(_ dur: Double = 20) -> TimeMap { TimeMap(sourceDuration: dur) }

    /// Marks the 40x40 cells covered by a source-pixel rectangle.
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

    /// A uniform 10 Hz grid stream; `active` gives the changed rect at each time.
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

    /// A stable changed region, the way ActivityAnalyzer emits settled evidence.
    private func stable(_ t0: Double, _ r: CGRect, count: Int = 5,
                        dt: Double = 0.1) -> [ActivityGrid] {
        let active = (0..<count).map { (t0 + Double($0) * dt, r) }
        return grids(from: t0, to: t0 + Double(count - 1) * dt, dt: dt, active: active)
    }

    private func build(_ grids: [ActivityGrid], events: [InputEvent] = [],
                       settings: ActivitySettings = ActivitySettings()) -> ActivityResult {
        ActivityShotBuilder.build(grids: grids.sorted { $0.t < $1.t },
                                  source: (W, H),
                                  inputs: ActivityInputs.make(events: events),
                                  settings: settings)
    }

    private func analyze(_ grids: [ActivityGrid], events: [InputEvent] = [],
                         input: [ZoomPlanner.Intent] = [],
                         settings: ActivitySettings = ActivitySettings(),
                         dur: Double = 20, tm: TimeMap? = nil) -> [ZoomPlanner.Intent] {
        let result = build(grids, events: events, settings: settings)
        return VisualAutofocus.intents(shots: result.shots, input: input,
                                       src: source(dur), tm: tm ?? self.tm(dur))
    }

    private func contains(_ r: CGRect, in rect: CGRect?, tol: Double = 2) -> Bool {
        guard let rect else { return false }
        return rect.minX <= r.minX + tol && rect.minY <= r.minY + tol &&
               rect.maxX >= r.maxX - tol && rect.maxY >= r.maxY - tol
    }

    private func contains(_ r: CGRect, in rect: PxRect, tol: Double = 2) -> Bool {
        contains(r, in: CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h), tol: tol)
    }

    // MARK: Positives — the real product moments

    @Test func resultAppearingCreatesOneHeldBeat() {
        let r = CGRect(x: 1400, y: 700, width: 200, height: 200)
        let g = stable(5.0, r)
        let result = build(g)
        #expect(result.shots.count == 1, "a settled result must open one shot, got \(result.shots)")
        guard let shot = result.shots.first, let wp = shot.waypoints.first else { return }
        #expect(shot.kind == .region, "got \(shot.kind)")
        #expect(contains(r, in: wp.rect), "the whole result must be framed, got \(wp.rect)")
        #expect(wp.scale <= 1.8 + 1e-6, "scale must respect maxScale: \(wp.scale)")
        let out = analyze(g)
        #expect(out.count == 1)
        guard let intent = out.first else { return }
        #expect(intent.kind == .visual)
        #expect(contains(r, in: intent.rect), "got \(String(describing: intent.rect))")
        #expect(intent.t < intent.tEnd)
        #expect(abs(intent.t - 5.0) < 1e-6,
                "shot must be marked at the first change; the camera solver supplies lead-in, t=\(intent.t)")
        #expect(intent.tEnd - intent.t < 2.6, "shot must not sit for 8 s")
    }

    @Test func designRevealFramesTheWholeImageWithGentleMagnification() {
        let r = CGRect(x: 700, y: 300, width: 800, height: 500)   // 17% of frame
        let result = build(stable(4.0, r, count: 6))
        #expect(result.shots.count == 1)
        guard let wp = result.shots.first?.waypoints.first else { return }
        #expect(contains(r, in: wp.rect), "the whole reveal must stay in frame: \(wp.rect)")
        #expect(wp.scale <= 1.8 + 1e-6 && wp.scale >= 1.25 - 1e-6, "scale \(wp.scale)")
    }

    @Test func textChangingWithNoTypingInputCreatesAWideBeat() {
        let r = CGRect(x: 400, y: 500, width: 1000, height: 60)
        let result = build(stable(6.0, r, count: 5))
        #expect(result.shots.count == 1)
        guard let wp = result.shots.first?.waypoints.first else { return }
        #expect(contains(r, in: wp.rect))
        #expect(wp.rect.w >= 1000, "text change must frame a wide band, got \(wp.rect.w)")
    }

    @Test func cardDrawUnionsGrowingObservationsIntoOneBeat() {
        let rects = [
            CGRect(x: 900, y: 480, width: 120, height: 80),
            CGRect(x: 900, y: 470, width: 200, height: 130),
            CGRect(x: 900, y: 450, width: 300, height: 200),
            CGRect(x: 900, y: 440, width: 400, height: 260),
            CGRect(x: 900, y: 430, width: 460, height: 300),
        ]
        let active = rects.enumerated().map { (8.0 + Double($0.offset) * 0.1, $0.element) }
        let result = build(grids(from: 8.0, to: 8.4, active: active))
        #expect(result.shots.count == 1)
        guard let wp = result.shots.first?.waypoints.first else { return }
        #expect(contains(CGRect(x: 900, y: 430, width: 460, height: 300), in: wp.rect),
                "union of the growing card: \(wp.rect)")
    }

    @Test func panelOpeningWithoutAClickFramesTheWholePanel() {
        let r = CGRect(x: 640, y: 180, width: 800, height: 700)   // 27% of frame
        // A panel this large pads to a gentle magnification below the default
        // minTrigger; keep the whole panel as a subject by lowering that floor.
        var settings = ActivitySettings()
        settings.minTrigger = 1.1
        let result = build(stable(10.0, r, count: 6), settings: settings)
        #expect(result.shots.count == 1)
        guard let wp = result.shots.first?.waypoints.first else { return }
        #expect(contains(r, in: wp.rect), "a passive panel must not be cropped at the frame edge")
    }

    // MARK: Negatives — things that must never open a shot

    @Test func hoverOnlyHighlightNeverTriggers() {
        let r = CGRect(x: 940, y: 520, width: 60, height: 20)
        let moves = (0..<6).map { InputEvent(t: 3.0 + Double($0) * 0.1, kind: .move,
                                             x: 970, y: 530) }
        let result = build(stable(3.0, r, count: 6), events: moves)
        #expect(result.shots.isEmpty, "hover must never open a zoom: \(result.shots)")
        #expect(analyze(stable(3.0, r, count: 6), events: moves).isEmpty)
    }

    @Test func scrollingNearAChangeNeverTriggers() {
        let r = CGRect(x: 700, y: 400, width: 400, height: 300)
        let scroll = [InputEvent(t: 5.05, kind: .scroll, x: 900, y: 500, scrollDelta: 3),
                      InputEvent(t: 5.25, kind: .scroll, x: 900, y: 500, scrollDelta: -2)]
        let result = build(stable(5.0, r, count: 6), events: scroll)
        #expect(result.shots.isEmpty, "scrolling must never open a zoom: \(result.shots)")
    }

    @Test func fullScreenFlashNeverTriggersAndDoesNotPoisonTheNextResult() {
        let flash = CGRect(x: 0, y: 0, width: W, height: H)
        let resultRect = CGRect(x: 1300, y: 700, width: 220, height: 180)
        var active: [(Double, CGRect)] = [(2.0, flash), (2.1, flash), (2.2, flash)]
        active += (0..<5).map { (6.0 + Double($0) * 0.1, resultRect) }
        let result = build(grids(from: 2.0, to: 6.4, active: active))
        #expect(result.shots.count == 1, "the flash must break, not disable the detector")
        let out = analyze(grids(from: 2.0, to: 6.4, active: active))
        #expect(out.count == 1)
        #expect((out.first?.t ?? 0) > 5.0)
    }

    @Test func caretBlinkIsRejected() {
        // A caret BLINKS: active on even ticks, dark on odd ones. A steady
        // one-cell region would correctly be treated as a loader by F2.
        var active: [(Double, CGRect)] = []
        for i in stride(from: 0, through: 7, by: 2) {
            active.append((4.0 + Double(i) * 0.1,
                           CGRect(x: 800.0, y: 290, width: 8, height: 20)))
        }
        let result = build(grids(from: 4.0, to: 4.7, active: active))
        #expect(result.shots.isEmpty, "a caret blink is below minCells: \(result.shots)")
    }

    @Test func delayedStationaryHoverNeverBecomesAShot() {
        let r = CGRect(x: 850, y: 420, width: 240, height: 160)
        let move = InputEvent(t: 1, kind: .move, x: 960, y: 500)
        #expect(build(stable(5, r, count: 8), events: [move]).shots.isEmpty)
    }

    @Test func remoteHoverAnimationCannotResurrectAfterGuardExpires() {
        let r = CGRect(x: 1350, y: 650, width: 240, height: 160)
        let move = InputEvent(t: 1, kind: .move, x: 100, y: 100)
        #expect(build(stable(2, r, count: 35), events: [move]).shots.isEmpty)
    }

    @Test func independentRemoteResultAfterHoverUncertaintyRemainsEligible() {
        let r = CGRect(x: 1350, y: 650, width: 240, height: 160)
        let move = InputEvent(t: 1, kind: .move, x: 100, y: 100)
        #expect(build(stable(6, r, count: 6), events: [move]).shots.count == 1)
    }

    @Test func futurePointerDoesNotSuppressEarlierResult() {
        let r = CGRect(x: 850, y: 420, width: 240, height: 160)
        let move = InputEvent(t: 8, kind: .move, x: 960, y: 500)
        #expect(build(stable(5, r, count: 6), events: [move]).shots.count == 1)
        let inputs = ActivityInputs.make(events: [move, InputEvent(t: 1, kind: .move, x: 20, y: 30)])
        #expect(inputs.cursor(at: 0) == nil)
        #expect(inputs.cursor(at: 5)?.x == 20)
        #expect(inputs.cursor(at: 8)?.x == 960)
    }

    @Test func clickReleasesRemoteHoverUncertainty() {
        let r = CGRect(x: 1350, y: 650, width: 240, height: 160)
        let events = [InputEvent(t: 1, kind: .move, x: 100, y: 100),
                      InputEvent(t: 1.5, kind: .down, x: 100, y: 100, button: 0)]
        #expect(build(stable(2, r, count: 6), events: events).shots.count == 1)
    }

    @Test func endlessLocalAnimationDoesNotBecomeACameraShot() {
        let r = CGRect(x: 850, y: 420, width: 240, height: 160)
        let result = build(stable(2, r, count: 110))
        #expect(result.shots.isEmpty)
        #expect(!result.mergedBusy.isEmpty)
    }

    // MARK: Determinism

    @Test func analysisIsDeterministicAndInsensitiveToInputOrder() {
        let r = CGRect(x: 1200, y: 600, width: 300, height: 220)
        let g = stable(5.0, r, count: 6)
        let input = [ZoomPlanner.Intent(kind: .click, t: 1.0, tEnd: 1.0, x: 400, y: 300)]
        let a = analyze(g, input: input)
        let b = analyze(g.reversed(), input: input)
        #expect(build(g).shots == build(g.reversed()).shots,
                "same evidence must produce the same shot")
        func fingerprint(_ xs: [ZoomPlanner.Intent]) -> [IntentFingerprint] {
            xs.map { IntentFingerprint(t: $0.t, tEnd: $0.tEnd, x: $0.x, y: $0.y,
                                       w: Double($0.rect?.width ?? -1)) }
        }
        #expect(fingerprint(a) == fingerprint(b))
        #expect(fingerprint(analyze(g, input: input)) == fingerprint(a))
    }
}
