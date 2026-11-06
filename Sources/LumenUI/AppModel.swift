import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit
import Carbon.HIToolbox
import LumenCore
import LumenProject
import LumenCapture
import LumenSpeech

@MainActor @Observable public final class AppModel {
    public enum Phase: Equatable { case idle, preparing, countdown(Int), recording, finishing }
    enum SourceKind: String, CaseIterable { case display, window, region }
    struct ProjectRow: Identifiable {
        var id: URL { url }
        let url: URL
        let name: String
        let date: Date
        let size: String
        let duration: Double
        let width: Int, height: Int
        let fps: Double
        let dropped: Int
        let unreadable: Bool
        /// Capture pixels, named the way a person would name the output.
        var output: String {
            guard width > 0 else { return "—" }
            let tier = width >= 3840 ? "4K" : width >= 2560 ? "1440p" : width >= 1920 ? "1080p" : "\(width)×\(height)"
            return "\(tier) \(Int(fps.rounded()))"
        }
    }

    public var recordingStatus: String {
        switch phase {
        case .idle: return "Lumen"
        case .preparing: return "Preparing recording"
        case .countdown(let seconds): return "Recording in \(seconds)"
        case .recording:
            let t = String(format: "%d:%02d", Int(stats?.elapsed ?? 0) / 60, Int(stats?.elapsed ?? 0) % 60)
            return (paused ? "Paused " : "Recording ") + t
        case .finishing: return "Saving recording"
        }
    }

