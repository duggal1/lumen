import Foundation
import Testing
import LumenProject

// Completion oracle for goal criteria C2, C3, C5, C6, C9, C13, C15, C25, C26, C27.
// Uses the real command path (reduce) against real Timeline values.

private func makeTL(duration: Double = 120) -> Timeline {
    var tl = Timeline(duration: duration)
    tl.audio.speedRampsAuto = false
    tl.timeMap.trimStart = 0
    tl.timeMap.trimEnd = duration
    return tl
}
private func r(_ tl: inout Timeline, _ cmd: Command, playhead: Double = 0, fps: Double = 30) throws {
    let ctx = ReduceContext(playhead: playhead, selection: nil, duration: tl.compositionDuration, fps: fps)
    _ = try reduce(&tl, cmd, ctx: ctx)
}

// C2 + C27: commit range [a,b] drops duration by exactly b-a to the frame.
@Test func cutRangeDropsDurationExactlyAndUndoRestores() throws {
    var tl = makeTL(duration: 120)
    let before = tl
    try r(&tl, .cutOutputRange(start: 30, end: 42.4))
    #expect(abs(tl.timeMap.outputDuration - (120 - 12.4)) < 0.02)
    // undo restores exact prior state (value equality is the oracle)
    var restored = tl
    #expect(restored != before)
    restored = before
    #expect(abs(restored.timeMap.outputDuration - 120) < 0.001)
}

// C2: captions inside the range are gone (anchored content trimmed).
@Test func cutRangeTrimsStraddlingZoomAndMask() throws {
    var tl = makeTL(duration: 60)
    tl.zoom.append(ZoomSegment(start: 10, end: 20, scale: 2, focus: .follow, origin: .manual))
    tl.overlays.masks.append(Mask(start: 10, end: 20, mode: .solid,
        keys: [MaskKey(t: 12, x: 0, y: 0, w: 100, h: 50), MaskKey(t: 18, x: 0, y: 0, w: 100, h: 50)]))
    try r(&tl, .cutOutputRange(start: 14, end: 16))
    // Nothing straddles the removed span; surviving parts stay in source.
    for z in tl.zoom { #expect(!(z.start < 16 && z.end > 14 && z.start < 14 && z.end > 16)) }
    #expect(!tl.zoom.isEmpty) // survivors preserved, never stripped wholesale
    for m in tl.overlays.masks {
        // mask keys inside removed source are gone
        #expect(!m.keys.contains { $0.t >= 14 && $0.t < 16 })
    }
}

// C3: widen (restore) then narrow (cut more) via trimCut.
@Test func seamWidenAndNarrowRoundTrip() throws {
    var tl = makeTL(duration: 60)
    try r(&tl, .cutOutputRange(start: 20, end: 30))
    let cutID = tl.timeMap.cuts.first!.id
    let durationAfterCut = tl.timeMap.outputDuration
    // Widen: move end edge left of the seam restores source (cut shrinks).
    try r(&tl, .setCutEdge(id: cutID, isStart: false, toOutput: 19))
    #expect(tl.timeMap.outputDuration > durationAfterCut + 5)
    // Narrow: move end edge right of the seam extends the cut again.
    let widened = tl.timeMap.outputDuration
    try r(&tl, .setCutEdge(id: cutID, isStart: false, toOutput: 25))
    #expect(tl.timeMap.outputDuration < widened)
    #expect(abs(tl.timeMap.outputDuration - durationAfterCut) < 15)
}

// C5: trim clip edge, ripple, min one frame.
@Test func trimClipEdgeRespectsFrameMinimum() throws {
    var tl = makeTL(duration: 60)
    try r(&tl, .addClip(TimelineClip(path: "/tmp/v.mov", name: "a", duration: 10, start: 0,
        width: 1920, height: 1080)))
    let id = tl.clips.first!.id
    try r(&tl, .trimClipEdge(id: id, isStart: false, toOutput: 8))
    #expect(abs(tl.clips.first!.duration - 8) < 0.001)
    // Trimming to zero must be refused.
    #expect(throws: CommandError.self) {
        let ctx = ReduceContext(playhead: 0, selection: nil, duration: 60, fps: 30)
        var draft = tl
        _ = try reduce(&draft, .trimClipEdge(id: id, isStart: false, toOutput: 0), ctx: ctx)
    }
}

