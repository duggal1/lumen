import SwiftUI
import AppKit
import LumenUI
import LumenControl
import LumenCore

/// Headless mode: the daemon runs with no window, no Dock icon and no focus.
/// It is still a normal logged-in macOS session, because ScreenCaptureKit,
/// the event tap and AX all need a running main loop.
enum HeadlessMode {
    static var enabled: Bool { CommandLine.arguments.contains("--headless") }
}

/// The process entry point. The windowed app and the headless daemon are the
/// same binary and the same bundle id, so macOS permissions (Screen
/// Recording, Accessibility, Input Monitoring) are attributed to Lumen in
/// both cases.
@main
enum LumenMain {
    static func main() {
        if HeadlessMode.enabled {
            HeadlessRunner.run()
        } else {
            LumenUIApp.main()
        }
    }
}

/// The daemon: accessory policy, no windows, one private socket.
@MainActor
enum HeadlessRunner {
    static func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let model = AppModel()
        model.headless = true
        let daemon = LumenDaemon(runtime: model)
        do {
            try daemon.start()
            NSLog("Lumen agent daemon listening on \(LumenDaemon.defaultSocketPath().path)")
        } catch {
            NSLog("Lumen agent daemon failed to start: \(error)")
        }
        application.run()
    }
}

/// The normal, windowed app. Unchanged from before the agent layer existed.
struct LumenUIApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        Window("Lumen", id: "library") {
            #if DEBUG
            if DebugFlags.isActive {
                DebugFixtureView(screen: DebugFlags.screen, state: DebugFlags.state)
            } else {
                LibraryRoot(app).background(WindowChrome())
                    .onOpenURL { app.openURL($0) }
            }
            #else
            LibraryRoot(app).background(WindowChrome())
                .onOpenURL { app.openURL($0) }
            #endif
        }
        .defaultSize(width: Metrics.windowW, height: Metrics.windowH)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        WindowGroup("Editor", id: "editor", for: URL.self) { $url in
            if let url { EditorRoot(url: url) }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent(app)
        } label: {
            Label(app.phase == .recording ? (app.paused ? "Paused" : "Recording") : "Lumen",
                  systemImage: app.phase == .recording ? (app.paused ? "pause.circle.fill" : "record.circle.fill") : "record.circle")
        }
    }
}
