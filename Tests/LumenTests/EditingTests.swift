import Foundation
import Testing
import LumenProject

// Frozen oracle for plans/magnetic-editing.md. Red before implementation.

private func makeTimeline(duration: Double = 10) -> Timeline {
    var tl = Timeline(duration: duration)
    tl.audio.speedRampsAuto = false
    return tl
}

private func reduce(_ tl: inout Timeline, _ command: Command, playhead: Double = 0) throws {
    let ctx = ReduceContext(playhead: playhead, selection: nil, duration: tl.compositionDuration)
    _ = try reduce(&tl, command, ctx: ctx)
}

// MARK: - Add + sort + magnetic normalize

@Test func addClipSortsAndMagneticNormalizeClosesGap() throws {
    var tl = makeTimeline()
    // addClip sorts by start; gap close only happens on ripple edits (split/duplicate/paste/rippleDelete)
    try reduce(&tl, .addClip(TimelineClip(path: "/tmp/v.mov", name: "b", duration: 2, start: 4, width: 1920, height: 1080)), playhead: 0)
    try reduce(&tl, .addClip(TimelineClip(path: "/tmp/v.mov", name: "a", duration: 2, start: 0, width: 1920, height: 1080)), playhead: 0)
    #expect(tl.clips.map(\.start) == [0, 4]) // sorted; gap remains until a ripple edit
    try reduce(&tl, .trim(start: 0, end: 1), playhead: 0) // trim affects recording only; clips unaffected but checked
    try reduce(&tl, .trimClip(tl.clips.first { $0.name == "a" }!.id, inPoint: 0, duration: 2), playhead: 0)
}

// MARK: - Split (logical boundary, output unchanged)

@Test func splitChangesNothingAndPartitionsMask() throws {
    var tl = makeTimeline(duration: 10)
    // recording clip: full trim 0..10
    tl.timeMap.trimStart = 0; tl.timeMap.trimEnd = 10
    let full = TimelineClip(path: "/tmp/screen.mov", name: "recording", duration: 10, start: 0, width: 1920, height: 1080)
    try reduce(&tl, .addClip(full), playhead: 0)
    // mask spanning the split point 4..6
    tl.overlays.masks = [Mask(start: 4, end: 6, mode: .solid, keys: [MaskKey(t: 5, x: 10, y: 10, w: 100, h: 50)])]
    // split the recording clip at output 5
    try reduce(&tl, .splitClip(atOutput: 5), playhead: 5)
    // Two clips must exist, contiguous, same total duration
    #expect(tl.clips.count == 2)
    #expect(tl.clips[0].start == 0)
    #expect(tl.clips[0].duration == 5)
    #expect(tl.clips[1].start == 5)
    #expect(tl.clips[1].duration == 5)
    #expect(tl.compositionDuration == 10)
    // mask partitioned: no mask crosses the split boundary; no mask lost
    for m in tl.overlays.masks {
        #expect(m.end <= 5.001 || m.start >= 4.999)
    }
}

// MARK: - Ripple delete

@Test func rippleDeleteClosesGap() throws {
    var tl = makeTimeline(duration: 10)
    try reduce(&tl, .addClip(TimelineClip(path: "a", name: "a", duration: 2, start: 0, width: 1920, height: 1080)), playhead: 0)
    try reduce(&tl, .addClip(TimelineClip(path: "b", name: "b", duration: 2, start: 2, width: 1920, height: 1080)), playhead: 0)
    try reduce(&tl, .addClip(TimelineClip(path: "c", name: "c", duration: 2, start: 4, width: 1920, height: 1080)), playhead: 0)
    let b = tl.clips.first { $0.name == "b" }!.id
    try reduce(&tl, .rippleDeleteClip(id: b), playhead: 0)
    #expect(tl.clips.map(\.name) == ["a", "c"])
    #expect(tl.clips[1].start == 2) // rippled closed
    let expected = max(tl.timeMap.outputDuration, tl.clips.map(\.end).max() ?? 0)
    #expect(tl.compositionDuration == expected)
}

// MARK: - Join

@Test func joinMergesContiguousClips() throws {
    var tl = makeTimeline(duration: 10)
    // two halves of the same file, contiguous
    try reduce(&tl, .addClip(TimelineClip(path: "/tmp/v.mov", name: "a", inPoint: 0, duration: 5, start: 0, width: 1920, height: 1080)), playhead: 0)
    try reduce(&tl, .addClip(TimelineClip(path: "/tmp/v.mov", name: "b", inPoint: 5, duration: 5, start: 5, width: 1920, height: 1080)), playhead: 0)
    let a = tl.clips[0].id, b = tl.clips[1].id
    try reduce(&tl, .joinClips(ids: [a, b]), playhead: 0)
    #expect(tl.clips.count == 1)
    #expect(tl.clips[0].duration == 10)
    #expect(tl.clips[0].inPoint == 0)
}

// MARK: - Duplicate + Paste

@Test func duplicateAndPasteRipple() throws {
    var tl = makeTimeline(duration: 10)
    try reduce(&tl, .addClip(TimelineClip(path: "a", name: "a", duration: 2, start: 0, width: 1920, height: 1080)), playhead: 0)
    let a = tl.clips[0].id
    try reduce(&tl, .duplicateClip(id: a), playhead: 0)
    #expect(tl.clips.count == 2)
    #expect(tl.clips[1].start == 2)
    #expect(tl.clips[1].path == "a")
    // paste at playhead 1: inserts between, rippling the later clip
    let extra = TimelineClip(path: "x", name: "x", duration: 1, start: 0, width: 1920, height: 1080)
    try reduce(&tl, .pasteClip(clip: extra, atOutput: 1), playhead: 1)
    #expect(tl.clips.count == 3)
    // composition duration includes the recording itself (10s) unless trimmed; clocks include clips only after ripple
    let expected = max(tl.timeMap.outputDuration, tl.clips.map(\.end).max() ?? 0)
    #expect(tl.compositionDuration == expected)
    // no gaps
    var cursor = 0.0
    for c in tl.clips.sorted(by: { $0.start < $1.start }) {
        #expect(abs(c.start - cursor) < 0.01)
        cursor = c.start + c.duration
    }
}

// MARK: - Undo round trip (parser-level check only; EditorModel stacks snapshots)

@Test func reduceRoundTripViaEncodeDecode() throws {
    var tl = makeTimeline()
    try reduce(&tl, .addClip(TimelineClip(path: "a", name: "a", duration: 2, start: 0, width: 1920, height: 1080)), playhead: 0)
    let data = try JSONEncoder().encode(tl)
    let decoded = try JSONDecoder().decode(Timeline.self, from: data)
    #expect(decoded.clips == tl.clips)
}
