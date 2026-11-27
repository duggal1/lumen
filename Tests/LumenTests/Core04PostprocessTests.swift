import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenAnalysis

@Suite struct Core04PostprocessTests {
    @Test func cancelledSchedulerDoesNotAdmitMoreJobs() async {
        let task = Task {
            // Enter cancelled state deterministically before invoking scheduler.
            withUnsafeCurrentTask { $0?.cancel() }
            let jobs = (0..<8).map { i in
                AnalysisJob(name: "stale-\(i)", priority: i) {}
            }
            return await AnalysisScheduler.run(jobs, capacity: 2)
        }
        let report = await task.value
        #expect(report.order.isEmpty)
        #expect(report.peakConcurrency == 0)
    }

    @Test func indexedTypingFallbackUsesLastCausalClickAndNeverFuture() {
        let events = [
            InputEvent(t: 25, kind: .down, x: 250, y: 250),
            InputEvent(t: 4, kind: .down, x: 40, y: 40),
            InputEvent(t: 1, kind: .down, x: 10, y: 10)
        ]
        let resolved = TypingAnchorIndex.resolve(events: events, ax: [],
            bursts: [(t0: 2, t1: 3), (t0: 5, t1: 6), (t0: 50, t1: 51)])
        #expect(resolved[0] == SIMD2<Double>(10, 10))
        #expect(resolved[1] == SIMD2<Double>(40, 40))
        #expect(resolved[2] == nil)
    }

    @Test func silentScreenActivityProtectsThePicture() {
        let transcript = Transcript(words: [
            WordToken(text: "First", start: 0, end: 1),
            WordToken(text: "Second", start: 5, end: 6)
        ], locale: "en")
        #expect(TranscriptEdits.pauseCuts(transcript: transcript).count == 1)
        #expect(TranscriptEdits.pauseCuts(transcript: transcript, protectedVisualTimes: [3]).isEmpty)
        #expect(TranscriptEdits.cleanupCuts(transcript: transcript, includePauses: false).isEmpty)
    }

    @Test func expandingCutTrimsOnlyNewlyRemovedAnchors() throws {
        var timeline = Timeline(duration: 20)
        let cut = CutRange(start: 8, end: 10, origin: .manual)
        timeline.timeMap.cuts = [cut]
        timeline.layouts = [
            LayoutSegment(start: 6, end: 8, kind: .split),
            LayoutSegment(start: 10, end: 14, kind: .cameraOverlay)
        ]
        try timeline.trimCut(id: cut.id, isStart: true, toSource: 7, frame: 1.0 / 60)
        #expect(timeline.layouts.contains { $0.start == 6 && $0.end == 7 })
        #expect(timeline.layouts.contains { $0.start == 10 && $0.end == 14 })
        try timeline.trimCut(id: cut.id, isStart: false, toSource: 12, frame: 1.0 / 60)
        #expect(timeline.layouts.contains { $0.start == 12 && $0.end == 14 })
    }
}
