import SwiftUI
import LumenUI

@main
struct LumenApp: App {
    @State private var app = AppModel()
    var body: some Scene {
        Window("Lumen", id: "library") { LibraryRoot(app) }
        WindowGroup("Editor", id: "editor", for: URL.self) { $url in
            if let url { EditorRoot(url: url) }
        }
        MenuBarExtra {
            MenuBarContent(app)
        } label: {
            Label(app.recordingStatus, systemImage: app.phase == .recording ? "record.circle.fill" : "record.circle")
        }
    }
}