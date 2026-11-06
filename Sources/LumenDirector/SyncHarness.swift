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
            let firstFrame = min(ceil((actual.t / dt) - 1e-9) * dt, duration)
            // The frame immediately before the click must not show its ring.
            let before = floor((actual.t / dt) - 1e-6) * dt
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
}
