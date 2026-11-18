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

    @Test func laneRendererOnlyBracketsZoomRegions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent(
            "Sources/LumenUI/TimelineStrip+Lanes.swift"), encoding: .utf8)
        #expect(src.contains("if r.selected && r.brackets"),
                "a selected tile must not draw brackets")
        #expect(src.contains("brackets: StudioSelectionStyle.usesCornerBrackets(for: .zoomRegion)"),
                "the resolver must govern the lane renderer")
        // The clip and music lanes must pass no brackets flag (default false).
        #expect(!src.contains("brackets: true"))
    }
}
