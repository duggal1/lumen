import Foundation
import Testing
import LumenProject

// Headless contract for the core video editing model. Written BEFORE the
// implementation; see .proof/V1-plan.md and .proof/V1/red.log for the red proof.

// MARK: - Helpers

private func makeTimeline(_ duration: Double = 20) -> Timeline {
    var t = Timeline(duration: duration)
    t.audio.speedRampsAuto = false
    return t
}

private func context(_ t: Timeline, playhead: Double = 0) -> ReduceContext {
    ReduceContext(playhead: playhead, selection: nil, duration: t.compositionDuration)
}

@discardableResult
private func apply(_ command: Command, to t: inout Timeline, playhead: Double = 0) throws -> Effects {
    try reduce(&t, command, ctx: context(t, playhead: playhead))
}

private func assertFiniteTimes(_ t: Timeline, _ label: String = "") {
    #expect(t.timeMap.sourceDuration.isFinite, "\(label): sourceDuration")
    #expect(t.timeMap.trimStart.isFinite && t.timeMap.trimEnd.isFinite, "\(label): trim")
    #expect(t.timeMap.outputDuration.isFinite && t.compositionDuration.isFinite, "\(label): duration")
    for c in t.timeMap.cuts {
        #expect(c.start.isFinite && c.end.isFinite && c.end > c.start, "\(label): cut")
    }
    for r in t.timeMap.ramps {
        #expect(r.start.isFinite && r.end.isFinite && r.end > r.start, "\(label): ramp span")
        #expect(r.speed.isFinite && r.speed > 0, "\(label): ramp speed")
    }
    for c in t.clips {
        #expect(c.start.isFinite && c.inPoint.isFinite, "\(label): clip start/inPoint")
        #expect(c.duration.isFinite && c.end.isFinite && c.duration > 0, "\(label): clip duration")
    }
}

private func cutSignature(_ t: Timeline) -> [String] {
    t.timeMap.cuts.map { "\($0.start),\($0.end),\($0.origin.rawValue)" }
}

private func makeHistoryWithClips() -> VideoEditHistory {
    var t = makeTimeline(20)
    t.clips = [
        TimelineClip(path: "/tmp/a.mov", name: "a", duration: 2, start: 0),
        TimelineClip(path: "/tmp/b.mov", name: "b", duration: 2, start: 2),
    ]
    return VideoEditHistory(t)
}

// MARK: - 1. Cut / delete with ripple

@Test func cutSourceSpanRipplesAndMapsFrames() throws {
    var t = makeTimeline(20)
    let original = t.timeMap.outputDuration
    try apply(.cutOutputRange(start: 2, end: 4), to: &t)
    #expect(abs(t.timeMap.outputDuration - (original - 2)) < 0.05)
    #expect(t.timeMap.cuts.count == 1)
    // The decision list is honest: output 2 is now source 4.
    #expect(abs(t.timeMap.source(atOutput: 2) - 4) < 0.05)
    assertFiniteTimes(t, "ripple cut")
}

@Test func overlappingSourceCutsAreMerged() throws {
    var t = makeTimeline(20)
    try apply(.addCut(start: 2, end: 4), to: &t)
    try apply(.addCut(start: 3, end: 5), to: &t)
    #expect(t.timeMap.cuts.count == 1)
    #expect(abs(t.timeMap.cuts[0].start - 2) < 1e-9)
    #expect(abs(t.timeMap.cuts[0].end - 5) < 1e-9)
    assertFiniteTimes(t, "overlapping cuts")
}

@Test func cutAtBoundariesIsRejectedWithoutMutation() throws {
    var t = makeTimeline(10)
    let before = t
    #expect(throws: CommandError.self) { try apply(.cutOutputRange(start: 0, end: 10), to: &t) }
    #expect(throws: CommandError.self) { try apply(.cutOutputRange(start: -5, end: -1), to: &t) }
    #expect(throws: CommandError.self) { try apply(.cutOutputRange(start: 9.999, end: 10.001), to: &t) }
    #expect(t == before)
}

