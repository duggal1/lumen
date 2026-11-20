import Foundation
import Testing
import LumenProject
import LumenRender
@testable import LumenUI

/// Headless state and source tests for the rebuilt Studio rail. No window is
/// opened: these pin the structure of the new right side and the Diether
/// instruments it uses.
@MainActor
@Suite("Studio rail UI state")
struct UnifiedFocusUIStateTests {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func railIsRebuiltWithSevenQuietSections() throws {
        let src = try source("Sources/LumenUI/Inspector.swift")
        let tabs = ["= \"Look\"", "= \"Cursor\"", "= \"Sound\"", "= \"Text\"", "= \"Trim\"", "= \"Privacy\"", "= \"Export\""]
        for tab in tabs { #expect(src.contains(tab), "\(tab) section missing") }
        #expect(src.contains("case focus") == false)
        #expect(src.contains("case tools") == false)
        #expect(!FileManager.default.fileExists(atPath: SourcePaths.page))
        #expect(!FileManager.default.fileExists(atPath: SourcePaths.appearance))
    }

    @Test func cursorPageIsBackWithTheTinyHandCoat() throws {
        let src = try source("Sources/LumenUI/Inspector.swift")
        #expect(src.contains("var cursorPage"))
        #expect(src.contains("TinyHandSkins.catalog.map(\\.pack)"))
        #expect(src.contains("CursorAtlas.previewImage(pack: pack)"))
        #expect(src.contains("Bitmap.check"))
        #expect(src.contains("SliderRow(label: \"Size\""))
    }

    @Test func soundIsCutToTheMainControls() throws {
        let src = try source("Sources/LumenUI/InspectorPages.swift")
        let page = src.components(separatedBy: "var soundPage").dropFirst().first ?? ""
        let next = page.components(separatedBy: "var textPage").first ?? page
        for control in ["voiceBoostDb", "noiseReductionStrength", "soundEffectsEnabled"] {
            #expect(next.contains(control), "\(control) must stay")
        }
        for removed in ["studioMode", "zoomInGainDb", "zoomOutGainDb", "clickGainDb", "typingLevelDb", "showVoiceIsolationControls"] {
            #expect(!next.contains(removed), "\(removed) is one of the cut settings")
        }
    }

    @Test func framingSurvivesOnTheTrimPage() throws {
        let src = try source("Sources/LumenUI/InspectorPages.swift")
        for label in ["Auto zoom", "Zoom amount", "Layout"] {
            #expect(src.contains(label), "\(label) must survive the rebuild")
        }
        #expect(src.contains("FramingLayoutStyle.all"))
        let rail = try source("Sources/LumenUI/Inspector.swift")
        #expect(rail.contains("enum FramingLayoutStyle"))
        let kinds = Set(Inspector.FramingLayoutStyle.all.map(\.0))
        #expect(kinds == Set(LayoutKind.allCases))
    }

    @Test func retiredTabsResolveToTheNewSections() {
        for old in ["Focus", "Cursor", "Camera", "Layout"] {
            #expect(Inspector.normalizeTab(old) == "Cursor")
        }
        for old in ["Tools", "Background", "Studio", "Timeline"] {
            #expect(Inspector.normalizeTab(old) == "Look")
        }
        #expect(Inspector.normalizeTab("Transcript") == "Text")
        #expect(Inspector.normalizeTab("Captions") == "Text")
        #expect(Inspector.normalizeTab("Audio") == "Sound")
        #expect(Inspector.normalizeTab("") == "")
    }

    @Test func everyPageHasAHeadlineAction() throws {
        let src = try source("Sources/LumenUI/InspectorPages.swift")
        for page in ["soundPage", "textPage", "trimPage", "privacyPage", "exportPage"] {
            #expect(src.contains("var \(page)"), "\(page) missing")
        }
        #expect(src.contains("pageHeader(\"Sound\""))
        #expect(src.contains("pageHeader(\"Text\""))
        #expect(src.contains("pageHeader(\"Trim\""))
        #expect(src.contains("pageHeader(\"Privacy\""))
        #expect(src.contains("pageHeader(\"Export\""))
    }

    // MARK: The stolen coat

    @Test func tinyHandCatalogIsRealAndDistinct() {
        let skins = TinyHandSkins.catalog
        #expect(skins.count == 25)
        #expect(Set(skins.map(\.pack)).count == skins.count)
        for skin in skins {
            #expect(!skin.title.isEmpty)
            #expect(skin.asset.hasPrefix("hand_"))
            #expect(TinyHandSkins.isCoat(skin.pack))
            #expect(!skin.pack.preservesShape)
        }
    }

    @Test func tinyHandArtworkResolvesInTheBundle() {
        for skin in TinyHandSkins.catalog {
            #expect(TinyHandSkins.image(for: skin.pack) != nil, "\(skin.asset) missing from resources")
        }
    }

    @Test func existingInkPacksKeepTheirShapeIdentity() {
        for pack in [CursorPack.lavender, .ember, .system, .coral] { #expect(pack.preservesShape) }
        for pack in [CursorPack.dot, .ring, .outline, .pixel, .glove, .robot] { #expect(!pack.preservesShape) }
    }

    @Test func chooserShowsTheSameArtworkAndChecksTheActiveSkin() throws {
        let src = try source("Sources/LumenUI/CursorSkinChooser.swift")
        #expect(src.contains("TinyHandSkins.catalog"))
        #expect(src.contains("Bitmap.check"))
        let toolbar = try source("Sources/LumenUI/EditorView.swift")
        #expect(toolbar.contains("CursorSkinChooser(model: model)"))
    }

    // MARK: Diether instruments

    @Test func musicWaveformUsesTheDitherInstrument() throws {
        let src = try source("Sources/LumenUI/MusicPicker.swift")
        #expect(src.contains("DitherWaveformView(peaks: peaks, hue: 5"))
        #expect(src.contains("WaveformStore.shared.peaks(for: track.url)"))
        #expect(src.contains("Task.detached"))
        #expect(!src.contains("WaveformPeaks("))
    }

    @Test func exportBandIsColorfulAndTracksProgress() throws {
        let src = try source("Sources/LumenUI/DitherWaveformView.swift")
        #expect(src.contains("struct DitherColorBandView"))
        #expect(src.contains("let hues = [0, 1, 2, 3, 4, 5]"))
        let pages = try source("Sources/LumenUI/InspectorPages.swift")
        #expect(pages.contains("DitherColorBandView(progress: exportFraction)"))
    }

    @Test func chooserTilesNeverWearStrokesOrRawFonts() throws {
        let src = try source("Sources/LumenUI/CursorSkinChooser.swift")
        for banned in [".stroke(", "CornerBrackets", "ColorPicker", ".font(.system("] {
            #expect(!src.contains(banned), "\(banned) must not appear in the chooser")
        }
    }
}

private enum SourcePaths {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let page = root.appendingPathComponent("Sources/LumenUI/UnifiedFocusPage.swift").path
    static let appearance = root.appendingPathComponent("Sources/LumenUI/CursorAppearance.swift").path
}
