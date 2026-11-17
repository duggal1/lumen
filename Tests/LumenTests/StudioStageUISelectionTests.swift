import Testing
import Foundation
@testable import LumenUI

/// Corner brackets are canvas handles only. Tiles get a flat selected surface,
/// and a music drag must never put its id into the timeline's bracketed
/// selection (DESIGN.md §3.1.7 and §2.20).
@Suite struct StudioStageUISelectionTests {
    @Test func listTilesNeverUseCornerBrackets() {
        let tiles: [StudioSelectionStyle.Target] = [.musicTile, .clipTile, .cursorTile]
        for tile in tiles {
            #expect(!StudioSelectionStyle.usesCornerBrackets(for: tile), "\(tile) must not wear brackets")
        }
    }

    @Test func canvasAndZoomRegionsStillUseBrackets() {
        #expect(StudioSelectionStyle.usesCornerBrackets(for: .canvasCrop))
        #expect(StudioSelectionStyle.usesCornerBrackets(for: .zoomRegion))
    }

    @Test func musicDragNeverAssignsBracketedSelection() {
        let id = UUID()
        #expect(TimelineStrip.dragSelectionID(id, isMusic: true) == nil)
        #expect(TimelineStrip.dragSelectionID(id, isMusic: false) == id)
        #expect(TimelineStrip.dragSelectionID(nil, isMusic: true) == nil)
        #expect(TimelineStrip.dragSelectionID(nil, isMusic: false) == nil)
    }

    @Test func dragSelectionFollowsTheSameResolverAsTheTiles() {
        let id = UUID()
        let expected = StudioSelectionStyle.usesCornerBrackets(for: .musicTile) ? id : nil
        #expect(TimelineStrip.dragSelectionID(id, isMusic: true) == expected)
    }
}