@Test func nonFiniteCutTimesAreRejectedWithoutMutation() throws {
    var t = makeTimeline(10)
    let before = t
    #expect(throws: CommandError.self) { try apply(.cutOutputRange(start: .nan, end: 5), to: &t) }
    #expect(throws: CommandError.self) { try apply(.cutOutputRange(start: 1, end: .infinity), to: &t) }
    #expect(throws: CommandError.self) { try apply(.addCut(start: 2, end: .infinity), to: &t) }
    #expect(throws: CommandError.self) { try apply(.addCut(start: -.infinity, end: 3), to: &t) }
    #expect(t == before)
    assertFiniteTimes(t, "non-finite cut")
}

// MARK: - 2. Insert clip

@Test func insertedClipsStayFiniteAndHostileInsertIsRejected() throws {
    let nanDuration = TimelineClip(path: "/tmp/x.mov", duration: .nan, start: 0)
    let nanStart = TimelineClip(path: "/tmp/x.mov", duration: 1, start: .nan)
    #expect(nanDuration.duration.isFinite)
    #expect(nanStart.start.isFinite)

    var t = makeTimeline(20)
    let before = t
    #expect(throws: CommandError.self) {
        try apply(.pasteClip(clip: TimelineClip(path: "/tmp/c.mov", duration: 1, start: 0),
                             atOutput: .nan), to: &t)
    }
    #expect(t == before)
    assertFiniteTimes(t, "hostile insert")
}

@Test func insertClipRipplesToGaplessLane() throws {
    var t = makeTimeline(4)
    try apply(.addClip(TimelineClip(path: "a", name: "a", duration: 2, start: 8)), to: &t)
    try apply(.addClip(TimelineClip(path: "b", name: "b", duration: 2, start: 0)), to: &t)
    try apply(.pasteClip(clip: TimelineClip(path: "c", name: "c", duration: 1, start: 0),
                         atOutput: 1), to: &t)
    var cursor: Double? = nil
    for c in t.clips.sorted(by: { $0.start < $1.start }) {
        #expect(c.start.isFinite && c.duration.isFinite)
        if let cur = cursor { #expect(abs(c.start - cur) < 0.01) }
        cursor = c.end
    }
    assertFiniteTimes(t, "insert ripple")
}

// MARK: - 3. Reorder

@Test func reorderClipIsIdempotentClampedAndScoped() throws {
    var t = makeHistoryWithClips().timeline
    let first = t.clips[0].id
    let before = t
    try apply(.reorderClip(id: first, toIndex: 0), to: &t)
    #expect(t == before)
    try apply(.reorderClip(id: first, toIndex: 99), to: &t)
    #expect(t.clips.last?.id == first)
    // A sort-by-start here would silently restore [a, b] and lose the edit.
    #expect(t.clips.map(\.name) == ["b", "a"])
    #expect(throws: CommandError.self) { try apply(.reorderClip(id: UUID(), toIndex: 0), to: &t) }
    assertFiniteTimes(t, "reorder")
}

// MARK: - 4. Trim edges

@Test func nonFiniteClipMutationsAreRejectedWithoutMutation() throws {
    var t = makeHistoryWithClips().timeline
    let id = t.clips[0].id
    let before = t
    #expect(throws: CommandError.self) { try apply(.moveClip(id, start: .nan), to: &t) }
    #expect(throws: CommandError.self) { try apply(.trimClip(id, inPoint: .nan, duration: 2), to: &t) }
    #expect(throws: CommandError.self) { try apply(.trimClip(id, inPoint: 0, duration: .infinity), to: &t) }
    #expect(throws: CommandError.self) {
        try apply(.trimClipEdge(id: id, isStart: false, toOutput: .nan), to: &t)
    }
    #expect(t == before)
    assertFiniteTimes(t, "trim mutations")
}

@Test func trimClipEdgeKeepsAtLeastOneFrame() throws {
    var t = makeHistoryWithClips().timeline
    let id = t.clips[0].id
    #expect(throws: CommandError.self) {
        try apply(.trimClipEdge(id: id, isStart: true, toOutput: t.clips[0].end), to: &t)
    }
    assertFiniteTimes(t, "trim edge")
}