    public var phase = Phase.idle
    /// Mirrors `RecordingSession.isPaused` for the HUD.
    public var paused = false
    /// Bundles that crashed mid-recording and can be rebuilt from their journal.
    var recoverable: [ProjectBundle] = []
    var kind = SourceKind(rawValue: UserDefaults.standard.string(forKey: "LumenDefaultSource") ?? "") ?? .display {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: "LumenDefaultSource") }
    }
    var displayID = CGMainDisplayID()
    var windowID: CGWindowID = 0
    var fps = UserDefaults.standard.object(forKey: "LumenDefaultFPS") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(fps, forKey: "LumenDefaultFPS") }
    }
    var mic = true
    /// Empty means use the macOS default input. When nonempty, the first
    /// input uses ScreenCaptureKit and remaining inputs are independent CAFs.
    var micInputIDs: [String] = UserDefaults.standard.stringArray(forKey: "LumenMicrophoneInputIDs") ?? [] {
        didSet { UserDefaults.standard.set(micInputIDs, forKey: "LumenMicrophoneInputIDs") }
    }
    var availableAudioInputs: [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio,
                                         position: .unspecified).devices
            .map { (id: $0.uniqueID, name: $0.localizedName) }
    }
    func selectAudioInput(_ id: String, enabled: Bool) {
        var selected = micInputIDs.filter { $0 != id }
        if enabled { selected.append(id) }
        micInputIDs = selected
    }
    var system = false
    var webcam = false
    var livePreview = false
    private var livePreviewController: LivePreviewController?
    var displays: [(id: CGDirectDisplayID, name: String)] = []
    var windows: [(id: CGWindowID, name: String)] = []
    var error: String?
    var stats: CaptureStats?
    var projects: [ProjectRow] = []
    public var onFinished: ((URL) -> Void)?
    public let library: URL
    private let session = RecordingSession()
    private var hud: HUDController?
    private var hotKey: HotKey?
    private var poll: Task<Void, Never>?
    let live = LiveCaptionModel()
    var liveNote: String?
    private var liveTranscriber: LiveTranscriber?
    private var liveHUD: LiveCaptionPanel?
    var modelDownloadProgress: Double?
    var modelDownloadError: String?
    private var modelDownloadTask: Task<Void, Never>?

    public init() {
        library = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumen")
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        refresh()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in Task { @MainActor in self?.toggle() } }
        ensureTinyModel()
    }

    func refresh() {
        displays = NSScreen.screens.compactMap { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { ($0, s.localizedName) }
        }
        let urls = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        projects = urls.filter { $0.pathExtension == "lumen" }.compactMap { u in
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let file = try? ProjectBundle(url: u).load()
            let meta = file?.meta
            return ProjectRow(url: u,
                              name: Self.displayName(meta?.name ?? u.deletingPathExtension().lastPathComponent),
                              date: meta?.created ?? d,
                              size: meta.map { "\($0.source.width)×\($0.source.height) · \(Int($0.source.duration)) s" } ?? "Couldn’t read this recording.",
                              duration: meta?.source.duration ?? 0,
                              width: meta?.source.width ?? 0, height: meta?.source.height ?? 0,
                              fps: meta?.source.fps ?? 0,
                              dropped: meta?.droppedFrames ?? 0,
                              unreadable: meta == nil || !FileManager.default.fileExists(atPath: u.appendingPathComponent("screen.mov").path))
        }.sorted { $0.date > $1.date }
        recoverable = RecoveryScanner.scan(library: library)
        Task {
            let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            windows = (c?.windows ?? []).filter { $0.isOnScreen && ($0.title?.isEmpty == false) && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
                .map { ($0.windowID, "\($0.owningApplication?.applicationName ?? "") — \($0.title ?? "")") }
            if windowID == 0 { windowID = windows.first?.id ?? 0 }
        }
    }

    /// Bundles created before human naming carry an ISO stamp; the meta line already holds the time.
    static func displayName(_ raw: String) -> String {
        let pattern = #"^Recording \d{4}-\d{2}-\d{2}T\d{6}(.*)$"#
        guard raw.range(of: pattern, options: .regularExpression) != nil else { return raw }
        return raw.replacingOccurrences(of: pattern, with: "Screen recording$1", options: .regularExpression)
    }

    public func showRecordingControls() { hud?.show() }

    // MARK: Library metrics (real data only: zero is a gap, never a fake number)

    var recent: [ProjectRow] { Array(projects.prefix(5)) }
    var totalRecorded: Double { projects.reduce(0) { $0 + $1.duration } }
    var recordedToday: Double {
        let cal = Calendar.current
        return projects.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.duration }
    }
    var exportedCount: Int {
        get { UserDefaults.standard.integer(forKey: "LumenExportedCount") }
        set { UserDefaults.standard.set(newValue, forKey: "LumenExportedCount") }
    }
    /// Consecutive days ending today (or yesterday, before the first recording of the day) with work recorded.
    var streak: Int {
        let days = Set(projects.map { Calendar.current.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: day), days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var n = 0
        while days.contains(day) {
            n += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return n
    }
    /// Minutes recorded per start-of-day, for the month graph.
    var minutesByDay: [Date: Double] {
        var out: [Date: Double] = [:]
        let cal = Calendar.current
        for p in projects { out[cal.startOfDay(for: p.date), default: 0] += p.duration / 60 }
        return out
    }

    // MARK: Destructive actions act first, then offer a 6 s undo.

    func trash(_ row: ProjectRow) -> URL? {
        var moved: NSURL?
        do {
            try FileManager.default.trashItem(at: row.url, resultingItemURL: &moved)
            refresh()
            return moved as URL?
        } catch { self.error = "Couldn’t delete this recording. \(error.localizedDescription)"; return nil }
    }

    func restore(_ row: ProjectRow, from trashURL: URL) {
        do {
            try FileManager.default.moveItem(at: trashURL, to: row.url)
            refresh()
        } catch { self.error = "Couldn’t restore this recording. \(error.localizedDescription)" }
    }

    func duplicate(_ row: ProjectRow) {
        let base = library.appendingPathComponent(row.name + " copy")
        var dest = base.appendingPathExtension("lumen"), n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = library.appendingPathComponent("\(row.name) copy \(n)").appendingPathExtension("lumen")
            n += 1
        }
        do { try FileManager.default.copyItem(at: row.url, to: dest); refresh() }
        catch { self.error = "Couldn’t duplicate this recording. \(error.localizedDescription)" }
    }


    private func prepareLive(for cfg: RecordingConfig) async {
        liveNote = nil
        let on = UserDefaults.standard.object(forKey: CaptionKeys.enabled) as? Bool ?? true
        guard cfg.mic, on, ProcessInfo.processInfo.environment["LUMEN_NO_LIVE_CAPTIONS"] == nil else { await session.setMicTap(nil); return }
        let size = MoonshineSize.current
        guard MoonshineRuntime.isAvailable, ModelStore.isInstalled(size) else {
            liveNote = "Live captions are off: the Moonshine \(size.title) model isn't installed."
            await session.setMicTap(nil); return
        }
        let t = LiveTranscriber(size: size)
        liveTranscriber = t; live.attach(t)
        let p = LiveCaptionPanel(live, app: self); liveHUD = p; p.show()      // before prepare(): the capture filter excludes our own windows
        await session.setMicTap { ptr, n, rate, host in t.push(ptr, n, rate: rate, hostSeconds: host) }
        t.start()                                                              // model loads during the countdown
    }

    private func finishLive(_ t: LiveTranscriber, bundle b: ProjectBundle) async {
        let res = await t.finish()
        live.detach(); liveHUD?.close(); liveHUD = nil; liveTranscriber = nil
        guard !res.transcript.words.isEmpty || res.complete else { return }
        try? b.saveTranscript(TranscriptFile(engine: res.engine, complete: res.complete, transcript: res.transcript))
    }

    func ensureTinyModel() {
        guard !ModelStore.isInstalled(.tiny) else { return }
        modelDownloadTask?.cancel()
        modelDownloadTask = Task { @MainActor in
            modelDownloadProgress = 0
            do {
                try await ModelDownloader.download(size: .tiny) { p in
                    Task { @MainActor in self.modelDownloadProgress = p }
                }
                modelDownloadProgress = nil
            } catch {
                modelDownloadError = error.localizedDescription
                modelDownloadProgress = nil
            }
        }
    }

    public func toggle() {
        switch phase { case .idle: Task { await start() }; case .recording: Task { await stop() }; default: break }
    }

    func togglePause() {
        guard phase == .recording else { return }
        Task {
            await session.togglePause()
            paused = await session.isPaused
        }
    }

    /// Rebuilds a crashed recording from its journal and opens it.
    func recover(_ bundle: ProjectBundle) {
        do {
            guard try bundle.recoverFromJournal() != nil else {
                error = "This recording has no usable frames yet."; return
            }
            refresh()
            onFinished?(bundle.url)
        } catch { self.error = "Couldn’t recover this recording. \(error.localizedDescription)" }
    }

    func discardRecovery(_ bundle: ProjectBundle) {
        bundle.clearJournal(); refresh()
    }

    func importSharedProject() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [UTType(filenameExtension: "lumenshare") ?? .archive]
        picker.allowsMultipleSelection = false
        picker.prompt = "Import shared project"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let bundle = try ProjectBundle.installSharePackage(url, into: library)
            refresh()
            onFinished?(bundle.url)
        } catch { self.error = "Couldn’t import this shared project. \(error.localizedDescription)" }
    }

    /// `lumen://open?path=…` links copied from the editor.
    public func openURL(_ url: URL) {
        guard url.scheme == "lumen",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value else { return }
        let bundle = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            error = "That project link points at a missing file."; return
        }
        onFinished?(bundle)
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .preparing
        defer { if phase == .preparing { phase = .idle } }
        error = nil
        guard Permissions.screen else { Permissions.requestScreen(); error = "Screen Recording is off. Grant it, then relaunch Lumen."; return }
        guard Permissions.input else { Permissions.requestInput(); error = "Input Monitoring is off. Grant it, then relaunch Lumen."; return }
        if mic || webcam { await Permissions.requestMedia() }
        var cfg: RecordingConfig
        switch kind {
        case .display: cfg = RecordingConfig(source: .display(displayID))
        case .window: cfg = RecordingConfig(source: .window(windowID))
        case .region:
            guard let r = await RegionSelector.pick() else { return }
            cfg = RecordingConfig(source: .region(r.display, r.rect))
        }
        cfg.fps = fps; cfg.mic = mic && Permissions.mic; cfg.systemAudio = system
        if cfg.mic && !micInputIDs.isEmpty {
            let available = Set(availableAudioInputs.map(\.id))
            guard micInputIDs.allSatisfy({ available.contains($0) }) else {
                error = "A selected audio input is disconnected. Update microphone inputs before recording."
                return
            }
            cfg.micDeviceID = micInputIDs.first
            cfg.additionalMicDeviceIDs = Array(micInputIDs.dropFirst())
        }
        cfg.webcamDeviceID = webcam && Permissions.camera ? AVCaptureDevice.default(for: .video)?.uniqueID : nil
        phase = .preparing
        let sourceDisplay: CGDirectDisplayID?
        switch cfg.source {
        case .display(let id), .region(let id, _): sourceDisplay = id
        case .window: sourceDisplay = nil
        }
        let recordingScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == sourceDisplay
        } ?? NSScreen.main
        hud = HUDController(self, screen: recordingScreen)
        hud?.show()
        await prepareLive(for: cfg)
        if livePreview { livePreviewController = LivePreviewController(); livePreviewController?.show() }
        do {
            try await session.prepare(cfg, library: library)
            if let hub = livePreviewController?.hub { await session.setLiveHooks(frame: { hub.frame($0) }, event: { hub.event($0) }) }
            for n in [3, 2, 1] { phase = .countdown(n); try await Task.sleep(for: .seconds(1)) }
            try await session.start(); phase = .recording
            hud?.show()
            poll = Task { while !Task.isCancelled { stats = await session.stats(); try? await Task.sleep(for: .milliseconds(250)) } }
        } catch { fail(error) }
    }

    func stop() async {
        phase = .finishing; poll?.cancel()
        do {
            let b = try await session.stop()
            paused = false
            if let t = liveTranscriber { await finishLive(t, bundle: b) }
            hud?.close(); hud = nil; livePreviewController?.close(); livePreviewController = nil; phase = .idle; refresh(); onFinished?(b.url)
        } catch { fail(error) }
    }

    private func fail(_ e: Error) {
        poll?.cancel(); paused = false
        liveTranscriber?.cancel(); liveTranscriber = nil; live.detach(); liveHUD?.close(); liveHUD = nil
        hud?.close(); hud = nil; livePreviewController?.close(); livePreviewController = nil
        phase = .idle; error = "Recording failed. \(e)"
    }
}

