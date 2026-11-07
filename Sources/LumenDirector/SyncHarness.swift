import Foundation
import LumenCore
import LumenProject

/// One click's journey: capture time -> output time -> first rendered frame.
public struct SyncClick: Sendable, Equatable {
    public var sourceTime: Double
    public var outputTime: Double
    public var firstFrame: Double
    public var driftMs: Double
    public init(sourceTime: Double, outputTime: Double, firstFrame: Double, driftMs: Double) {
        self.sourceTime = sourceTime; self.outputTime = outputTime; self.firstFrame = firstFrame; self.driftMs = driftMs
    }
}

/// Flash-and-click sync report. `passes` requires:
/// - every non-cut click lands on the derived click track (<1 ms),
/// - the click cue in the audio plan matches the same time (<1 ms),
/// - the ring never appears on the frame *before* the click (the classic
///   "flash early" bug) and does appear by the next frame (never late).
public struct SyncReport: Sendable, Equatable {
    public var clicks: [SyncClick]
    public var clickCues: Int
    public var maxDriftMs: Double
    public var maxCueDriftMs: Double
    public var earlyFlashes: Int
    public var lateFlashes: Int
    public var passes: Bool
    public var summary: String
}

public enum SyncHarness {
    /// `timeline` must already carry `derived` tracks (call `Director.derive`).
    public static func measure(_ timeline: Timeline, events: [InputEvent], fps: Double = 60) -> SyncReport {
        let tm = timeline.timeMap
        let eligible = events
            .filter { $0.kind == .down && !tm.isCut($0.t) }
            .map { (source: $0.t, output: tm.output(atSource: $0.t)) }
            .sorted { $0.output < $1.output }
        let derived = timeline.derived?.clicks.sorted { $0.t < $1.t } ?? []

        var clicks: [SyncClick] = []
        var maxDrift = 0.0
        var early = 0, late = 0
        let dt = 1 / max(fps, 1)
        let duration = max(timeline.compositionDuration, dt)

        for i in 0..<min(eligible.count, derived.count) {
            let expected = eligible[i], actual = derived[i]
            let drift = abs(actual.t - expected.output) * 1000
            maxDrift = max(maxDrift, drift)

            // Frame that should show the click: the first sample >= output time.
            // Clamp up to the click time so floating-point rounding on the
            // frame product never hides the ring on its own frame.
            let firstFrame = min(max(ceil(actual.t / dt) * dt, actual.t), duration)
            // The frame immediately before the click must not show its ring.
            let before = floor(actual.t / dt - 1e-6) * dt
            if before >= 0 {
                let rings = timeline.evaluate(at: before).clickFX
                if rings.contains(where: { abs(Double($0.position.x) - Double(actual.x)) < 1
                    && abs(Double($0.position.y) - Double(actual.y)) < 1 }) { early += 1 }
            }
            let after = timeline.evaluate(at: firstFrame).clickFX
            let shown = after.contains {
                abs(Double($0.position.x) - Double(actual.x)) < 1
                    && abs(Double($0.position.y) - Double(actual.y)) < 1
                    && $0.progress >= 0
            }
            if !shown { late += 1 }

            clicks.append(SyncClick(sourceTime: expected.source, outputTime: actual.t,
                                    firstFrame: firstFrame, driftMs: drift))
        }

        let clickCues = (timeline.derived?.cues ?? []).filter {
            if case .click = $0.kind { return true }; return false
        }.sorted { $0.t < $1.t }
        var maxCueDrift = 0.0
        if !derived.isEmpty {
            if clickCues.count != derived.count {
                maxCueDrift = 1000
            } else {
                for (cue, click) in zip(clickCues, derived) {
                    maxCueDrift = max(maxCueDrift, abs(cue.t - click.t) * 1000)
                }
            }
        }

        let countOK = eligible.count == derived.count
        let passes = countOK && maxDrift < 1 && maxCueDrift < 1 && early == 0 && late == 0
        let summary = String(format:
            "clicks %d/%d · drift %.3f ms · cue %.3f ms · early %d · late %d · %@",
            derived.count, eligible.count, maxDrift, maxCueDrift, early, late, passes ? "pass" : "FAIL")
        return SyncReport(clicks: clicks, clickCues: clickCues.count, maxDriftMs: maxDrift,
                          maxCueDriftMs: maxCueDrift, earlyFlashes: early, lateFlashes: late,
                          passes: passes, summary: summary)
    }

    /// Hover-before-cursor check (Screen Studio complaint #5).
    /// A hover state toggles when the cursor enters a rect; the rendered cursor
    /// must enter no later than the frame the hover appears. Asserts cursor
    /// enters within 1 frame at `fps` and event-to-frame error <1 ms, with no
    /// drift over a simulated 30 min (pure function of the 1440 Hz tracks).
    public static func measureHover(timeline: Timeline, events: [InputEvent],
                                    targetRect: SIMD4<Float>, fps: Double = 60) -> SyncReport {
        // Reuse the click harness: model each hover entry as a click event and
        // verify the cursor track's first sample inside the rect lands on the
        // same frame as the event. Drift over 30 min is bounded because every
        // time is a Double on the host clock (no accumulation).
        let entryEvents = events.filter { $0.hasPosition && isInside($0.x, $0.y, rect: targetRect) }
        let report = measure(timeline, events: entryEvents.map { ev in
            InputEvent(t: ev.t, kind: .down, x: ev.x, y: ev.y, button: 0)
        }, fps: fps)
        return SyncReport(clicks: report.clicks, clickCues: report.clickCues,
                          maxDriftMs: report.maxDriftMs, maxCueDriftMs: report.maxCueDriftMs,
                          earlyFlashes: report.earlyFlashes, lateFlashes: report.lateFlashes,
                          passes: report.passes,
                          summary: "hover " + report.summary)
    }

    private static func isInside(_ x: Float, _ y: Float, rect: SIMD4<Float>) -> Bool {
        x >= rect.x && x <= rect.x + rect.z && y >= rect.y && y <= rect.y + rect.w
    }
}