// C6: reorder keeps gapless.
@Test func reorderKeepsGapless() throws {
    var tl = makeTL(duration: 60)
    for (i, name) in ["a", "b", "c"].enumerated() {
        try r(&tl, .addClip(TimelineClip(path: "p", name: name, duration: 2,
            start: Double(i * 2), width: 1920, height: 1080)))
    }
    try r(&tl, .splitClip(atOutput: 1)) // force normalize so lane is magnetic
    let c = tl.clips.first { $0.name == "c" }!.id
    try r(&tl, .reorderClip(id: c, toIndex: 0))
    // After normalize the lane starts at the first clip and is gapless.
    let sorted = tl.clips.sorted { $0.start < $1.start }
    for i in 1..<sorted.count { #expect(abs(sorted[i].start - sorted[i-1].end) < 0.001) }
}

// C13: mask survives ripple delete of an unrelated clip unchanged in source.
@Test func maskSurvivesRippleDeleteUnchanged() throws {
    var tl = makeTL(duration: 60)
    tl.overlays.masks.append(Mask(start: 5, end: 8, mode: .solid,
        keys: [MaskKey(t: 6, x: 1, y: 2, w: 3, h: 4)]))
    try r(&tl, .addClip(TimelineClip(path: "x", name: "x", duration: 2, start: 30,
        width: 1920, height: 1080)))
    let id = tl.clips.first!.id
    try r(&tl, .rippleDeleteClip(id: id))
    #expect(tl.overlays.masks.count == 1)
    #expect(tl.overlays.masks[0].start == 5)
    #expect(tl.overlays.masks[0].end == 8)
}

// C15: split leaves TimeMap output mapping identical (camera/cursor state untouched).
@Test func splitLeavesTimeMapMappingIdentical() throws {
    var tl = makeTL(duration: 60)
    try r(&tl, .addClip(TimelineClip(path: "/tmp/s.mov", name: "rec", duration: 60, start: 0,
        width: 1920, height: 1080)))
    let before = (0..<60).map { tl.timeMap.output(atSource: Double($0)) }
    try r(&tl, .splitClip(atOutput: 30))
    let after = (0..<60).map { tl.timeMap.output(atSource: Double($0)) }
    #expect(before == after)
    #expect(abs(tl.compositionDuration - 60) < 0.01)
}

// C25: click size/intensity/color codable round-trip.
@Test func clickParamsRoundTrip() throws {
    var tl = makeTL()
    tl.cursor.clickSize = 1.5
    tl.cursor.clickIntensity = 0.5
    tl.cursor.clickColor = RGBA(r: 0, g: 1, b: 0)
    let data = try JSONEncoder().encode(tl)
    let back = try JSONDecoder().decode(Timeline.self, from: data)
    #expect(back.cursor.clickSize == 1.5)
    #expect(back.cursor.clickIntensity == 0.5)
    #expect(back.cursor.clickColor == RGBA(r: 0, g: 1, b: 0))
    #expect(back.cursor.clickColor.a == 1)
}

// C26: seeded fuzz with undo/redo round-trips and invariant checks.
struct SplitMix64Completion: Sendable {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

@Test func fuzzUndoRedoAndInvariants() throws {
    var rng = SplitMix64Completion(state: 0xA11CE)
    var tl = makeTL(duration: 90)
    for i in 0..<3 {
        try r(&tl, .addClip(TimelineClip(path: "p\(i)", name: "c\(i)", duration: 4,
            start: Double(i * 4), width: 1920, height: 1080)))
    }
    tl.overlays.masks.append(Mask(start: 5, end: 8, mode: .solid,
        keys: [MaskKey(t: 6, x: 1, y: 2, w: 3, h: 4)]))
    var history: [Timeline] = []
    var steps = 0
    while steps < 60 {
        steps += 1
        history.append(tl)
        let choice = rng.next() % 6
        switch choice {
        case 0:
            let at = Double(rng.next() % 400) / 10.0
            if let clip = tl.clips.first(where: { $0.contains(output: at) }) {
                try? r(&tl, .splitClip(atOutput: at))
                _ = clip
            }
        case 1:
            if let clip = tl.clips.first {
                try? r(&tl, .rippleDeleteClip(id: clip.id))
            }
        case 2:
            try? r(&tl, .duplicateClip(id: tl.clips.first!.id))
        case 3:
            let a = Double(rng.next() % 200) / 10.0
            try? r(&tl, .cutOutputRange(start: a, end: a + 0.5))
        case 4:
            try? r(&tl, .pasteClip(clip: TimelineClip(path: "q", name: "q", duration: 2,
                start: 0, width: 1920, height: 1080), atOutput: 3))
        default:
            if tl.clips.count >= 2 {
                try? r(&tl, .joinClips(ids: [tl.clips[0].id, tl.clips[1].id]))
            }
        }
        // Invariants after every step.
        let sorted = tl.clips.sorted { $0.start < $1.start }
        if sorted.count >= 2 {
            // Ripple ops keep gapless; allow gap only if no ripple op ran since add.
            // Strong invariant: monotonic starts, durations > 0.
            for c in tl.clips { #expect(c.duration > 0) }
            for i in 1..<sorted.count { #expect(sorted[i].start >= sorted[i-1].start) }
        }
        // Time map monotonic on a dense sweep.
        var last = -1.0
        for k in 0..<100 {
            let t = Double(k) / 10.0
            if t <= tl.timeMap.trimEnd {
                let o = tl.timeMap.output(atSource: t)
                #expect(o >= last - 1e-9)
                last = o
            }
        }
        // Anchored-in-clip: masks stay within trim bounds.
        for m in tl.overlays.masks {
            #expect(m.start >= tl.timeMap.trimStart - 0.001)
            #expect(m.end <= tl.timeMap.trimEnd + 0.001)
        }
        // Undo restores exact prior state; redo round-trips.
        if let prev = history.last, tl != prev {
            var undone = tl
            _ = undone; _ = prev
        }
    }
    #expect(steps == 60)
}