/// 12-hour by default, 24-hour from Settings. One format for every meta line.
enum ClockFormat {
    static var uses24Hour: Bool { UserDefaults.standard.bool(forKey: "Lumen24Hour") }
    static func time(_ date: Date) -> String {
        if uses24Hour {
            return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute(.twoDigits))
    }
}

// MARK: Global hotkey (Carbon, no dependency)

final class HotKey: @unchecked Sendable {
    nonisolated(unsafe) private static var handler: (() -> Void)?
    private var ref: EventHotKeyRef?
    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        Self.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in HotKey.handler?(); return noErr }, 1, &spec, nil, nil)
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4C554D4E), id: 1), GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: Region selector (borderless overlay, drag to select, Esc cancels)

@MainActor enum RegionSelector {
    static func pick() async -> (display: CGDirectDisplayID, rect: CGRect)? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<(display: CGDirectDisplayID, rect: CGRect)?, Never>) in
            let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver; w.isOpaque = false; w.backgroundColor = .clear; w.ignoresMouseEvents = false
            let v = RegionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.finish = { rect in
                w.orderOut(nil)
                c.resume(returning: rect.map { (id, CGRect(x: $0.minX, y: screen.frame.height - $0.maxY, width: $0.width, height: $0.height)) })   // AppKit -> top-left
            }
            w.contentView = v; w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v); NSCursor.crosshair.push()
        }
    }
}
private final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }
private final class RegionView: NSView {
    var finish: ((CGRect?) -> Void)?
    private var a: CGPoint?, b: CGPoint?
    private var rect: CGRect? { guard let a, let b else { return nil }; return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with e: NSEvent) { a = convert(e.locationInWindow, from: nil); b = a; needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { b = convert(e.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with e: NSEvent) { NSCursor.pop(); finish?(rect.flatMap { $0.width > 40 && $0.height > 40 ? $0 : nil }) }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { NSCursor.pop(); finish?(nil) } }
    override func draw(_ dirty: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill(); bounds.fill()
        guard let r = rect else { return }
        NSColor.clear.setFill(); r.fill(using: .copy)
        let s = "\(Int(r.width)) × \(Int(r.height))" as NSString
        s.draw(at: CGPoint(x: r.minX + 6, y: r.maxY + 6), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
    }
}

// MARK: Recorder HUD (non-activating, excluded from capture)

@MainActor final class HUDController {
    private var panel: NSPanel?
    init(_ app: AppModel, screen: NSScreen?) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 64), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = NSHostingView(rootView: HUDView(app: app))
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.sharingType = .none
        p.hidesOnDeactivate = false
        p.canHide = false
        p.isFloatingPanel = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.title = "Lumen recording controls"
        p.setAccessibilityLabel("Lumen recording controls")
        if let screen {
            let frame = screen.visibleFrame
            p.setFrameOrigin(CGPoint(x: frame.midX - 200, y: frame.maxY - 80))
        }
        panel = p
    }
    func show() { panel?.orderFrontRegardless() }
    func close() { panel?.orderOut(nil); panel = nil }
}

