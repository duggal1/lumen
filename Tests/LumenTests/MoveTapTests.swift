import Foundation
import Testing
@testable import LumenProject

private func tlWithTap() -> Timeline {
    var tl = Timeline(duration: 10)
    tl.timeMap.trimStart = 0; tl.timeMap.trimEnd = 10
    tl.overlays.taps = [TapIndicator(t: 5, x: 100, y: 100)]
    return tl
}

@Test func moveTapPreservesIdClampsAndSnapsCut() throws {
    var tl = tlWithTap()
    let id = tl.overlays.taps[0].id
    let ctx = ReduceContext(playhead: 5, selection: id, duration: 10)
    // clamp time into source range
    _ = try reduce(&tl, .moveTap(tap: id, x: 99999, y: -5, atSource: 99), ctx: ctx)
    #expect(tl.overlays.taps.first?.id == id)
    #expect(tl.overlays.taps.first!.t == 10)
    #expect(tl.overlays.taps.first!.x > 100)
    // cut snap: put cut 6..8, move to 7 -> nearest edge
    tl.timeMap.cuts = [CutRange(start: 6, end: 8, origin: .manual)]
    _ = try reduce(&tl, .moveTap(tap: id, x: 50, y: 50, atSource: 7.2), ctx: ctx)
    // nearest edge to 7.2 is 6 (dist 1.2 vs 0.8 to 8? 8-7.2=0.8 -> should snap to 8)
    #expect(tl.overlays.taps.first!.t == 8)
    // no-op when unchanged type-wise: unknown id throws
    var threw = false
    do { try reduce(&tl, .moveTap(tap: UUID(), x: 0, y: 0, atSource: nil), ctx: ctx) } catch { threw = true }
    #expect(threw)
}

@Test func moveTapEffectsAreCursorAudioOnly() throws {
    var tl = tlWithTap()
    let id = tl.overlays.taps[0].id
    let ctx = ReduceContext(playhead: 5, selection: id, duration: 10)
    let fx = try reduce(&tl, .moveTap(tap: id, x: 200, y: 200, atSource: 6), ctx: ctx)
    #expect(fx.contains(.cursor))
    #expect(fx.contains(.audio))
    #expect(!fx.contains(.zoom))
    #expect(!fx.contains(.camera))
    #expect(try JSONEncoder().encode(tl).count > 0)
}
