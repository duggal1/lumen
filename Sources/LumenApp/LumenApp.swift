import SwiftUI
import LumenUI

@main
struct LumenApp: App {
    @State private var app = AppModel()
    var body: some Scene {
        Window("Lumen", id: "library") {
            LibraryRoot(app).background(WindowChrome())
                .onOpenURL { app.openURL($0) }
        }
        .defaultSize(width: Metrics.windowW, height: Metrics.windowH)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        WindowGroup("Editor", id: "editor", for: URL.self) { $url in
            if let url { EditorRoot(url: url) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        MenuBarExtra {
            MenuBarContent(app)
        } label: {
            Label(app.recordingStatus, systemImage: app.phase == .recording ? (app.paused ? "pause.circle.fill" : "record.circle.fill") : "record.circle")
        }
    }
}