// MARK: - 5. Split at playhead

@Test func splitAtPlayheadPartitionsWithoutLosingDuration() throws {
    var t = makeTimeline(10)
    t.clips = [TimelineClip(path: "/tmp/screen.mov", duration: 10, start: 0)]
    try apply(.splitClip(atOutput: 5), to: &t, playhead: 5)
    #expect(t.clips.count == 2)
    #expect(abs(t.clips.map(\.duration).reduce(0, +) - 10) < 0.001)
    #expect(abs(t.timeMap.outputDuration - 10) < 0.05)
    #expect(throws: CommandError.self) { try apply(.splitClip(atOutput: .nan), to: &t) }
    assertFiniteTimes(t, "split")
}

@Test func splittingRecordingAtSamePointIsIdempotent() throws {
    var t = makeTimeline(10)
    try apply(.splitRecording(atOutput: 5), to: &t)
    let count = t.seams.count
    try apply(.splitRecording(atOutput: 5), to: &t)
    #expect(t.seams.count == count)
}

// MARK: - 6. Speed ramp

@Test func speedRampRejectsHostileAndOutOfRangeInputs() throws {
    var t = makeTimeline(10)
    let before = t
    #expect(throws: CommandError.self) { try apply(.addSpeedRamp(start: .nan, end: 2, speed: 2), to: &t) }
    #expect(throws: CommandError.self) { try apply(.addSpeedRamp(start: 1, end: 2, speed: .nan), to: &t) }
    #expect(throws: CommandError.self) { try apply(.addSpeedRamp(start: 20, end: 30, speed: 2), to: &t) }
    #expect(throws: CommandError.self) { try apply(.addSpeedRamp(start: 4, end: 2, speed: 2), to: &t) }
    #expect(t == before)
}

@Test func overlappingSpeedRampsAreRejected() throws {
    var t = makeTimeline(10)
    try apply(.addSpeedRamp(start: 2, end: 4, speed: 2), to: &t)
    #expect(throws: CommandError.self) { try apply(.addSpeedRamp(start: 3, end: 5, speed: 2), to: &t) }
    #expect(t.timeMap.ramps.count == 1)
    assertFiniteTimes(t, "ramp overlap")
}

@Test func validSpeedRampRetimesDeterministically() throws {
    var a = makeTimeline(10), b = makeTimeline(10)
    try apply(.addSpeedRamp(start: 2, end: 4, speed: 2), to: &a)
    try apply(.addSpeedRamp(start: 2, end: 4, speed: 2), to: &b)
    // IDs are deliberately fresh UUIDs; compare the deterministic decision data.
    #expect(a.timeMap.ramps.map { "\($0.start),\($0.end),\($0.speed)" } ==
            b.timeMap.ramps.map { "\($0.start),\($0.end),\($0.speed)" })
    #expect(a.timeMap.outputDuration == b.timeMap.outputDuration)
    #expect(a.timeMap.outputDuration < 10)
    assertFiniteTimes(a, "valid ramp")
}

// MARK: - 7. Crossfade duration

@Test func crossfadeDurationIsClampedAndIdempotent() throws {
    var t = makeHistoryWithClips().timeline  // shortest clip = 2s
    try apply(.setCrossfadeDuration(0.5), to: &t)
    #expect(abs(t.crossfadeDuration - 0.5) < 1e-9)
    #expect(abs(t.effectiveCrossfade - 0.5) < 1e-9)
    try apply(.setCrossfadeDuration(10), to: &t)
    #expect(t.effectiveCrossfade <= 1.0 + 1e-9)
    try apply(.setCrossfadeDuration(.nan), to: &t)
    #expect(t.crossfadeDuration == 0)
    #expect(t.effectiveCrossfade == 0)
    try apply(.setCrossfadeDuration(0.25), to: &t)
    let stable = t.crossfadeDuration
    try apply(.setCrossfadeDuration(0.25), to: &t)
    #expect(t.crossfadeDuration == stable)
}

