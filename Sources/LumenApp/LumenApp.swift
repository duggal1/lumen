import SwiftUI
import LumenUI

@main
struct LumenApp: App {
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
            Label(app.recordingStatus, systemImage: app.phase == .recording ? (app.paused ? "pause.circle.fill" : "record.circle.fill") : "record.circle")
        }
    }
}