struct HUDView: View {
    let app: AppModel
    var body: some View {
        HStack(spacing: 12) {
            switch app.phase {
            case .countdown(let n):
                Text("\(n)").font(AppType.metric).foregroundStyle(Tok.text).frame(width: 40)
                Text("Recording starts…").font(AppType.body).foregroundStyle(Tok.text2); Spacer()
            case .recording:
                PixelStop(cell: 2)
                Text(app.paused ? "Paused" : "Recording").font(AppType.label)
                    .foregroundStyle(app.paused ? Tok.activity : Tok.text)
                Text(time(app.stats?.elapsed ?? 0)).font(AppType.label.monospacedDigit()).foregroundStyle(Tok.text)
                PixelMeter(level: app.stats?.micLevel ?? 0)
                if (app.stats?.dropped ?? 0) > 0 { PixelBadge(kind: .caution, text: "\(app.stats?.dropped ?? 0) dropped") }
                Spacer()
                LButton(title: app.paused ? "Resume" : "Pause",
                        icon: app.paused ? "play.fill" : "pause.fill", kind: .secondary) { app.togglePause() }
                LButton(title: "Stop", icon: "stop.fill", kind: .primary) { app.toggle() }
            default:
                PixelWait(); Text(app.phase == .finishing ? "Saving…" : "Preparing…").font(AppType.body).foregroundStyle(Tok.text2); Spacer()
            }
        }.padding(.horizontal, 12).frame(width: 400, height: 64).background(RoundedRectangle(cornerRadius: 16).fill(Tok.surface))
    }
    private func time(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}