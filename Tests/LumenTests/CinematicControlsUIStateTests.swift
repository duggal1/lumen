import Foundation
import Testing
import LumenProject
@testable import LumenUI

/// Headless state/logic tests for the Studio's cinematic zoom + 3D controls.
/// No views are instantiated and no window is opened: these exercise the pure
/// contract the Inspector controls bind to, so the contract is verified even
/// on a machine where a GUI cannot be shown.
@Suite("Cinematic controls UI state")
struct CinematicControlsUIStateTests {

    @Test func offIsTheOnlyDisabledTiltMode() {
        #expect(!Cinematic3D.isEnabled(.off))
        #expect(Cinematic3D.isEnabled(.lean))
        #expect(Cinematic3D.isEnabled(.reveal))
    }

    @Test func enablingFromOffChoosesLean() {
        #expect(Cinematic3D.mode(.off, enabling: true) == .lean)
        #expect(Cinematic3D.mode(.off, enabling: true) == Cinematic3D.enabledMode)
    }

    @Test func enablingAgainPreservesTheUsersStyle() {
        for mode: TiltMode in [.lean, .reveal] {
            #expect(Cinematic3D.mode(mode, enabling: true) == mode)
            #expect(Cinematic3D.mode(Cinematic3D.mode(mode, enabling: true), enabling: true) == mode)
        }
    }

    @Test func disablingAlwaysReturnsToOff() {
        for mode: TiltMode in TiltMode.allCases {
            #expect(Cinematic3D.mode(mode, enabling: false) == .off)
            #expect(!Cinematic3D.isEnabled(Cinematic3D.mode(mode, enabling: false)))
        }
    }

    @Test func toggleIsIdempotentInBothDirections() {
        for mode: TiltMode in TiltMode.allCases {
            let on = Cinematic3D.mode(mode, enabling: true)
            #expect(on == mode || mode == .off)
            #expect(Cinematic3D.mode(on, enabling: false) == .off)
            #expect(Cinematic3D.mode(.off, enabling: Cinematic3D.isEnabled(on)) == on || mode != .off)
        }
    }

    @Test func styleSegmentsCoverExactlyTheNonOffModes() {
        #expect(Cinematic3D.styles.count == TiltMode.allCases.count - 1)
        let modes = Set(Cinematic3D.styles.map(\.0))
        #expect(modes == Set(TiltMode.allCases.filter { $0 != .off }))
        #expect(!modes.contains(.off))
        #expect(Set(Cinematic3D.styles.map(\.1)).count == Cinematic3D.styles.count)
    }

    @Test func accessibilityLabelsAreUniqueAndSentenceCase() {
        let labels = TiltMode.allCases.map { Cinematic3D.label($0) }
        #expect(Set(labels).count == TiltMode.allCases.count)
        for label in labels {
            #expect(!label.isEmpty)
            #expect(label.first(where: { $0.isLetter })?.isUppercase == true)
            #expect(!label.contains("!"))
        }
    }

    @Test func hintsExplainEachStateWithoutAForbiddenTone() {
        let hints = TiltMode.allCases.map { Cinematic3D.hint($0) }
        #expect(Set(hints).count == TiltMode.allCases.count)
        for hint in hints {
            #expect(!hint.isEmpty)
            #expect(hint.last == ".")
            #expect(!hint.contains("!"))
        }
    }

    @Test func defaultEnabledModeMatchesTheCinematicPreset() {
        var camera = CameraParams()
        camera.apply(preset: .cinematic)
        #expect(camera.tilt == Cinematic3D.enabledMode)

        var flat = CameraParams()
        flat.apply(preset: .balanced)
        #expect(flat.tilt == .off)
        #expect(!Cinematic3D.isEnabled(flat.tilt))
    }

    @Test func presetRoundTripKeepsTheTogglesSourceOfTruth() throws {
        var camera = CameraParams()
        camera.tilt = Cinematic3D.mode(.off, enabling: true)
        let data = try JSONEncoder().encode(camera)
        let rebuilt = try JSONDecoder().decode(CameraParams.self, from: data)
        #expect(rebuilt.tilt == camera.tilt)
        #expect(Cinematic3D.isEnabled(rebuilt.tilt))
        #expect(!Cinematic3D.isEnabled(Cinematic3D.mode(rebuilt.tilt, enabling: false)))
    }

    @Test func newControlsUseOnlyNativeSFSymbols() {
        let symbols = ["camera.aperture", "arrow.up.and.down", "move.3d"]
        for symbol in symbols {
            #expect(IconSymbols.exists(symbol), "\(symbol) must be a real macOS SF Symbol")
        }
    }
}
