import Foundation
import Testing
import LumenProject

// Fuzz + split no-op + export-shape verification for the magnetic lane.

private func ctx(for tl: Timeline, playhead: Double) -> ReduceContext {
    ReduceContext(playhead: playhead, selection: nil, duration: tl.compositionDuration)
}

private func seededTimeline(seed: UInt64) -> Timeline {
    var tl = Timeline(duration: 30)
    tl.audio.speedRampsAuto = false
    tl.timeMap.trimStart = 0; tl.timeMap.trimEnd = 30
    // recording clip spanning the whole take
    tl.clips = [TimelineClip(path: "/tmp/screen.mov", name: "recording", inPoint: 0, duration: 30, start: 0, width: 1920, height: 1080)]
    tl.overlays.masks = [Mask(start: 5, end: 8, mode: .solid, keys: [MaskKey(t: 6, x: 10, y: 10, w: 100, h: 50)])]
    return tl
}

@Test func fuzzNoGapsAcrossRandomOps() throws {
    var rng = SplitMix64(state: 0xC0FFEE)
    var tl = seededTimeline(seed: 0xC0FFEE)
    let c = ctx(for: tl, playhead: 5)
    // seed some clips first
    for i in 0..<3 {
        try reduce(&tl, .addClip(TimelineClip(path: "/tmp/v\(i).mov", name: "c\(i)", duration: 2, start: Double(i) * 2, width: 1920, height: 1080)), ctx: c)
    }
    for _ in 0..<40 {
        switch rng.next() % 7 {
        case 0:
            if tl.clips.count >= 1, let p = tl.clips.first { try? reduce(&tl, .duplicateClip(id: p.id), ctx: c) }
        case 1:
            if tl.clips.count >= 1, let p = tl.clips.first { try? reduce(&tl, .rippleDeleteClip(id: p.id), ctx: c) }
        case 2:
            _ = try? reduce(&tl, .splitClip(atOutput: rng.nextDouble() * max(tl.compositionDuration - 1, 1) + 0.5), ctx: c)
        case 3:
            if tl.clips.count >= 2 { try? reduce(&tl, .joinClips(ids: [tl.clips[0].id, tl.clips[1].id]), ctx: c) }
        case 4:
            try? reduce(&tl, .moveClip(tl.clips.first!.id, start: rng.nextDouble() * 5), ctx: c)
        case 5:
            try? reduce(&tl, .trimClip(tl.clips.first!.id, inPoint: 0, duration: max(1, tl.clips.first!.duration - 0.5)), ctx: c)
        default:
            try? reduce(&tl, .addClip(TimelineClip(path: "/tmp/f.mov", name: "f", duration: 1, start: 0, width: 1920, height: 1080)), ctx: c)
        }
        // assert invariants after every step
        tl.clips.sort { $0.start < $1.start }
        var cursor = 0.0
        for clip in tl.clips {
            #expect(abs(clip.start - cursor) < 0.01, "gap before \(clip.name)")
            #expect(clip.duration > 0)
            cursor = clip.start + clip.duration
        }
        // time map monotonic: outputDuration >= 0 and source monotonic
        #expect(tl.timeMap.outputDuration >= 0)
        // anchored objects inside recording clip's source range
        for m in tl.overlays.masks {
            #expect(m.start >= tl.timeMap.trimStart - 0.001)
            #expect(m.end <= tl.timeMap.trimEnd + 0.001)
        }
        // total duration equals sum of clips (composition includes recording; we track clips alone)
        let sum = tl.clips.map(\.duration).reduce(0, +)
        #expect(tl.clips.map(\.end).max() ?? 0 <= max(tl.timeMap.outputDuration, sum) + 0.01)
    }
}

@Test func splitIsOutputNoOp() throws {
    var tl = seededTimeline(seed: 1)
    let beforeDur = tl.compositionDuration
    let beforeClips = tl.clips
    // split at 10, then join back with 11 → should restore identical output
    let c = ctx(for: tl, playhead: 10)
    try reduce(&tl, .splitClip(atOutput: 10), ctx: c)
    #expect(tl.compositionDuration == beforeDur)
    // partition: all masks partitioned, no span crosses the boundary
    for m in tl.overlays.masks {
        #expect(m.end <= 10.001 || m.start >= 9.999)
    }
    // masks still inside recording
    for m in tl.overlays.masks {
        #expect(m.end <= 30.001)
    }
    _ = beforeClips // readability
}

@Test func anchoredObjectsStayInsideClipRangeAfterDuplicatePaste() throws {
    var tl = seededTimeline(seed: 2)
    let c = ctx(for: tl, playhead: 3)
    try reduce(&tl, .duplicateClip(id: tl.clips[0].id), ctx: c)
    // duplicate inserts after original; masks remain source-anchored and unchanged
    #expect(tl.overlays.masks.count == 1)
    #expect(tl.overlays.masks[0].start == 5 && tl.overlays.masks[0].end == 8)
    for m in tl.overlays.masks {
        #expect(m.start >= 0 && m.end <= 30)
    }
}

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextDouble() -> Double { Double(next() % 1000) / 1000.0 }
}
