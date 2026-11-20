import Foundation
import Testing
import LumenProject
import LumenRender
@testable import LumenUI

/// Headless state and source tests for the replacement of the deleted Focus
/// (cursor) page. The page no longer exists: framing moved to Tools, skins
/// moved to the toolbar chooser. These tests pin that shape so the page cannot
/// creep back and the Tiny Hand coat stays wired to the renderer.
@MainActor
@Suite("Cursor chooser UI state")
struct UnifiedFocusUIStateTests {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func inspectorHasNoCursorPage() throws {
        let src = try source("Sources/LumenUI/Inspector.swift")
        #expect(!src.contains("case focus ="))
        #expect(!src.contains("UnifiedFocusPage"))
        #expect(!src.contains("CursorAppearance"))
        #expect(!FileManager.default.fileExists(atPath: SourcePaths.page))
        #expect(!FileManager.default.fileExists(atPath: SourcePaths.appearance))
    }

    @Test func framingControlsSurviveInTools() throws {
        let src = try source("Sources/LumenUI/Inspector.swift")
        for label in ["Auto zoom", "Zoom amount", "Smoothness", "Layout"] {
            #expect(src.contains(label), "\(label) must survive the page deletion")
        }
        #expect(src.contains("FramingLayoutStyle.all"))
        let kinds = Set(Inspector.FramingLayoutStyle.all.map(\.0))
        #expect(kinds == Set(LayoutKind.allCases))
    }

    @Test func retiredTabsFallBackToStudio() {
        for old in ["Camera", "Cursor", "Layout", "Focus"] {
            #expect(Inspector.normalizeTab(old) == "Studio")
        }
        #expect(Inspector.normalizeTab("Transcript") == "Captions")
        #expect(Inspector.normalizeTab("Background") == "Studio")
        #expect(Inspector.normalizeTab("Audio") == "Audio")
        #expect(Inspector.normalizeTab("") == "")
    }

    @Test func tinyHandCatalogIsRealAndDistinct() {
        let skins = TinyHandSkins.catalog
        #expect(skins.count == 25)
        #expect(Set(skins.map(\.pack)).count == skins.count)
        for skin in skins {
            #expect(!skin.title.isEmpty)
            #expect(skin.asset.hasPrefix("hand_"))
            #expect(TinyHandSkins.isCoat(skin.pack))
            #expect(!skin.pack.preservesShape, "a skin replaces the pointer for every shape")
        }
    }

    @Test func tinyHandArtworkResolvesInTheBundle() {
        for skin in TinyHandSkins.catalog {
            #expect(TinyHandSkins.image(for: skin.pack) != nil, "\(skin.asset) missing from resources")
        }
    }

    @Test func existingInkPacksKeepTheirShapeIdentity() {
        for pack in [CursorPack.lavender, .ember, .system, .coral] {
            #expect(pack.preservesShape)
        }
        for pack in [CursorPack.dot, .ring, .outline, .pixel, .glove, .robot] {
            #expect(!pack.preservesShape)
        }
    }

    @Test func chooserShowsTheSameArtworkAndChecksTheActiveSkin() throws {
        let src = try source("Sources/LumenUI/CursorSkinChooser.swift")
        #expect(src.contains("TinyHandSkins.catalog"))
        #expect(src.contains("TinyHandSkins.image(for: pack)"))
        #expect(src.contains("CursorAtlas.previewImage(pack: pack)"))
        #expect(src.contains("Bitmap.check"))
        for banned in [".stroke(", "ColorPicker", "DisclosureGroup", ".sheet", ".popover"] {
            #expect(!src.contains(banned), "\(banned) does not belong in the chooser")
        }
        let toolbar = try source("Sources/LumenUI/EditorView.swift")
        #expect(toolbar.contains("CursorSkinChooser(model: model)"))
        #expect(toolbar.contains("cursorarrow"))
    }

    @Test func cursorGlyphsAreRealSymbols() {
        for name in ["cursorarrow", "rectangle.3.group"] {
            #expect(IconSymbols.exists(name), "\(name) must be a real macOS SF Symbol")
        }
    }

    @Test func wallpaperTreeIsWalkedOnceOffMain() throws {
        let src = try source("Sources/LumenUI/Inspector.swift")
        #expect(src.contains("loadWallpaperChoices()"))
        #expect(src.contains("Task.detached"))
        #expect(!src.contains("Self.wallpaperChoices()"), "no per-redraw filesystem walk")
    }

    @Test func musicPreviewsLoadLazily() throws {
        let src = try source("Sources/LumenUI/MusicPicker.swift")
        #expect(src.contains("WaveformStore.shared.peaks(for: track.url)"))
        #expect(src.contains("Task.detached"))
        #expect(!src.contains("loadWaveforms()"), "no eager whole-library decode")
        #expect(!src.contains("AVAudioFile"), "decoding lives in LumenAudio")
    }

    @Test func chooserTilesNeverWearStrokesOrRawFonts() throws {
        let src = try source("Sources/LumenUI/CursorSkinChooser.swift")
        for banned in [".stroke(", ".strokeBorder(", "CornerBrackets", "ColorPicker", ".font(.system("] {
            #expect(!src.contains(banned), "\(banned) must not appear in the chooser")
        }
        #expect(src.contains(".clickable()"))
        #expect(src.contains(".focusRing()"))
    }
}

private enum SourcePaths {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let page = root.appendingPathComponent("Sources/LumenUI/UnifiedFocusPage.swift").path
    static let appearance = root.appendingPathComponent("Sources/LumenUI/CursorAppearance.swift").path
}
