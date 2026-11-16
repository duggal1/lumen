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

/// Starts the agent daemon. The daemon is the same engine as the UI, so the
/// windowed app serves it too: an agent and a human can work on the same
/// projects at the same time.
@MainActor
final class LumenAppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    private var daemon: LumenDaemon?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model = LumenAppDelegate.model else { return }
        startDaemon(model)
        #if DEBUG
        if CommandLine.arguments.contains("--bar-preview") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                model.showRecordingControls()
                if let panel = CommandLine.arguments.firstIndex(of: "--bar-panel"), panel + 1 < CommandLine.arguments.count {
                    let id = CommandLine.arguments[panel + 1]
                    try? await Task.sleep(for: .milliseconds(700))
                    model.showBarPanel(id)
                }
            }
        }
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = LumenAppDelegate.model else { return .terminateNow }
        // Quit always quits. Cancelling here hid the windows and left the app
        // alive with nothing on screen, so only Force Quit could close it.
        // A live recording is saved first, then the process goes down.
        guard model.phase == .recording else { return .terminateNow }
        Task { @MainActor in
            await model.finishBeforeTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemon?.stop()
        daemon = nil
    }

    func startDaemon(_ model: AppModel) {
        guard daemon == nil else { return }
        let daemon = LumenDaemon(runtime: model)
        self.daemon = daemon
        do {
            try daemon.start()
            NSLog("Lumen agent daemon listening on \(LumenDaemon.defaultSocketPath().path)")
        } catch {
            NSLog("Lumen agent daemon failed to start: \(error)")
        }
    }
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
        LumenAppDelegate.model = model
        let delegate = LumenAppDelegate()
        delegate.startDaemon(model)
        application.run()
    }
}

/// The normal, windowed app. Unchanged from before the agent layer existed.
struct LumenUIApp: App {
    @NSApplicationDelegateAdaptor(LumenAppDelegate.self) private var delegate
    @State private var app: AppModel

    init() {
        let model = AppModel()
        _app = State(initialValue: model)
        LumenAppDelegate.model = model
    }

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
