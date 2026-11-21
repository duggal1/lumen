import Testing
import Foundation
import LumenProject
import LumenRender
@testable import LumenUI

/// Headless state tests for the rebuilt right side.
@Suite("Studio rail UI state")
struct UnifiedFocusUIStateTests {

    @Test func cursorPageKeepsThreeSkins() {
        for pack in [CursorPack.system, .pixel, .ring] {
            #expect(CursorAtlas.previewImage(pack: pack) != nil, "\(pack) preview missing")
        }
        // Two or three types: standard arrow, pixelated, and a different one.
        // Pixel and ring are stylized overrides of the pointer; the system
        // arrow keeps the recorded identity.
        #expect(CursorPack.pixel.preservesShape == false)
        #expect(CursorPack.ring.preservesShape == false)
        #expect(CursorPack.system.preservesShape == true)
        let system = CursorAtlas.previewImage(pack: .system)
        let pixel = CursorAtlas.previewImage(pack: .pixel)
        let ring = CursorAtlas.previewImage(pack: .ring)
        #expect(system != nil && pixel != nil && ring != nil)
        #expect(system != pixel && system != ring && pixel != ring)
    }

    @Test func rightSideIsPanelOnNearBlack() {
        // Tok.surface, dark: near-black neutral, one step above Tok.bg.
        #expect(Tok.surface != Tok.bg)
    }
}