@Test func crossfadeDurationSurvivesEncodeDecode() throws {
    var t = makeTimeline(5)
    t.crossfadeDuration = 0.3
    let data = try JSONEncoder().encode(t)
    let back = try JSONDecoder().decode(Timeline.self, from: data)
    #expect(abs(back.crossfadeDuration - 0.3) < 1e-9)
}

@Test func legacyProjectWithoutCrossfadeDecodesToZero() throws {
    let data = try JSONEncoder().encode(makeTimeline(5))
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    object.removeValue(forKey: "crossfadeDuration")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    let back = try JSONDecoder().decode(Timeline.self, from: legacy)
    #expect(back.crossfadeDuration == 0)
}

// MARK: - 8. Bulk cut insertion (O(N²) rebuild defect from T4)

@Test func bulkCutsRebuildOnceAndKeepExactSemantics() throws {
    let cuts = (0..<100).map { i in
        CutRange(start: Double(i) * 3 + 1, end: Double(i) * 3 + 1.5, origin: .manual)
    }

    var incremental = Timeline(duration: 300)
    let r0 = incremental.timeMap.rebuildCount
    for c in cuts { try apply(.addCut(start: c.start, end: c.end), to: &incremental) }
    let incrementalRebuilds = incremental.timeMap.rebuildCount - r0

    var bulk = Timeline(duration: 300)
    let b0 = bulk.timeMap.rebuildCount
    try apply(.addCuts(cuts), to: &bulk)
    let bulkRebuilds = bulk.timeMap.rebuildCount - b0

    // Deterministic cost proxy: no wall-clock assertion, just rebuild counts.
    #expect(incrementalRebuilds >= 100)
    #expect(bulkRebuilds == 1)
    // Identical output — a faster but different edit is not a fix.
    #expect(cutSignature(bulk) == cutSignature(incremental))
    #expect(bulk.timeMap.outputDuration == incremental.timeMap.outputDuration)
    assertFiniteTimes(bulk, "bulk cuts")
}

// MARK: - 9. Hostile sweeps

@Test func rapidHostileCommandsNeverCorruptTheTimeline() throws {
    var t = makeTimeline(30)
    let hostile: [Command] = [
        .cutOutputRange(start: .nan, end: 2), .cutOutputRange(start: -1, end: 1),
        .addCut(start: 1, end: .infinity), .addSpeedRamp(start: 2, end: 3, speed: .nan),
        .addSpeedRamp(start: 40, end: 41, speed: 2), .moveClip(UUID(), start: .nan),
        .trimClip(UUID(), inPoint: -.infinity, duration: .nan),
        .pasteClip(clip: TimelineClip(path: "x", duration: .nan, start: .nan), atOutput: .nan),
        .setCrossfadeDuration(.infinity), .splitClip(atOutput: .nan),
        .trimClipEdge(id: UUID(), isStart: true, toOutput: .nan),
        .cutOutputRange(start: 0, end: 30),
    ]
    for _ in 0..<5 { for c in hostile { try? apply(c, to: &t, playhead: .nan) } }
    assertFiniteTimes(t, "hostile sweep")
}

// MARK: - 10. Undo / redo

@Test func undoRedoCutRoundTrip() throws {
    var h = makeHistoryWithClips()
    let before = h.timeline
    try h.apply(.cutOutputRange(start: 0.5, end: 1.5), playhead: 1)
    let after = h.timeline
    #expect(after != before)
    let undone = h.undo()
    #expect(undone)
    #expect(h.timeline == before)
    let redone = h.redo()
    #expect(redone)
    #expect(h.timeline == after)
}

