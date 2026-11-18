import Testing
import Foundation
@testable import LumenUI

/// Floating-bar visibility is pure state: hidden on a fresh install, flipped
/// by the status-item action, and restored on the next launch. No window and
/// no status item is created by any of these checks.
@Suite(.serialized) struct StudioStageUIVisibilityTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "ui6.visibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func freshInstallStartsWithTheBarHidden() {
        let defaults = freshDefaults()
        #expect(FloatingBarVisibility.isHidden(defaults: defaults))
        #expect(FloatingBarVisibility.defaultHidden)
    }

    @Test func toggleFlipsVisibilityBothWays() {
        let defaults = freshDefaults()
        #expect(FloatingBarVisibility.isHidden(defaults: defaults))
        #expect(!FloatingBarVisibility.toggle(defaults: defaults))
        #expect(!FloatingBarVisibility.isHidden(defaults: defaults))
        #expect(FloatingBarVisibility.toggle(defaults: defaults))
        #expect(FloatingBarVisibility.isHidden(defaults: defaults))
    }

    @Test func repeatedToggleNeverDrifts() {
        let defaults = freshDefaults()
        for i in 0..<12 {
            let hidden = FloatingBarVisibility.toggle(defaults: defaults)
            #expect(hidden == (i % 2 == 1), "toggle \(i) drifted")
        }
        #expect(FloatingBarVisibility.isHidden(defaults: defaults))
    }

    @Test func explicitChoiceWinsOverTheDefault() {
        let defaults = freshDefaults()
        FloatingBarVisibility.show(defaults: defaults)
        #expect(!FloatingBarVisibility.isHidden(defaults: defaults))
        FloatingBarVisibility.hide(defaults: defaults)
        #expect(FloatingBarVisibility.isHidden(defaults: defaults))
    }

    @Test func visibilitySurvivesANewReader() {
        let suite = "ui6.visibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        FloatingBarVisibility.show(defaults: defaults)
        let secondReader = UserDefaults(suiteName: suite)!
        #expect(!FloatingBarVisibility.isHidden(defaults: secondReader))
    }

    @MainActor
    @Test func appToggleReadsAndAppliesPersistedState() async throws {
        let key = FloatingBarVisibility.defaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        let previousAutoInstall = FloatingBarMenuBarToggle.autoInstallEnabled
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            FloatingBarMenuBarToggle.autoInstallEnabled = previousAutoInstall
        }
        FloatingBarMenuBarToggle.autoInstallEnabled = false
        FloatingBarVisibility.show()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui6-floating-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = AppModel(library: root)
        #expect(!app.floatingBarHidden, "the app must read the persisted choice")
        // The bar was never presented in this headless test, so hiding it only
        // flips state: no panel is ordered out and no window is created.
        app.toggleFloatingBar()
        #expect(app.floatingBarHidden)
        #expect(FloatingBarVisibility.isHidden())
    }

    @Test func oneStatusItemThatNeverStealsFocus() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }
        func code(_ text: String) -> String {
            text.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let toggle = code(try source("Sources/LumenUI/Floating/MenuBarToggle.swift"))
        #expect(toggle.contains("statusItem(withLength:"), "one status item exists")
        for banned in ["NSApp.activate", "makeKeyAndOrderFront", "NSMenu("] {
            #expect(!toggle.contains(banned), "\(banned) steals focus or adds a second menu")
        }
        // No other file in the UI or app target creates a second status item.
        for file in ["Sources/LumenUI/AppModel.swift", "Sources/LumenApp/LumenApp.swift"] {
            #expect(!code(try source(file)).contains("statusItem(withLength:"),
                    "\(file) must not create a second menu-bar icon")
        }
    }
}
