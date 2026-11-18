import Foundation
import Testing
import LumenProject
@testable import LumenUI

/// Headless state tests for the unified Focus page. Nothing here instantiates a
/// view or opens a window: it pins the minimal control set, the mode wiring and
/// the live feedback meter's state machine, plus a source guard against the
/// deleted knobs and tile-selection brackets creeping back in.
@MainActor
@Suite("Unified Focus UI state")
struct UnifiedFocusUIStateTests {

    // MARK: Minimal control set

    @Test func pageCarriesOnlyThreeSmallGroups() {
        #expect(FocusControlSet.zoom == ["Auto zoom", "Zoom amount", "Smoothness"])
        #expect(FocusControlSet.cursor == ["Cursor style", "Size", "Smoothing", "Click effect"])
        #expect(FocusControlSet.layout == ["Layout"])
        #expect(FocusControlSet.all.count == 8)
        #expect(Set(FocusControlSet.all).count == FocusControlSet.all.count)
        #expect(Set(FocusControlSet.removed).isDisjoint(with: FocusControlSet.all))
    }

    @Test func calledOutKnobsAreNotExposed() {
        let banned = ["Constant size", "Loop position", "Press scale", "Zoom comp.",
                      "Click size", "Click intensity", "Click color", "Click duration",
                      "Click ring", "Glide", "Fine tuning", "3D motion", "Motion blur"]
        for knob in banned {
            #expect(!FocusControlSet.isAllowed(knob), "\(knob) must stay deleted")
        }
    }

    // MARK: Cursor themes, not colors