@Test func undoRedoWorksForEveryCoreOperation() throws {
    let operations: [(String, (Timeline) -> Command)] = [
        ("cut", { _ in .cutOutputRange(start: 0.5, end: 1) }),
        ("delete", { t in .rippleDeleteClip(id: t.clips[0].id) }),
        ("insert", { _ in .addClip(TimelineClip(path: "/tmp/c.mov", duration: 1, start: 99)) }),
        ("reorder", { t in .reorderClip(id: t.clips[1].id, toIndex: 0) }),
        ("trimEdge", { t in .trimClipEdge(id: t.clips[0].id, isStart: false,
                                           toOutput: t.clips[0].end - 0.5) }),
        ("split", { _ in .splitClip(atOutput: 1) }),
        ("ramp", { _ in .addSpeedRamp(start: 0.5, end: 1, speed: 2) }),
        ("crossfade", { _ in .setCrossfadeDuration(0.2) }),
    ]
    for (name, make) in operations {
        var h = makeHistoryWithClips()
        let before = h.timeline
        let command = make(h.timeline)
        try h.apply(command, playhead: 1)
        let after = h.timeline
        #expect(after != before, "\(name): edit changed the timeline")
        let undone = h.undo()
        #expect(undone, "\(name): undo returned true")
        #expect(h.timeline == before, "\(name): undo restored the snapshot")
        let redone = h.redo()
        #expect(redone, "\(name): redo returned true")
        #expect(h.timeline == after, "\(name): redo restored the snapshot")
    }
}

@Test func failedCommandDoesNotEnterUndoStack() throws {
    var h = makeHistoryWithClips()
    let before = h
    #expect(throws: CommandError.self) {
        try h.apply(.addClip(TimelineClip(path: "", duration: 1, start: 0)), playhead: 0)
    }
    #expect(h == before)
    #expect(!h.canUndo && !h.canRedo)
}

@Test func undoAndRedoOnEmptyStackAreNoOps() {
    var h = makeHistoryWithClips()
    let before = h
    let undone = h.undo()
    let redone = h.redo()
    #expect(!undone)
    #expect(!redone)
    #expect(h == before)
}

@Test func newEditClearsRedoStack() throws {
    var h = makeHistoryWithClips()
    try h.apply(.cutOutputRange(start: 0.5, end: 1), playhead: 1)
    let undone = h.undo()
    #expect(undone)
    #expect(h.canRedo)
    try h.apply(.addSpeedRamp(start: 0.5, end: 1, speed: 2), playhead: 1)
    #expect(!h.canRedo)
}

@Test func undoStackIsBounded() throws {
    var h = VideoEditHistory(makeTimeline(30), limit: 3)
    for i in 0..<6 {
        try h.apply(.addCut(start: Double(i) + 1, end: Double(i) + 1.2), playhead: 0)
    }
    #expect(h.undoStack.count == 3)
    var undone = 0
    while h.undo() { undone += 1 }
    #expect(undone == 3)
}

@Test func rapidUndoRedoChainIsExact() throws {
    var h = VideoEditHistory(makeTimeline(30))
    let origin = h.timeline
    for i in 0..<20 {
        let s = Double(i) * 0.3 + 0.1
        try h.apply(.addSpeedRamp(start: s, end: s + 0.1, speed: 1.5), playhead: 0)
    }
    let final = h.timeline
    var undoneAll = true
    for _ in 0..<20 { undoneAll = h.undo() && undoneAll }
    #expect(undoneAll)
    #expect(h.timeline == origin)
    var redoneAll = true
    for _ in 0..<20 { redoneAll = h.redo() && redoneAll }
    #expect(redoneAll)
    #expect(h.timeline == final)
}

@Test func undoWorksAfterPersistenceRoundTrip() throws {
    var h = makeHistoryWithClips()
    try h.apply(.cutOutputRange(start: 0.5, end: 1), playhead: 1)
    let data = try JSONEncoder().encode(h.timeline)
    let restored = try JSONDecoder().decode(Timeline.self, from: data)

    // Fresh process: only the persisted timeline survives; history is
    // session-local, but editing and undoing still work from that baseline.
    var fresh = VideoEditHistory(restored)
    #expect(!fresh.canUndo)
    let baseline = fresh.timeline
    try fresh.apply(.addSpeedRamp(start: 2, end: 3, speed: 2), playhead: 0)
    #expect(fresh.canUndo)
    let undone = fresh.undo()
    #expect(undone)
    #expect(fresh.timeline == baseline)
    #expect(fresh.timeline == restored)
}
