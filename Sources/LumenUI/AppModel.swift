import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit
import Carbon.HIToolbox
import LumenCore
import LumenProject
import LumenCapture

public enum WebcamQuality: String, CaseIterable, Sendable { case auto, q4k, q1080, q720
    var title: String { switch self { case .auto: "Auto"; case .q4k: "4K"; case .q1080: "1080p"; case .q720: "720p" } }
}

@MainActor @Observable public final class AppModel {
    public enum Phase: Equatable { case idle, preparing, countdown(Int), recording, finishing }
    enum SourceKind: String, CaseIterable { case display, window, region }
    private enum RecoveryResult: Sendable { case recovered, noUsableFrames, failed(String) }
    private enum RecoveryDiscardResult: Sendable { case discarded, failed(String) }
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
        let appUsage: [RecordedAppUsage]
        /// Capture pixels, named the way a person would name the output.
        var output: String {
            guard width > 0 else { return "—" }
            return "\(width)x\(height) · \(Int(fps.rounded()))"
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
        case .finishing: return "Saving recording \(Int(finalizeProgress * 100))%"
        }
    }

    public var finalizeProgress = 0.0
    public var phase = Phase.idle
    /// Mirrors `RecordingSession.isPaused` for the HUD.
    public var paused = false
    /// Headless mode: the daemon runs the same engine with no window and no
    /// floating recorder panel.
    public var headless = false
    /// An agent-driven recording target. When set, `start()` records exactly
    /// this instead of the UI's current selection.
    public var agentTarget: RecordingTarget?
    /// Options for an agent-driven recording.
    public var agentOptions: RecordingOptions?
    /// Markers recorded during the session, written into the project on stop.
    var pendingMarkers: [CaptureMarker] = []
    // AGENT: remember the initiator through finalization after agentTarget is cleared.
    var agentRecording = false
    /// The project the last recording produced.
    public private(set) var lastProjectURL: URL?
    public var micTesting = false
    public var micTestLevel: Float = 0
    /// Real per-buffer peaks, newest last, for the pixel scope.
    public var micTestWave: [Float] = []
    /// RMS in dBFS from the raw input, no cosmetic gain.
    public var micTestDB: Float = -60
    private var micTestEngine: AVAudioEngine?
    /// Bundles that crashed mid-recording and can be rebuilt from their journal.
    var recoverable: [ProjectBundle] = []
    private var recoveryOperations: Set<URL> = []
    var kind = SourceKind(rawValue: UserDefaults.standard.string(forKey: "LumenDefaultSource") ?? "") ?? .display {
        didSet { UserDefaults.standard.set(kind.rawValue, forKey: "LumenDefaultSource") }
    }
    var displayID = CGMainDisplayID()
    /// Intelligent Area crop settings for the next recording. Kept in memory;
    /// the derived crop is persisted in the project's Timeline.
    var smartCrop = SmartCropConfig()
    var windowID: CGWindowID = 0
    var fps = UserDefaults.standard.object(forKey: "LumenDefaultFPS") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(fps, forKey: "LumenDefaultFPS") }
    }
    var captureResolution = RecordingConfig.Resolution(rawValue: UserDefaults.standard.string(forKey: "LumenCaptureRes") ?? "") ?? .native {
        didSet { UserDefaults.standard.set(captureResolution.rawValue, forKey: "LumenCaptureRes") }
    }
    var captureQuality = RecordingConfig.Quality(rawValue: UserDefaults.standard.string(forKey: "LumenCaptureQ") ?? "") ?? .high {
        didSet { UserDefaults.standard.set(captureQuality.rawValue, forKey: "LumenCaptureQ") }
    }
    var captureMbps: Double = UserDefaults.standard.object(forKey: "LumenCaptureMbps") as? Double ?? 20 {
        didSet { UserDefaults.standard.set(captureMbps, forKey: "LumenCaptureMbps") }
    }
    var mic = UserDefaults.standard.object(forKey: "LumenCaptureMic") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mic, forKey: "LumenCaptureMic") }
    }
    var micDeviceID = UserDefaults.standard.string(forKey: "LumenMicDevice") ?? "" {
        didSet { UserDefaults.standard.set(micDeviceID, forKey: "LumenMicDevice") }
    }
    var system = UserDefaults.standard.bool(forKey: "LumenCaptureSystem") {
        didSet { UserDefaults.standard.set(system, forKey: "LumenCaptureSystem") }
    }
    var webcam = UserDefaults.standard.bool(forKey: "LumenCaptureWebcam") {
        didSet { UserDefaults.standard.set(webcam, forKey: "LumenCaptureWebcam") }
    }
    var webcamQuality = WebcamQuality(rawValue: UserDefaults.standard.string(forKey: "LumenWebcamQuality") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(webcamQuality.rawValue, forKey: "LumenWebcamQuality") }
    }
    var cameraDeviceID = UserDefaults.standard.string(forKey: "LumenCameraDevice") ?? "" {
        didSet { UserDefaults.standard.set(cameraDeviceID, forKey: "LumenCameraDevice") }
    }
    var showCameraPreview = UserDefaults.standard.bool(forKey: "LumenCameraPreview") {
        didSet { UserDefaults.standard.set(showCameraPreview, forKey: "LumenCameraPreview") }
    }
    /// 0 or 3. The countdown is a setting, not a surprise.
    var countdownSeconds = UserDefaults.standard.object(forKey: "LumenCountdown") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(countdownSeconds, forKey: "LumenCountdown") }
    }
    /// The last area the user picked, and the short list they can return to.
    var lastArea: AreaPreset? {
        didSet { if let lastArea { addAreaPreset(lastArea) } }
    }
    private(set) var areaPresets: [AreaPreset] = AreaPreset.load()
    var livePreview = false
    private var livePreviewController: LivePreviewController?
    var displays: [(id: CGDirectDisplayID, name: String)] = []
    /// Refresh the panel reports. Display copy only: 120 fps stays offered on a
    /// 60 Hz panel, where it still gives the smoothest capture the system can
    /// deliver and a 120 fps project timeline.
    var maxFPS = 60
    var supportedFPS: [Int] { [24, 30, 60, 120] }
    var windows: [(id: CGWindowID, name: String, appID: String, appName: String)] = []
    var error: String?
    var stats: CaptureStats?
    /// Cached TCC state. Views read this; nothing in a view body may call
    /// `Permissions.*`, because those are blocking IPC into tccd and the
    /// redraw that Stop triggers landed on the main thread mid-teardown.
    var permissions = PermissionSnapshot()
    let recordingMeter = RecordingMeter()
    var projects: [ProjectRow] = []
    public var onFinished: ((URL) -> Void)?
    var onShowLibrary: (() -> Void)?
    public private(set) var library: URL
    /// The capture session. Internal so the agent runtime adapter can drive
    /// the same lifecycle the UI buttons drive.
    let session = RecordingSession()
    private var appUsageRecorder: RecordingAppUsage?
    private var bar: FloatingBarController?
    /// Set while the app is quitting so a saved recording does not reopen UI.
    private var terminating = false
    private var hotKey: HotKey?
    private var pauseHotKey: HotKey?
    private var poll: Task<Void, Never>?
    private var permissionObserver: NSObjectProtocol?
    private var hiddenWindows: [NSWindow] = []
    private var cancelRequested = false

    public init(library: URL? = nil) {
        self.library = library ?? AppModel.defaultLibrary()
        try? FileManager.default.createDirectory(at: self.library, withIntermediateDirectories: true)
        refresh()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in Task { @MainActor in self?.toggle() } }
        // Cmd+Opt+P toggles pause while recording (start/stop is Cmd+Opt+R).
        pauseHotKey = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in Task { @MainActor in self?.togglePause() } }
        // Seed the cache once at launch, before any capture runs. Later reads
        // are off-main; this one cannot deadlock because nothing is recording.
        permissions = PermissionSnapshot.read()
        // A grant or revoke happens in System Settings, which deactivates us.
        // Re-read when the user comes back instead of on every redraw.
        permissionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    /// Re-reads TCC off the main thread and publishes the result. Cheap enough
    /// to call on activation; never called from a view body.
    func refreshPermissions() {
        Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) { PermissionSnapshot.read() }.value
            self?.permissions = snapshot
        }
    }

    func refresh() {
        displays = NSScreen.screens.compactMap { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { ($0, s.localizedName) }
        }
        maxFPS = Self.probeMaxFPS(displayID: displayID)
        // Project metas + recovery scan are disk work: load off-main so the
        // shell appears immediately, then publish incrementally.
        let library = self.library
        Task { @MainActor [weak self] in
            guard let self else { return }
            let rows = await Task.detached(priority: .userInitiated) {
                let urls = (try? FileManager.default.contentsOfDirectory(at: library,
                    includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                return urls.filter { $0.pathExtension == "lumen" }.compactMap { u -> ProjectRow in
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
                              unreadable: meta == nil || !FileManager.default.fileExists(atPath: u.appendingPathComponent("screen.mov").path),
                              appUsage: (try? JSONDecoder().decode([RecordedAppUsage].self, from: Data(contentsOf: u.appendingPathComponent("app-usage.json")))) ?? [])
                }.sorted { $0.date > $1.date }
            }.value
            self.projects = rows
            self.recoverable = await Task.detached(priority: .userInitiated) { RecoveryScanner.scan(library: library) }.value
            let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            self.windows = (c?.windows ?? []).filter { $0.isOnScreen && ($0.title?.isEmpty == false) && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
                .map { ($0.windowID, "\($0.owningApplication?.applicationName ?? "") — \($0.title ?? "")", $0.owningApplication?.bundleIdentifier ?? "", $0.owningApplication?.applicationName ?? "") }
            if self.windowID == 0 { self.windowID = self.windows.first?.id ?? 0 }
        }
    }

    /// Bundles created before human naming carry an ISO stamp; the meta line already holds the time.
    nonisolated static func displayName(_ raw: String) -> String {
        let pattern = #"^Recording \d{4}-\d{2}-\d{2}T\d{6}(.*)$"#
        guard raw.range(of: pattern, options: .regularExpression) != nil else { return raw }
        return raw.replacingOccurrences(of: pattern, with: "Screen recording$1", options: .regularExpression)
    }

    static func probeMaxFPS(displayID: CGDirectDisplayID) -> Int {
        // Real display probe; fall back to 60Hz so we never offer 120 on a 60Hz panel.
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            let r = Double(screen.maximumFramesPerSecond)
            if r >= 119 { return 120 }
            if r >= 59 { return 60 }
            if r >= 29 { return 30 }
        }
        return 60
    }

    public func showRecordingControls() {
        presentBar(on: NSScreen.main)
        Task { await refreshWindows() }
    }

    public func showBarPanel(_ id: String) {
        bar?.present(options: id, in: self)
    }

    public var hasRecordingControls: Bool { bar != nil }

    private func presentBar(on screen: NSScreen?) {
        if bar == nil { bar = FloatingBarController(self, screen: screen ?? NSScreen.main) }
        bar?.show()
    }

    // MARK: What the floating bar configures

    /// Cameras the bar can offer. Real devices only; never a fabricated name.
    var cameraDevices: [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.map { ($0.uniqueID, $0.localizedName) }
    }

    var microphoneDevices: [(id: String, name: String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified)
            .devices.map { ($0.uniqueID, $0.localizedName) }
    }

    /// Normalizes a saved Area (display-relative top-left points) into the
    /// source-relative coordinates the crop planner uses.
    private func normalizedSmartCrop(for area: AreaPreset) -> SmartCropConfig {
        var config = smartCrop
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == area.displayID
        } ?? NSScreen.main
        if let screen, screen.frame.width > 0, screen.frame.height > 0 {
            config.roi = CGRect(x: area.x / screen.frame.width, y: area.y / screen.frame.height,
                                width: area.width / screen.frame.width, height: area.height / screen.frame.height)
        }
        return config
    }

    func setArea(display: CGDirectDisplayID, rect: CGRect) {
        lastArea = AreaPreset.make(display: display, rect: rect)
        kind = .region
    }

    private func addAreaPreset(_ preset: AreaPreset) {
        var list = areaPresets.filter { $0.displayID != preset.displayID || $0.rect != preset.rect }
        list.insert(preset, at: 0)
        areaPresets = Array(list.prefix(5))
        preset.save(areaPresets)
    }

    func removeAreaPreset(_ id: UUID) {
        areaPresets.removeAll { $0.id == id }
        if lastArea?.id == id { lastArea = nil }
        AreaPreset(name: "", displayID: 0, x: 0, y: 0, width: 0, height: 0).save(areaPresets)
    }

    /// The window list the bar's picker shows, refreshed on demand so it is
    /// never a stale snapshot from launch.
    func refreshWindows() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
        let own = Bundle.main.bundleIdentifier
        windows = content.windows
            .filter { $0.isOnScreen && ($0.title?.isEmpty == false) && $0.owningApplication?.bundleIdentifier != own }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            .map { ($0.windowID, $0.title ?? "", $0.owningApplication?.bundleIdentifier ?? "", $0.owningApplication?.applicationName ?? "") }
        if windowID == 0 || !windows.contains(where: { $0.id == windowID }) {
            windowID = windows.first?.id ?? 0
        }
    }

    static func defaultLibrary() -> URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumen")
    }

    /// Moves the recording library. Files stay where they are; new recordings
    /// land in the chosen folder.
    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Record here"
        panel.directoryURL = library
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            library = url
            refresh()
        } catch {
            self.error = "Couldn’t use that folder. \(error.localizedDescription)"
        }
    }


    func showLibrary() {
        onShowLibrary?()
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Lumen" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            restoreLibraryAfterFailure()
        }
    }

    // Keep the selected desktop visible, not the Library floating over it.
    // The recording controls are an independent, capture-excluded NSPanel.
    private func hideLibraryForRecording() {
        let controls = bar?.recordingWindow
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0 !== controls }
        for window in hiddenWindows { window.orderOut(nil) }
    }

    private func restoreLibraryAfterFailure() {
        for window in hiddenWindows { window.makeKeyAndOrderFront(nil) }
        hiddenWindows.removeAll()
    }

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


    public func toggle() {
        switch phase { case .idle: Task { await start() }; case .recording: Task { await stop() }; default: break }
    }

    func togglePause() {
        guard phase == .recording else { return }
        Task {
            await session.togglePause()
            paused = await session.isPaused
            appUsageRecorder?.setPaused(paused)
        }
    }

    /// Rebuilds a crashed recording from its journal and opens it.
    func recover(_ bundle: ProjectBundle) {
        let url = bundle.url.standardizedFileURL
        guard recoveryOperations.insert(url).inserted else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    guard try bundle.recoverFromJournal() != nil else { return RecoveryResult.noUsableFrames }
                    return RecoveryResult.recovered
                } catch {
                    return RecoveryResult.failed(error.localizedDescription)
                }
            }.value
            recoveryOperations.remove(url)
            switch result {
            case .recovered:
                refresh()
                onFinished?(bundle.url)
            case .noUsableFrames:
                error = "This recording has no usable frames yet."
            case .failed(let message):
                error = "Couldn’t recover this recording. \(message)"
            }
        }
    }

    func discardRecovery(_ bundle: ProjectBundle) {
        let url = bundle.url.standardizedFileURL
        guard recoveryOperations.insert(url).inserted else { return }
        guard url.pathExtension == "lumen", url.deletingLastPathComponent() == library.standardizedFileURL else {
            recoveryOperations.remove(url)
            error = "Couldn’t discard this recording because its project folder is outside the library."
            return
        }
        Task {
            let result = await Task.detached(priority: .utility) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    return RecoveryDiscardResult.discarded
                } catch {
                    return RecoveryDiscardResult.failed(error.localizedDescription)
                }
            }.value
            recoveryOperations.remove(url)
            switch result {
            case .discarded:
                refresh()
            case .failed(let message):
                error = "Couldn’t discard this recording. \(message)"
            }
        }
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

    public var micTestError: String?
    private var micTestToken = UUID()

    /// Toggle mic testing with a live waveform. Permission, missing devices
    /// and engine failures surface as state, never as a crash. The test runs
    /// until the user stops it (toggle off, dialog closes, or 60 s failsafe).
    public func testMicrophone() {
        if micTesting { stopMicrophoneTest(); return }
        guard !micTesting else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            Task {
                await Permissions.requestMedia()
                // Re-read off main: the answer is TCC IPC, not a view concern.
                let granted = await Task.detached(priority: .userInitiated) { Permissions.mic }.value
                if !granted { micTestError = "Microphone is off." } else { testMicrophone() }
            }
            return
        default: micTestError = "Microphone is off. Allow mic access in Settings."; return
        }
        let token = UUID(); micTestToken = token
        micTesting = true; micTestError = nil; micTestLevel = 0
        micTestWave = []; micTestDB = -60
        let engine = AVAudioEngine()
        micTestEngine = engine
        engine.prepare()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            micTesting = false; micTestEngine = nil
            micTestError = "No microphone input is available."
            return
        }
        final class TickBox: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let tickBox = TickBox()
        input.installTap(onBus: 0, bufferSize: 512, format: format) { @Sendable [weak self, token, tickBox] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength); guard n > 0 else { return }
            var sum: Float = 0; for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = (sum / Float(n)).squareRoot()
            // One peak per 10 ms-ish bucket: the scope shows the real envelope,
            // not a smoothed decoration.
            let buckets = 48
            let stride = max(n / buckets, 1)
            var peaks = [Float](repeating: 0, count: buckets)
            for b in 0..<buckets {
                var m: Float = 0
                let lo = b * stride, hi = min(lo + stride, n)
                if lo < hi { for i in lo..<hi { m = max(m, abs(ch[i])) } }
                peaks[b] = m
            }
            // Publish at ~20 Hz, not per buffer (~86/s), so the test does
            // not hop to main every 11 ms.
            tickBox.lock.lock()
            tickBox.n += 1
            let tick = tickBox.n
            tickBox.lock.unlock()
            guard tick % 4 == 0 else { return }
            DispatchQueue.main.async {
                Task { @MainActor in
                    guard let self, self.micTesting, self.micTestToken == token else { return }
                    let shown = min(rms * 6, 1)
                    self.micTestLevel = max(shown, self.micTestLevel * 0.75)
                    self.micTestWave = Array((self.micTestWave + peaks).suffix(96))
                    self.micTestDB = 20 * log10(max(rms, 0.000001))
                }
            }
        }
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            micTesting = false; micTestEngine = nil
            micTestError = "Couldn’t start the microphone. \(error.localizedDescription)"
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard micTestToken == token else { return }
            stopMicrophoneTest()
        }
    }

    public func stopMicrophoneTest() {
        micTestToken = UUID()
        micTestEngine?.inputNode.removeTap(onBus: 0)
        micTestEngine?.stop()
        micTestEngine = nil
        micTesting = false
        micTestLevel = 0
        micTestWave = []
        micTestDB = -60
    }

    /// Quit path: a recording in flight is finalized before the process goes
    /// down, without reopening the editor or the library the user is closing.
    public func finishBeforeTermination() async {
        guard phase == .recording else { return }
        terminating = true
        await stop()
    }

    /// Discards the in-progress recording entirely: stops capture, deletes
    /// the bundle, and returns to the library without opening the project.
    public func discard() {
        switch phase {
        case .recording:
            phase = .finishing; poll?.cancel()
            _ = appUsageRecorder?.finish(); appUsageRecorder = nil
            Task {
                if let message = await session.abandon() {
                    self.error = "Couldn’t discard this recording. \(message)"
                }
                endDiscard()
            }
        case .preparing, .countdown:
            // Nothing recorded yet: tear the prepared engine down instead of
            // finalizing frames that never existed.
            cancelRequested = true
            phase = .finishing
            Task { await abandon() }
        default:
            return
        }
    }

    private func endDiscard() {
        paused = false
        CameraBubbleController.shared.setVisible(false)
        livePreviewController?.close(); livePreviewController = nil
        phase = .idle; refresh()
        restoreLibraryAfterFailure()
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .preparing
        cancelRequested = false
        recordingMeter.level = 0
        stats = nil
        defer { if phase == .preparing { phase = .idle } }
        error = nil
        // One read, off main. The start gate must never block the main thread
        // on tccd, and the answer is reused for the config below.
        var perms = await Task.detached(priority: .userInitiated) { PermissionSnapshot.read() }.value
        permissions = perms
        guard perms.screen else { Permissions.requestScreen(); error = "Screen Recording is off. Grant it, then relaunch Lumen."; return }
        guard perms.input else { Permissions.requestInput(); error = "Input Monitoring is off. Grant it, then relaunch Lumen."; return }
        if !perms.accessibility { Permissions.requestAccessibility() }
        if mic || webcam {
            await Permissions.requestMedia()
            perms = await Task.detached(priority: .userInitiated) { PermissionSnapshot.read() }.value
            permissions = perms
        }
        var cfg: RecordingConfig
        switch kind {
        case .display: cfg = RecordingConfig(source: .display(displayID))
        case .window: cfg = RecordingConfig(source: .window(windowID))
        case .region:
            // AGENT: an agent's explicit region must not invoke the human region picker.
            // Intelligent crop captures the whole display and carries the chosen
            // rectangle as a normalized ROI instead of a hard sourceRect.
            let useSmart = smartCrop.enabled && agentTarget == nil
            if let target = agentTarget { cfg = RecordingConfig(source: .display(target.displayID ?? CGMainDisplayID())) }
            else if let area = lastArea {
                cfg = useSmart ? RecordingConfig(source: .display(area.displayID)) : RecordingConfig(source: .region(area.displayID, area.rect))
            } else {
                guard let picked = await AreaSelector.pick() else { return }
                setArea(display: picked.displayID, rect: picked.rect)
                guard let area = lastArea else { return }
                cfg = useSmart ? RecordingConfig(source: .display(area.displayID)) : RecordingConfig(source: .region(area.displayID, area.rect))
            }
            if useSmart, let area = lastArea {
                cfg.smartCrop = normalizedSmartCrop(for: area)
            }
        }
        // An agent may ask for an exact target; it wins over the UI selection.
        if let target = agentTarget {
            switch target.kind {
            case .display:
                cfg = RecordingConfig(source: .display(target.displayID ?? CGMainDisplayID()))
            case .window:
                let id = target.windowID ?? windows.first { $0.appID == (target.bundleID ?? "") }?.id ?? 0
                guard id != 0 else { error = "That window is not on screen."; return }
                cfg = RecordingConfig(source: .window(id))
            case .region:
                cfg = RecordingConfig(source: .region(target.displayID ?? CGMainDisplayID(),
                                                       target.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)))
            }
        }
        cfg.fps = fps; cfg.mic = mic && perms.mic; cfg.systemAudio = system
        cfg.rawRetentionDays = RawRetention.normalize(UserDefaults.standard.integer(forKey: "LumenRawRetentionDays"))
        cfg.deleteRawAfterExport = UserDefaults.standard.bool(forKey: "LumenDeleteRawAfterExport")
        cfg.micDeviceID = micDeviceID.isEmpty ? nil : micDeviceID
        cfg.webcamQuality = webcamQuality.rawValue
        cfg.resolution = captureResolution; cfg.quality = captureQuality; cfg.customMbps = captureMbps
        // A chosen camera beats the system default; never silently substitute.
        cfg.webcamDeviceID = webcam && perms.camera
            ? (AVCaptureDevice(uniqueID: cameraDeviceID) ?? AVCaptureDevice.default(for: .video))?.uniqueID
            : nil
        if let options = agentOptions {
            cfg.fps = options.fps
            cfg.mic = options.microphone && perms.mic
            cfg.systemAudio = options.systemAudio
            cfg.webcamDeviceID = options.webcam && perms.camera ? AVCaptureDevice.default(for: .video)?.uniqueID : nil
            // AGENT: the option existed but was never copied, so auto-mask did nothing.
            cfg.privacyAutoMask = options.privacyAutoMask
        }
        let sourceDisplay: CGDirectDisplayID?
        switch cfg.source {
        case .display(let id), .region(let id, _): sourceDisplay = id
        case .window: sourceDisplay = nil
        }
        let recordingScreen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == sourceDisplay
        } ?? NSScreen.main
        // The daemon runs without a window: no floating recorder panel, no
        // library. The agent drives the same engine through tools.
        if !headless && agentTarget == nil {
            presentBar(on: recordingScreen)
            hideLibraryForRecording()
            if livePreview {
                livePreviewController = LivePreviewController(config: cfg.smartCrop.isActive ? cfg.smartCrop : nil)
                livePreviewController?.show()
            }
        }
        do {
            // One preparation pass, then the countdown. The engine is warm
            // before "3" appears, so "1" is followed by the first frame instead
            // of another wait.
            let prepareTask = Task { try await session.prepare(cfg, library: library) }
            try await prepareTask.value
            guard !cancelRequested else { await abandon(); return }
            if let hub = livePreviewController?.hub {
                await session.setLiveHooks(frame: { hub.frame($0) }, event: { hub.event($0) }, focus: { hub.focus($0, $1) })
            }
            let ticks = max(0, min(agentOptions?.countdownSeconds ?? countdownSeconds, 10))
            if ticks > 0 {
                await session.markCountdown()
                let clock = ContinuousClock()
                let start = clock.now
                bar?.countdown.show(on: recordingScreen, number: ticks)
                for n in stride(from: ticks, through: 1, by: -1) {
                    phase = .countdown(n)
                    bar?.countdown.set(n)
                    let deadline = start.advanced(by: .seconds(ticks - n + 1))
                    guard await hold(until: deadline, clock: clock) else {
                        bar?.countdown.hide()
                        await abandon()
                        return
                    }
                }
                bar?.countdown.hide()
            }
            try await session.start()
            phase = .recording
            let usage = RecordingAppUsage()
            let selectedWindow = kind == .window ? windows.first(where: { $0.id == windowID }) : nil
            usage.start(fixedApp: selectedWindow.map { (id: $0.appID, name: $0.appName) })
            appUsageRecorder = usage
            if showCameraPreview { CameraBubbleController.shared.setVisible(true) }
            poll = Task {
                var nextStatus = ContinuousClock.now
                var lastLevel: Float = -1
                while !Task.isCancelled {
                    let sample = await session.stats()
                    // The meter drives a SwiftUI repaint on the floating
                    // recorder. Publishing every poll kept the main thread
                    // busy enough that clicking Pause or Stop waited behind
                    // the redraw. Only publish a level that actually moved.
                    let level = max(sample.micLevel, sample.systemLevel)
                    if abs(level - lastLevel) > 0.0001 {
                        lastLevel = level
                        recordingMeter.level = level
                    }
                    let now = ContinuousClock.now
                    if now >= nextStatus {
                        stats = sample
                        nextStatus = now.advanced(by: .milliseconds(250))
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
        } catch { fail(error) }
    }

    /// Countdown clock. Absolute deadlines, 50 ms cancellability, no drift.
    /// Returns false when the user cancelled.
    private func hold(until deadline: ContinuousClock.Instant, clock: ContinuousClock) async -> Bool {
        while ContinuousClock.now < deadline {
            if cancelRequested { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// Cancels a start that has not recorded a frame: the prepared engine is
    /// torn down and its empty bundle removed. Called from the bar's Cancel.
    func cancelStart() {
        guard phase == .preparing || isCountingDown else { return }
        cancelRequested = true
        bar?.countdown.hide()
        phase = .preparing
    }

    private var isCountingDown: Bool {
        if case .countdown = phase { return true }
        return false
    }

    private func abandon() async {
        cancelRequested = false
        bar?.countdown.hide()
        await session.abandon()
        paused = false
        phase = .idle
        restoreLibraryAfterFailure()
    }

    func stop() async {
        guard phase == .recording else { return }
        finalizeProgress = 0
        let appUsage = appUsageRecorder?.finish() ?? []
        appUsageRecorder = nil
        phase = .finishing; poll?.cancel()
        // HUD dismisses within 200 ms of the click (spec §3.2): close it now,
        // finalize in the background with "Finishing…" progress in Library.
        livePreviewController?.close(); livePreviewController = nil
        CameraBubbleController.shared.setVisible(false)
        do {
            try await session.stopCapture()
            let b = try await session.finalize { [weak self] value in
                Task { @MainActor [weak self] in self?.finalizeProgress = value }
            }
            do {
                let data = try JSONEncoder().encode(appUsage)
                try data.write(to: b.url.appendingPathComponent("app-usage.json"), options: .atomic)
            } catch {
                self.error = "Recording saved, but app activity could not be saved: \(error.localizedDescription)"
            }
            // Markers recorded during the session become part of the project.
            if !pendingMarkers.isEmpty {
                var file = MarkerFile()
                file.markers = pendingMarkers
                // AGENT: retain markers and surface a failed atomic save.
                try b.saveMarkers(file)
                pendingMarkers = []
            }
            lastProjectURL = b.url
            paused = false
            phase = .idle; refresh()
            let finished = b.url
            let duration = await Task.detached(priority: .userInitiated) {
                (try? ProjectBundle(url: finished).load().meta.source.duration) ?? 0
            }.value
            Task { await EmailNotificationService.shared.recordingFinished(project: finished, duration: duration) }
            // AGENT: finishing an agent recording must not open the editor over the user's work.
            if terminating { hiddenWindows.removeAll() }
            else if agentRecording { agentRecording = false }
            else if let onFinished { onFinished(b.url); hiddenWindows.removeAll() }
            else { restoreLibraryAfterFailure() }
        } catch { fail(error) }
    }

    private func fail(_ e: Error) {
        poll?.cancel(); paused = false
        cancelRequested = false
        _ = appUsageRecorder?.finish(); appUsageRecorder = nil
        bar?.countdown.hide()
        CameraBubbleController.shared.setVisible(false)
        livePreviewController?.close(); livePreviewController = nil
        restoreLibraryAfterFailure()
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
    // AGENT: each shortcut needs its own identity and callback rather than overwriting a shared handler.
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var nextID: UInt32 = 1
    private var ref: EventHotKeyRef?
    private let id: UInt32
    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        id = Self.nextID; Self.nextID += 1; Self.handlers[id] = handler
        if !Self.installed {
            Self.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotkey = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
                if result == noErr, hotkey.signature == OSType(0x4C554D4E) { HotKey.handlers[hotkey.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4C554D4E), id: id), GetApplicationEventTarget(), 0, &ref)
    }
    deinit { if let ref { UnregisterEventHotKey(ref) }; Self.handlers[id] = nil }
}