    @Test func cursorStylesAreShapeThemesOnly() {
        let styles = FocusCursorStyle.all
        #expect(styles.count == 5)
        #expect(Set(styles.map(\.pack)) == [.system, .minimal, .dot, .ring, .outline])

        let colorOnlyPacks = ["lavender", "coral", "sky", "mint", "lemon", "pink",
                              "wood", "chrome", "grass", "ember", "holiday", "mono"]
        for style in styles {
            #expect(!colorOnlyPacks.contains(style.pack.rawValue),
                    "\(style.title) is a color swatch, not a cursor style")
            #expect(!style.title.isEmpty)
            #expect(style.accessibilityLabel == "\(style.title) cursor style")
        }
    }

    @Test func styleAccessibilityLabelsAreUniqueAndSentenceCase() {
        let labels = FocusCursorStyle.all.map(\.accessibilityLabel)
        #expect(Set(labels).count == labels.count)
        for label in labels {
            #expect(label.first?.isUppercase == true)
            #expect(!label.contains("!"))
        }
    }

    // MARK: Layout + tab wiring

    @Test func layoutDropdownCoversEveryLayoutKind() {
        let kinds = Set(FocusLayoutStyle.all.map(\.0))
        #expect(kinds == Set(LayoutKind.allCases))
        #expect(FocusLayoutStyle.all.count == LayoutKind.allCases.count)
        for (_, title) in FocusLayoutStyle.all {
            #expect(!title.isEmpty)
            #expect(title.first?.isUppercase == true)
        }
    }

    @Test func retiredTabsNormalizeToFocus() {
        for old in ["Camera", "Cursor", "Layout", "Focus"] {
            #expect(FocusTabMigration.normalize(old) == "Focus")
        }
        #expect(FocusTabMigration.normalize("Transcript") == "Captions")
        #expect(FocusTabMigration.normalize("Background") == "Studio")
        #expect(FocusTabMigration.normalize("Audio") == "Audio")
        #expect(FocusTabMigration.normalize("") == "")
    }

    @Test func focusUsesRealSFSymbolsAtAllowedSizes() {
        for name in ["cursorarrow", "rectangle.3.group"] {
            #expect(IconSymbols.exists(name), "\(name) must be a real macOS SF Symbol")
        }
    }

    // MARK: Live feedback waveform

    @Test func silenceIsAGapAtZeroAndBelow() {
        #expect(FocusFeedbackMeter.cellLevel(0) == 0)
        #expect(FocusFeedbackMeter.cellLevel(-1) == 0)
        #expect(FocusFeedbackMeter.cellLevel(.nan) == 0)
        #expect(FocusFeedbackMeter.cellLevel(0.04) == 0)
        #expect(FocusFeedbackMeter.cellLevel(0.1) == 1)
        #expect(FocusFeedbackMeter.cellLevel(0.4) == 2)
        #expect(FocusFeedbackMeter.cellLevel(0.6) == 3)
        #expect(FocusFeedbackMeter.cellLevel(0.9) == 4)
    }

    @Test func tapsScrollAndDecayBackToGaps() {
        let meter = FocusFeedbackMeter()
        #expect(meter.isSilent)
        #expect(meter.levels.count == FocusFeedbackMeter.columns)

        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        meter.register(.click, at: start)
        #expect(meter.levels.last == 1.0)
        #expect(meter.headIndex == FocusFeedbackMeter.columns - 1)

        meter.register(.key, at: start.addingTimeInterval(0.01))
        #expect(meter.levels.last == 0.72)
        #expect(meter.levels[FocusFeedbackMeter.columns - 2] > 0)
        #expect(!meter.isSilent)

        meter.advance(to: start.addingTimeInterval(5))
        #expect(meter.isSilent)
        #expect(meter.levels.allSatisfy { $0 == 0 })
    }

    @Test func feedbackNotificationDecodesOnlyKnownKinds() {
        let meter = FocusFeedbackMeter()
        let key = Notification(name: FocusFeedbackMeter.tapNotification,
                               userInfo: [FocusFeedbackMeter.kindKey: "key"])
        meter.handle(key)
        #expect(meter.levels.last == 0.72)

        let unknown = Notification(name: FocusFeedbackMeter.tapNotification,
                                   userInfo: [FocusFeedbackMeter.kindKey: "explosion"])
        meter.handle(unknown)
        #expect(meter.levels.last == 0.72)

        let missingData = Notification(name: FocusFeedbackMeter.tapNotification)
        meter.handle(missingData)
        #expect(meter.levels.last == 0.72)
    }

    @Test func postedFeedbackUsesTheDocumentedNameAndKey() {
        #expect(FocusFeedbackMeter.tapNotification.rawValue == "lumen.focus.feedback.tap")
        #expect(FocusFeedbackMeter.kindKey == "kind")
        #expect(FocusFeedbackMeter.Feedback.click.peak > FocusFeedbackMeter.Feedback.key.peak)
    }

    // MARK: Static guards against regression

    private func source(_ relative: String) throws -> String {
        // #filePath = <root>/Tests/LumenTests/<this file> — step out three times.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LumenTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func focusPageDrawsNoBracketsStrokesOrColorPickers() throws {
        let src = try source("Sources/LumenUI/UnifiedFocusPage.swift")
        for banned in ["CornerBrackets", ".stroke(", "ColorPicker", "AVAudioPlayer", "DisclosureGroup"] {
            #expect(!src.contains(banned), "\(banned) must not return to the Focus page")
        }
        #expect(src.contains("Tok.accentSoft"))
        #expect(src.contains("Ramp.heat"))
    }

    @Test func keyboardFocusUsesARingNotSelectionBrackets() throws {
        let components = try source("Sources/LumenUI/Components.swift")
        #expect(components.contains("struct FocusRing"))
        #expect(components.contains("Capsule().stroke(Tok.accent"))
        #expect(components.contains("focusEffectDisabled()"))
        let page = try source("Sources/LumenUI/UnifiedFocusPage.swift")
        #expect(page.contains(".focusRing()"))
    }

    @Test func inspectorNoLongerHasSeparateCameraCursorOrLayoutTabs() throws {
        let src = try source("Sources/LumenUI/Inspector.swift")
        #expect(src.contains("focus = \"Focus\""))
        #expect(src.contains("UnifiedFocusPage(model: model)"))
        for banned in ["case cursor =", "case camera =", "case layout =", "CursorAppearance(model:", "ClickSoundGrid(selected:"] {
            #expect(!src.contains(banned), "\(banned) is a removed page")
        }
    }

    // MARK: Q5 — flat tile selection, no strokes or brackets

    @Test func contentTilesNeverWearStrokesOrBrackets() throws {
        for file in ["CanvasPresetGrid.swift", "DitherPaletteGrid.swift",
                     "ClickSoundGrid.swift", "UnifiedFocusPage.swift"] {
            let src = try source("Sources/LumenUI/\(file)")
            for banned in [".stroke(", ".strokeBorder(", "CornerBrackets", "ColorPicker"] {
                #expect(!src.contains(banned), "\(banned) must not mark a tile in \(file)")
            }
        }
        let helper = try source("Sources/LumenUI/TileSelection.swift")
        #expect(helper.contains("Tok.accentSoft"))
        #expect(helper.contains("Tok.accentText"))
        #expect(!helper.contains(".stroke("), "selection is a fill, never an outline")
    }

    @Test func focusPageUsesOnlyTokensForFontsAndPointer() throws {
        let page = try source("Sources/LumenUI/UnifiedFocusPage.swift")
        #expect(!page.contains(".font(.system("), "no raw font sizes in features")
        #expect(!page.contains(".pointerStyle("), "pointer style belongs in clickable()")
        let components = try source("Sources/LumenUI/Components.swift")
        #expect(components.contains("func clickable"))
    }
}
