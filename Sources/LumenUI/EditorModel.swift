import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import os
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
import LumenExport
import LumenSpeech
import LumenAnalysis

/// Host-clock playback time. Read by the display link on the main thread and by audio start.
final class PlaybackClock: @unchecked Sendable {
    private struct S { var playing = false; var t0 = 0.0; var h0 = 0.0; var dur = 0.0 }
    private let s = OSAllocatedUnfairLock(initialState: S())
    func time(at h: Double) -> Double { s.withLock { $0.playing ? min($0.t0 + max(h - $0.h0, 0), $0.dur) : $0.t0 } }
    func start(from t: Double, at h: Double, dur: Double) { s.withLock { $0 = S(playing: true, t0: t, h0: h, dur: dur) } }
    func pause(at h: Double) { s.withLock { if $0.playing { $0.t0 = min($0.t0 + max(h - $0.h0, 0), $0.dur); $0.playing = false } } }
    func seek(_ t: Double) { s.withLock { $0.t0 = t; $0.h0 = HostClock.now() } }
    // SMOOTHNESS: duration captured at start() goes stale after cuts; update it without re-anchoring t0/h0.
    func setDuration(_ d: Double) { s.withLock { $0.dur = d } }
    var playing: Bool { s.withLock { $0.playing } }
    /// The host instant the current t0 is anchored to. The transport reads it
    /// to prove video and audio were started against the same instant.
    var anchor: Double { s.withLock { $0.h0 } }
    var startedAt: Double { s.withLock { $0.t0 } }
}

/// One owner of transport timing. Video, audio and every late join are placed
/// against the same future host instant, derived from the measured device
/// latency, so the first frame and every later seek land the same way.
enum TransportTiming {
    /// Seconds between "start the clock now" and "the first sample is really
    /// audible": the output latency plus a small scheduling margin.
    static func lead(outputLatency: Double) -> Double { max(0.05, outputLatency + 0.03) }
    /// The host instant audio for output time `t` must be heard at.
    static func startInstant(outputLatency: Double, now: Double = HostClock.now()) -> Double {
        now + lead(outputLatency: outputLatency)
    }
    /// Content that will be on screen at host instant `h` when the clock is
    /// anchored at (t0, h0) and running at 1x.
    static func content(at h: Double, t0: Double, h0: Double) -> Double { t0 + max(h - h0, 0) }
}

/// Atomic snapshot handoff: UI writes whole Timeline values, the render task reads one per frame.
final class TimelineBox: @unchecked Sendable {
    private let s: OSAllocatedUnfairLock<(Timeline, Int)>
    init(_ t: Timeline) { s = OSAllocatedUnfairLock(initialState: (t, 0)) }
    func set(_ t: Timeline) { s.withLock { $0 = (t, $0.1 + 1) } }
    func get() -> (Timeline, Int) { s.withLock { $0 } }
}

/// Serializes replans and keeps the expensive cursor stage between edits.
/// A newer edit cancels the awaiting task, so stale results never overwrite
/// the user's latest change.
actor DerivePipeline {
    private var cache = DeriveCache()
    func derive(_ tl: Timeline, input: DirectorInput, revision: Int) -> Timeline? {
        // A slider can queue dozens of edits while a previous derive is
        // running. Discard cancelled requests before doing any CPU work, and
        // let the running derive notice the cancellation and stop early.
        guard !Task.isCancelled else { return nil }
        let result = Director.deriveCancellable(tl, input: input, revision: revision, cache: &cache,
                                                cancelled: { Task.isCancelled })
        return Task.isCancelled ? nil : result
    }
}

struct LookPreset: Codable, Identifiable, Sendable { var id: String { name }; var name: String; var style: Style; var cursor: CursorStyle; var camera: CameraParams; var audio: AudioPlan }

/// The transient picture of a cut being chosen. Lives only in the editor
/// (view state): it is never written into `Timeline`, never saved and never
/// enters the undo stack. Output times.
struct PendingCut: Equatable {
    enum Edge: Equatable { case start, end }
    var start: Double, end: Double
    var focused: Edge = .end
    var length: Double { max(end - start, 0) }
}

/// What the main lane has selected. One thing at a time.
enum TimelineSelection: Equatable {
    case none
    case clip(UUID)
    case recording(outputStart: Double)
    case seam(UUID)
    case cut(UUID)
}

@MainActor @Observable final class EditorModel {
    enum ExportState: Equatable { case idle, running(Double), done(URL), failed(String) }
    let session: ProjectSession, renderer: Renderer, box: TimelineBox, clock = PlaybackClock()
    /// SMOOTHNESS: the preview's shared state lives on the model, so the
    /// export flag reaches the display-link thread without going through
    /// @Observable (which would invalidate the whole editor).
    let previewShared = PreviewShared()
    private(set) var timeline: Timeline
    var playhead = 0.0
    enum TranscribeState: Equatable { case idle, running(Double), failed(String), notInstalled }
    private(set) var transcript: Transcript?
    private(set) var sentences: [Sentence] = []
    var transcribeState = TranscribeState.idle
    private var transcribeTask: Task<Void, Never>?
    /// True while the clock is running. The strip reads it to choose between
    /// display-rate playhead animation and the exact paused position.
    var isPlaying = false
    /// Latest measured master loudness/peak, for the audio meter.
    var mixStats: (lufs: Double, peak: Double)?
    var selection: UUID?
    /// The main lane's selection (recording strip, imported clip, split seam or
    /// cut seam). Kept separate from `selection` (overlays/zooms/masks).
    var timelineSelection = TimelineSelection.none
    /// The pending cut range, view state only. Committed through `.cutOutputRange`.
    var pendingCut: PendingCut?
    /// Why the last command was refused, shown in the readout line.
    var editIssue: String?
    /// Bumped when something outside the strip asks it to fit the whole take.
    var timelineFitRequest = 0
    var frameRate: Double { max(session.meta.source.fps, 1) }
    var frameDuration: Double { 1 / frameRate }
    var exportState = ExportState.idle {
        didSet { previewShared.exportRunning = if case .running = exportState { true } else { false } }
    }
    var exportSettings: ExportSettings
    var exportSeparateStems = UserDefaults.standard.bool(forKey: "lumen.export.separateWavStems")
    var exportPanelRequest = 0
    var exportPanelActive = false
    var zoomDebug = false
    var exportElapsed = 0.0
    var exportETA: Double?
    var notice: String?
    /// Protect against exporting a video whose automatic redaction analysis
    /// has not yet been applied to the final derived timeline.
    var privacyScanProgress = 0.0
    private var privacyDeadline: Task<Void, Never>?
    var privacyScanning = false
    var privacyScanError: String?
    private var privacyAnalysisComplete = true
    enum PlacementTool: String { case tap = "tap", loupe = "loupe", highlight = "highlight" }
    var placingTool: PlacementTool?
    var focusEditing = false
    var maskEditing = false
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var duration: Double { timeline.compositionDuration }
    private var undoStack: [Timeline] = []
    private var redoStack: [Timeline] = []
    private var lastEdit = Date.distantPast
    private var revision = 1
    private let pipeline = DerivePipeline()
    private var published = -1.0
    private var replanTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var analysisGeneration = 0
    private var transcriptGeneration = 0
    private var pendingInitialAnalysis = false
    private var exportTask: Task<Void, Never>?
    private var activeExportID = UUID()
    private var mixTask: Task<Void, Never>?
    private var masterDelayTask: Task<Void, Never>?
    private var hasMixed = false
    private var isMixing = false
    private var needsInitialMix = true
    private var pendingAudioInvalidation = false
    private var mixGeneration = 0
    private var playbackTask: Task<Void, Never>?
    private var windowTask: Task<Void, Never>?
    private var transportGeneration = 0
    private var wantsPlayback = false
    /// True from the moment Play asks for audio until the clock and the audio
    /// start together. The transport shows it in the readout line; the clock
    /// stays stopped, so a silent start is never presented as success.
    private(set) var preparingPlayback = false
    /// True while the player holds the bounded first window rather than the
    /// full program. The full mix replaces it at the content being heard.
    private var playingProvisional = false
    /// Measured Play→A/V start, for diagnostics. Seconds, or nil when the last
    /// start has not completed.
    private(set) var lastStartLatency: Double?
    /// True when the last start had real audio queued with it. The regression
    /// this lane fixes is the clock running with nothing to play.
    private(set) var audioQueuedAtStart = false
    private let player = PreviewAudioPlayer()
    /// Keeps the wallpaper URL in sync with the active desktop space.
    private var spaceObserver: NSObjectProtocol?

    init(session: ProjectSession, renderer: Renderer, timeline: Timeline,
         exportSettings: ExportSettings, transcript: Transcript?) {
        self.session = session; self.renderer = renderer; self.timeline = timeline; box = TimelineBox(timeline)
        self.exportSettings = exportSettings
        // AGENT: surface a revision race while the file watcher delivers the newer timeline.
        session.setSaveConflictHandler { [weak self] _, actual in
            Task { @MainActor [weak self] in
                self?.notice = "Project updated by an agent. Reloading revision \(actual)."
            }
        }
        // AGENT: edits from the daemon must replace the editor's stale in-memory copy, not merely show a warning.
        session.setProjectChangeHandler { [weak self] file in
            Task { @MainActor [weak self] in self?.acceptExternalProjectFile(file) }
        }
        renderer.setCustomCursors(session.cursors)
        // SMOOTHNESS: a background image that finishes decoding off the
        // render thread must trigger one more frame, otherwise the preview
        // keeps showing the fallback colour until the next edit.
        renderer.setOnAssetReady { [weak self] in
            Task { @MainActor in self?.bumpRenderVersion() }
        }
        // SMOOTHNESS: AppKit is main-thread only, so the wallpaper URL is
        // resolved here and handed to the renderer; the render thread only
        // stats and decodes it.
        renderer.refreshWallpaperURL(Renderer.resolveWallpaperURL())
        spaceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: NSWorkspace.shared, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderer.refreshWallpaperURL(Renderer.resolveWallpaperURL()) }
        }
        setTranscript(transcript)
        // Pre-start the audio engine off the main thread so the first Play
        // click never pays engine startup inside the transport gap.
        let p = player
        Task.detached(priority: .utility) { p.warm() }
        // Age out raw footage in the background. This is pure file-system work
        // and never removes a project file or an exported deliverable.
        let library = session.bundle.url.deletingLastPathComponent()
        Task.detached(priority: .utility) { _ = RawFootageSweep.sweep(library: library) }
    }

    // AGENT: stale undo snapshots must not put a superseded timeline back over an accepted agent edit.
    private func acceptExternalProjectFile(_ file: ProjectFile) {
        let incomingRevision = file.revision ?? session.currentProjectRevision
        guard incomingRevision > session.currentProjectRevision else { return }
        replanTask?.cancel()
        timeline = file.timeline
        box.set(file.timeline)
        undoStack.removeAll()
        redoStack.removeAll()
        selection = nil
        timelineSelection = .none
        pendingCut = nil
        revision += 1
        session.adoptExternalRevision(incomingRevision)
        notice = "Updated by an agent."
        replan(remixAudio: true)
    }

    /// Republish the timeline to the preview. The render version changes, so
    /// the next display-link tick draws the frame again.
    func bumpRenderVersion() { box.set(timeline) }

    static func open(url: URL) async throws -> EditorModel {
        // Everything that touches disk or CPU for a project load happens in
        // the worker: the session, the waveform, the export defaults and the
        // transcript. The main actor only receives the finished values.
        let (r, s, initial, settings, transcript) = try await Task.detached(priority: .userInitiated) {
            let renderer = try Renderer()
            // Minimal open: the persisted project and its frame readers, with
            // the recorded tracks still on disk. The session prepares them in
            // the background, so the window paints instead of waiting for
            // audio decode, VAD, the waveform envelope and the neural pass.
            let (session, timeline) = try await ProjectSession.openEditor(ProjectBundle(url: url), device: renderer.device)
            let settings = ExportSettings.load(defaultName: AppModel.displayName(session.meta.name))
            let transcript = session.transcriptFile?.transcript.shifted(by: session.micOffset)
            return (renderer, session, timeline, settings, transcript)
        }.value
        // Open the editor from persisted intent immediately. Cursor/camera
        // derivation is CPU-heavy and must not block the Studio window.
        let model = EditorModel(session: s, renderer: r, timeline: initial,
                                exportSettings: settings, transcript: transcript)
        // Editor must open fast: OCR/face/mask analysis used to start here,
        // competing with derive+mix for CPU and making open feel hung.
        // Defer it until the first derive has published (see replan), so the
        // window paints with persisted zooms first. Export stays gated by
        // privacyScanning until the deferred scan finishes.
        model.pendingInitialAnalysis = true
        let scansPrivacy = initial.overlays.privacy.enabled && initial.overlays.privacy.autoDetect
        model.privacyScanning = scansPrivacy
        model.privacyAnalysisComplete = !scansPrivacy
        model.replan(remixAudio: true)
        // Auto-transcribe was also started here (Moonshine over the whole
        // mic file = tens of seconds at open). It now runs after analysis
        // finishes (see analyzeInBackground), still in the background.
        return model
    }

    // MARK: Edits (value-type timeline: undo is a stack of snapshots)

    func edit(coalesce: Bool = false, _ body: (inout Timeline) -> Void) {
        let old = timeline
        var new = old; body(&new)
        new.audio = new.audio.studioPolicy()
        guard new != old else { return }
        if !(coalesce && Date().timeIntervalSince(lastEdit) < 0.6) { undoStack.append(old); if undoStack.count > 100 { undoStack.removeFirst() } }
        lastEdit = Date(); redoStack.removeAll()
        timeline = new; box.set(new)                                    // renderer shows the new look immediately, old derived tracks
        // A visual-only edit can arrive during an expensive derive. That
        // worker owns an older complete timeline, not just derived tracks.
        // Restart against the new snapshot instead of losing the user's edit.
        let derivePending = replanTask != nil
        let analysisChanged = old.overlays.privacy != new.overlays.privacy || old.captions.enabled != new.captions.enabled
            || old.captions.locale != new.captions.locale || old.captions.vocabulary != new.captions.vocabulary
            || old.layouts != new.layouts
            || old.webcam?.backdrop != new.webcam?.backdrop
            || ((!old.camera.autoZoom || old.camera.preset == .fixed)
                && new.camera.autoZoom && new.camera.preset != .fixed)
        if analysisChanged { analyzeInBackground(new) }
        if derivePending || old.overlays.privacy != new.overlays.privacy || old.cursor != new.cursor || old.camera != new.camera || old.zoom != new.zoom || old.timeMap != new.timeMap
            || old.audio != new.audio || old.webcam != new.webcam || old.overlays.taps != new.overlays.taps
            || old.clips != new.clips || old.cropSettings != new.cropSettings || old.smartCrop != new.smartCrop || old.activity != new.activity
            || old.layouts != new.layouts || old.layoutSettings != new.layoutSettings
            || old.captions != new.captions
            || old.style.aspectRatio != new.style.aspectRatio || old.style.padding != new.style.padding
            || old.style.paddingInsets != new.style.paddingInsets {
            replan(remixAudio: old.audio != new.audio || old.timeMap != new.timeMap || old.clips != new.clips, debounce: coalesce)
        } else { session.save(new) }
    }

    private func analyzeInBackground(_ snapshot: Timeline) {
        analysisTask?.cancel()
        analysisGeneration += 1
        let generation = analysisGeneration
        privacyDeadline?.cancel()
        privacyScanProgress = 0
        let scansPrivacy = snapshot.overlays.privacy.enabled && snapshot.overlays.privacy.autoDetect
        privacyScanning = scansPrivacy
        privacyAnalysisComplete = !scansPrivacy
        privacyScanError = nil
        let session = session
        if scansPrivacy {
            privacyDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(190, session.meta.source.duration * 2 + 10))) } catch { return }
                guard let self else { return }
                self.analysisTask?.cancel()
                self.privacyAnalysisComplete = true
                self.privacyScanning = false
                self.privacyScanError = "Scanning timed out. Change detection settings to retry, or use manual masks."
            }
        }
        analysisTask = Task { [weak self] in
            let result = await session.analyze(snapshot, privacyProgress: { [weak self] value in
                Task { @MainActor [weak self] in
                    guard let self, self.analysisGeneration == generation else { return }
                    self.privacyScanProgress = value
                }
            }, onTyping: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.analysisGeneration == generation else { return }
                    self.replan()
                }
            }, onActivity: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.analysisGeneration == generation else { return }
                    self.replan()
                }
            }, onPrivacy: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.analysisGeneration == generation else { return }
                    self.finishPrivacy(error: error)
                }
            })
            guard !Task.isCancelled, let self, self.analysisGeneration == generation else { return }
            _ = result
            self.replan()
            self.autoTranscribeIfNeeded()
        }
    }
    private func finishPrivacy(error: String?) {
        privacyDeadline?.cancel()
        privacyScanError = error
        privacyAnalysisComplete = true
        privacyDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.privacyScanning else { return }
            self.privacyScanning = false
            self.privacyScanError = self.privacyScanError ?? "Applying masks timed out. Retry scanning or review manual masks."
        }
        replan()
    }

    func setWebcam(_ on: Bool) { edit { $0.webcam = on ? ($0.webcam ?? WebcamLayout()) : nil } }
    func undo() { if let p = undoStack.popLast() { redoStack.append(timeline); restore(p) } }
    func redo() { if let n = redoStack.popLast() { undoStack.append(timeline); restore(n) } }
    private func restore(_ t: Timeline) { replanTask?.cancel(); timeline = t; box.set(t); session.save(t); replan(remixAudio: true) }

    func bind<V>(_ kp: WritableKeyPath<Timeline, V>) -> Binding<V> {
        Binding(get: { self.timeline[keyPath: kp] }, set: { v in self.edit(coalesce: true) { $0[keyPath: kp] = v } })
    }

    /// No artificial debounce: a yield coalesces a burst of slider events and
    /// the actor pipeline keeps the cursor stage warm. A newer edit cancels the
    /// awaiting task before it can publish a stale timeline.
    private func replan(remixAudio: Bool = false, debounce: Bool = false) {
        replanTask?.cancel()
        pendingAudioInvalidation = pendingAudioInvalidation || remixAudio
        let snap = timeline, s = session, pl = pipeline; revision += 1; let rev = revision
        replanTask = Task { [weak self] in
            defer { if let self, self.revision == rev { self.replanTask = nil } }
            if debounce { try? await Task.sleep(for: .milliseconds(60)) }
            else { await Task.yield() }
            guard !Task.isCancelled else { return }
            guard let out = await pl.derive(snap, input: s.input, revision: rev),
                  !Task.isCancelled, let self, self.revision == rev else { return }
            // Visual-only changes must never restart a full-recording audio mix.
            let audioChanged = remixAudio || self.pendingAudioInvalidation || snap.audio != out.audio || snap.timeMap != out.timeMap
                || snap.clips != out.clips || snap.derived?.cues != out.derived?.cues
                || snap.derived?.duck != out.derived?.duck
            self.pendingAudioInvalidation = false
            self.timeline = out; self.box.set(out); s.save(out)
            if self.pendingInitialAnalysis {
                self.pendingInitialAnalysis = false
                self.analyzeInBackground(out)
            }
            if audioChanged, !self.needsInitialMix { self.invalidateAudio(); self.scheduleIdleMaster() }
            // Warm the preview buffer after derive publishes so a typical
            // Play (seconds after open) has sound instantly. The mix runs
            // off-main and never blocks open; an eager Play already owns
            // its mix, so this only fires when transport is idle.
            if self.needsInitialMix {
                self.needsInitialMix = false
                if !self.hasMixed, !self.isMixing, !self.wantsPlayback {
                    self.prepareFirstWindow()
                    self.scheduleIdleMaster()
                }
            }
            // SMOOTHNESS: `playhead` is a 12 Hz echo, up to ~83 ms behind the real clock.
            // Re-anchoring from it while playing rewinds video but not audio (A/V jump).
            if self.clock.playing {
                // The clock is the truth while playing. Never re-anchor it from the 12 Hz echo.
                self.clock.setDuration(out.compositionDuration)
                if self.clock.time(at: HostClock.now()) >= out.compositionDuration - 0.001 { self.pause() }
            } else {
                let t = min(self.playhead, out.compositionDuration)
                self.playhead = t; self.published = t
                self.clock.seek(t)
            }
            if self.privacyAnalysisComplete { self.privacyScanning = false; self.privacyDeadline?.cancel() }
        }
    }

    // MARK: Audio preparation and transport

    private func invalidateAudio() {
        let resume = wantsPlayback
        let t = clock.playing ? clock.time(at: HostClock.now()) : playhead
        cancelWindowRequests()
        player.stop(); player.load(nil)
        clock.pause(at: HostClock.now()); clock.seek(t)
        playhead = t; published = t
        yieldMasterToTransport()
        hasMixed = false; isPlaying = false
        if resume { startWhenAudioReady(t) }
    }

    /// Whole-program mastering is admitted while transport is idle.
    private func scheduleIdleMaster() {
        masterDelayTask?.cancel()
        guard !wantsPlayback, !hasMixed else { return }
        masterDelayTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self, !self.wantsPlayback, !self.hasMixed, !self.isMixing else { return }
            self.remix()
        }
    }

    private func yieldMasterToTransport() {
        masterDelayTask?.cancel(); masterDelayTask = nil
        // Keep the previous task as a cancellation barrier for the next master.
        if isMixing { mixGeneration += 1; mixTask?.cancel(); isMixing = false }
    }

    /// Mastering is independent from transport. Cancel obsolete work and
    /// never publish a mix belonging to a different edit generation.
    private func remix() {
        mixGeneration += 1
        let gen = mixGeneration, previous = mixTask
        previous?.cancel()
        let tl = timeline, mixer = session.mixer
        isMixing = true
        mixTask = Task { [weak self] in
            defer { if let self, self.mixGeneration == gen { self.isMixing = false } }
            await previous?.value
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { mixer.mix(tl, cancelled: { Task.isCancelled }) }
            let audio = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.mixGeneration == gen else { return }
            let cur = self.timeline
            guard tl.audio == cur.audio, tl.timeMap == cur.timeMap, tl.clips == cur.clips,
                  tl.derived?.cues == cur.derived?.cues, tl.derived?.duck == cur.derived?.duck else {
                self.remix(); return
            }
            self.isMixing = false
            guard let audio else { return }
            self.hasMixed = true
            self.mixStats = (audio.lufs, audio.truePeakDb)
            self.windowTask?.cancel(); self.windowTask = nil
            self.player.load(audio)
            // Continue the queue without resetting the clock or replaying
            // the samples already scheduled by a provisional window.
            if self.clock.playing, self.player.queuedThrough - self.clock.time(at: HostClock.now()) < 1.75 {
                _ = self.player.refill()
            }
            self.playingProvisional = false
        }
    }

    private func cancelWindowRequests() {
        transportGeneration += 1
        playbackTask?.cancel(); playbackTask = nil
        windowTask?.cancel(); windowTask = nil
        preparingPlayback = false
    }

    func seek(_ t: Double) {
        guard t.isFinite else { return }
        cancelWindowRequests()
        let c = min(max(t, 0), duration)
        clock.pause(at: HostClock.now()); player.stop(); clock.seek(c)
        playhead = c; published = c; isPlaying = false
        if wantsPlayback {
            if audioReady(at: c) { startPlayback(c) }
            else { startWhenAudioReady(c) }
        }
    }

    func play() {
        if clock.playing || preparingPlayback { return }
        wantsPlayback = true
        yieldMasterToTransport()
        cancelWindowRequests()
        let t = playhead >= duration - 0.02 ? 0 : playhead
        if audioReady(at: t) { startPlayback(t) }
        else { startWhenAudioReady(t) }
    }

    func pause() {
        wantsPlayback = false
        cancelWindowRequests()
        clock.pause(at: HostClock.now()); player.stop()
        playhead = clock.time(at: HostClock.now()); published = playhead
        isPlaying = false
        if editIssue == "Preparing audio…" { editIssue = nil }
        scheduleIdleMaster()
    }
    func togglePlay() { wantsPlayback ? pause() : play() }

    private func prepareFirstWindow() {
        let tl = timeline, mixer = session.mixer, gen = transportGeneration
        guard mixer.hasProgram(tl) else { return }
        windowTask?.cancel()
        windowTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { mixer.previewWindow(tl, at: 0, cancelled: { Task.isCancelled }) }
            let window = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.transportGeneration == gen else { return }
            self.windowTask = nil
            guard let window, !self.hasMixed, !self.wantsPlayback else { return }
            self.player.loadWindow(window)
        }
    }

    private func audioReady(at t: Double) -> Bool {
        !session.mixer.hasProgram(timeline) || player.contains(t)
    }

    private func startPlayback(_ t: Double) {
        let requested = HostClock.now(), hasAudio = session.mixer.hasProgram(timeline)
        if hasAudio { player.warm() }
        let target = TransportTiming.startInstant(outputLatency: player.outputLatency)
        let audible = hasAudio ? player.play(from: t, atHostSeconds: target) : target
        guard !hasAudio || player.hasQueuedAudio else {
            wantsPlayback = false; preparingPlayback = false; isPlaying = false
            editIssue = "Audio output is unavailable."
            return
        }
        clock.start(from: t, at: audible, dur: duration)
        playingProvisional = hasAudio && !hasMixed
        audioQueuedAtStart = hasAudio && player.hasQueuedAudio
        isPlaying = true; preparingPlayback = false
        if editIssue == "Preparing audio…" { editIssue = nil }
        lastStartLatency = max(audible - requested, 0)
        // Bounded preview windows own playback; mastering resumes when idle.
    }

    /// Every seek gets its own bounded window. There is no polling for an
    /// entire recording to finish denoising or mastering.
    private func startWhenAudioReady(_ t: Double) {
        wantsPlayback = true; preparingPlayback = true; isPlaying = false
        editIssue = "Preparing audio…"
        let started = HostClock.now(), gen = transportGeneration
        let tl = timeline, mixer = session.mixer
        playbackTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { mixer.previewWindow(tl, at: t, cancelled: { Task.isCancelled }) }
            let window = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.transportGeneration == gen, self.wantsPlayback else { return }
            if !self.hasMixed, let window { self.player.loadWindow(window) }
            guard self.audioReady(at: t) else {
                self.wantsPlayback = false; self.preparingPlayback = false
                self.editIssue = "Audio is unavailable, so playback cannot start."; return
            }
            self.startPlayback(t)
            self.lastStartLatency = max(HostClock.now() - started, self.lastStartLatency ?? 0)
        }
        // Do not launch a full-program mix while the first window is pending.
    }

    private func prepareNextWindow(at t: Double) {
        guard windowTask == nil, player.queuedThrough < duration - 0.001 else { return }
        let from = player.queuedThrough
        guard from - t < 1.75 else { return }
        if hasMixed { _ = player.refill(); return }
        let tl = timeline, mixer = session.mixer, gen = transportGeneration
        windowTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { mixer.previewWindow(tl, at: from, cancelled: { Task.isCancelled }) }
            let window = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.transportGeneration == gen else { return }
            self.windowTask = nil
            guard self.wantsPlayback, self.clock.playing else { return }
            if self.hasMixed { _ = self.player.refill() }
            else if let window { _ = self.player.appendWindow(window) }
        }
    }

    func tick(_ t: Double) {
        if abs(t - published) >= 1.0 / 12 { playhead = t; published = t }
        guard clock.playing else { return }
        if t >= duration - 0.001 { pause(); return }
        if session.mixer.hasProgram(timeline) {
            prepareNextWindow(at: t)
            // An underrun buffers at the exact media position, never runs
            // the video clock silently ahead of the queued audio.
            if player.hasQueuedAudio, t >= player.queuedThrough - 0.025 {
                seek(min(t, duration))
            }
        }
    }

    func setTranscript(_ t: Transcript?) {
        // A transcript arriving never switches captions on. The toggle is the
        // only writer; this used to force `enabled = true` and that is why the
        // switch kept turning itself back on.
        transcript = t
        transcriptGeneration += 1
        let generation = transcriptGeneration
        guard let t else { sentences = []; return }
        // Splitting a transcript into sentences is O(words): it never runs on
        // the main actor, and a newer transcript always wins the race.
        let words = t.words
        Task.detached(priority: .userInitiated) {
            let split = Sentences.split(words)
            await MainActor.run {
                guard self.transcriptGeneration == generation else { return }
                self.sentences = split
            }
        }
    }
    func seekSource(_ s: Double) { seek(timeline.timeMap.output(atSource: s)) }

    func transcribe() {
        guard session.meta.mic != nil else { return }
        guard MoonshineRuntime.isAvailable, ModelStore.isInstalled(.current) else {
            transcribeState = .notInstalled
            return
        }
        let b = session.bundle, off = session.micOffset, size = MoonshineSize.current
        let audioSettings = timeline.audio
        transcribeState = .running(0); transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            let voiceURL: URL
            do { voiceURL = try await cleanVoiceURL(for: b, settings: audioSettings) }
            catch {
                guard !Task.isCancelled else { return }
                self?.transcribeState = .failed("Voice processing failed: \(error.localizedDescription)")
                return
            }
            let res = await FileTranscriber.run(url: voiceURL, size: size) { p in Task { @MainActor in self?.transcribeState = .running(p) } }
            guard let self, !Task.isCancelled else { return }
            switch res {
            case .success(let tr):
                try? b.saveTranscript(TranscriptFile(engine: "moonshine-streaming-\(size.rawValue)", complete: true, transcript: tr))
                let aligned = tr.shifted(by: off)
                self.setTranscript(aligned)
                self.session.updateTranscript(aligned)
                self.replan()
                self.transcribeState = .idle
            case .failure(let e): self.transcribeState = .failed(e.description)
            }
        }
    }

    func cancelTranscribe() { transcribeTask?.cancel(); transcribeState = .idle }

    /// A live take that dropped audio (or never ran) gets re-transcribed from the file, automatically.
    func autoTranscribeIfNeeded() {
        guard session.meta.mic != nil, session.transcriptFile?.complete != true,
              MoonshineRuntime.isAvailable, ModelStore.isInstalled(.current) else { return }
        transcribe()
    }

    // MARK: Preview placement

    /// Tools place source-pixel targets with a click in the actual recording.
    /// Never substitute (0, 0) when input monitoring failed.
    func placeSelectedTool(at point: SIMD2<Double>) {
        guard let tool = placingTool, timeline.clip(atOutput: playhead) == nil else { return }
        let source = session.meta.source
        let width = Double(source.width), height = Double(source.height)
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x <= width, point.y <= height else { return }
        placingTool = nil
        let start = timeline.timeMap.source(atOutput: playhead)
        let end = min(start + 3, timeline.timeMap.trimEnd)
        switch tool {
        case .tap:
            dispatch(.addTapAtPlayhead(x: point.x, y: point.y))
        case .highlight:
            guard end > start else { return }
            let w = width * 0.3, h = height * 0.16
            let highlight = Highlight(start: start, end: end,
                                      x: max(0, min(point.x - w / 2, width - w)),
                                      y: max(0, min(point.y - h / 2, height - h)),
                                      w: w, h: h, style: .dim)
            dispatch(.addHighlight(highlight))
            selection = highlight.id
        case .loupe:
            guard end > start else { return }
            let loupe = Loupe(start: start, end: end, x: point.x, y: point.y,
                              follow: false, cx: point.x / width, cy: point.y / height)
            dispatch(.addLoupe(loupe))
            selection = loupe.id
        }
    }

    // MARK: Zoom segments

    /// A manual region is stored in SOURCE pixels and SOURCE time.
    /// Its default lifetime runs from the current playhead to the recording
    /// end, not a static canvas position; auto zoom never exposes it.
    func addManualMask(sourceRect rect: CGRect) {
        guard let derived = timeline.derived, rect.width >= 4, rect.height >= 4 else { return }
        let sourceTime = timeline.timeMap.source(atOutput: playhead)
        let endTime = timeline.timeMap.trimEnd
        guard sourceTime + 0.01 < endTime else { return }
        let width = derived.sourceSize.x, height = derived.sourceSize.y
        let left = min(max(Double(rect.minX), 0), width)
        let top = min(max(Double(rect.minY), 0), height)
        let right = min(max(Double(rect.maxX), 0), width)
        let bottom = min(max(Double(rect.maxY), 0), height)
        guard right - left >= 4, bottom - top >= 4 else { return }
        let mask = Mask(start: sourceTime, end: endTime,
                        mode: timeline.overlays.privacy.mode,
                        keys: [MaskKey(t: sourceTime, x: left, y: top,
                                       w: right - left, h: bottom - top)],
                        origin: .manual, approved: true, padding: 0)
        edit { $0.overlays.masks.append(mask) }
    }

    /// Add a manual text/title overlay without modifying the original recording.
    /// The same source-time object is used in Metal preview and offline export.
    func addManualTitle() {
        let start = timeline.timeMap.source(atOutput: playhead)
        let end = min(start + 3, timeline.timeMap.trimEnd)
        guard end > start else { return }
        let title = TextBlock(start: start, end: end, text: "Title")
        dispatch(.addText(title))
        selection = title.id
    }

    /// Arm placement so the highlight lands where the user clicks in the preview.
    func addManualHighlight() {
        placingTool = .highlight
    }

    func addZoom() {
        let s = playhead, e = min(s + 2.5, duration)
        guard e - s > 0.3 else { return }
        let tm = timeline.timeMap
        let z = ZoomSegment(start: tm.source(atOutput: s), end: tm.source(atOutput: e), scale: 2, focus: .follow, origin: .manual)
        edit { $0.zoom.append(z) }; selection = z.id
    }

    /// Blade: creates a pending range at the playhead. Press Cut again or
    /// Backspace to commit, Esc to discard. The pending range is view state
    /// only — never saved, never on the undo stack.
    func cutAtPlayhead() {
        if pendingCut != nil { commitPendingCut(); return }
        let dur = timeline.timeMap.outputDuration
        guard playhead < dur - 0.05 else { editIssue = "Move the playhead before the end to cut here."; return }
        let e = min(playhead + 1.0, dur)
        guard e - playhead >= frameDuration else { editIssue = "A cut must keep at least one frame."; return }
        pendingCut = PendingCut(start: playhead, end: e)
        editIssue = nil
    }

    /// Pending range helpers. All times OUTPUT seconds. Min one frame.
    var pendingLength: Double { pendingCut?.length ?? 0 }
    var pendingWouldRemoveEverything: Bool {
        guard let p = pendingCut else { return false }
        return timeline.timeMap.outputDuration - p.length < frameDuration
    }
    func setPendingStart(_ t: Double) {
        guard var p = pendingCut else { return }
        p.start = min(max(t, 0), p.end - frameDuration)
        p.focused = .start; pendingCut = p
    }
    func setPendingEnd(_ t: Double) {
        guard var p = pendingCut else { return }
        p.end = min(max(t, p.start + frameDuration), timeline.timeMap.outputDuration)
        p.focused = .end; pendingCut = p
    }
    func movePending(by dt: Double) {
        guard var p = pendingCut else { return }
        let dur = timeline.timeMap.outputDuration
        let len = p.length
        let s = min(max(p.start + dt, 0), max(dur - len, 0))
        p.start = s; p.end = s + len
        pendingCut = p
    }
    func nudgePendingHandle(_ edge: PendingCut.Edge, _ dt: Double) {
        if edge == .start { setPendingStart((pendingCut?.start ?? 0) + dt) }
        else { setPendingEnd((pendingCut?.end ?? 0) + dt) }
    }
    func setRangeIn() {
        if pendingCut == nil { pendingCut = PendingCut(start: playhead, end: min(playhead + 1, timeline.timeMap.outputDuration)) }
        else { setPendingStart(playhead) }
    }
    func setRangeOut() {
        if pendingCut == nil { pendingCut = PendingCut(start: max(playhead - 1, 0), end: playhead) }
        else { setPendingEnd(playhead) }
    }
    func commitPendingCut() {
        guard let p = pendingCut else { return }
        guard !pendingWouldRemoveEverything else { editIssue = "That range would remove the whole recording."; return }
        guard p.length >= frameDuration else { editIssue = "A cut must keep at least one frame."; return }
        pendingCut = nil
        dispatch(.cutOutputRange(start: p.start, end: p.end))
        // Playhead sits on the seam after a commit.
        seek(p.start)
    }
    func discardPendingCut() { pendingCut = nil; editIssue = nil }

    // MARK: Magnetic lane actions (playhead-captured)

    /// Final Cut blade: split the clip under the playhead. Playhead is the
    /// only time source; no pointer or last-click state is consulted.
    func splitAtPlayhead() {
        let ph = playhead
        guard ph > 0.05, ph < timeline.compositionDuration - 0.05 else { return }
        dispatch(.splitClip(atOutput: ph))
    }

    func rippleDeleteSelected() {
        guard let id = selection,
              timeline.clips.contains(where: { $0.id == id }) else { return }
        dispatch(.rippleDeleteClip(id: id))
        selection = nil
    }

    func duplicateSelected() {
        guard let id = selection else { return }
        dispatch(.duplicateClip(id: id))
    }

    func joinSelectedClips() {
        guard let id = selection else { return }
        // join with the next clip if adjacent
        let sorted = timeline.clips.sorted { $0.start < $1.start }
        guard let idx = sorted.firstIndex(where: { $0.id == id }), idx + 1 < sorted.count else { return }
        dispatch(.joinClips(ids: [id, sorted[idx + 1].id]))
    }

    /// System clipboard bridge for Final Cut cmd-C/V paste a single clip.
    /// Writes a custom UTI with JSON so another Lumen window (and external
    /// paste reads) can reconstruct the clip; falls back to the path string.
    static let clipPasteboardType = NSPasteboard.PasteboardType("com.lumen.clip")
    func copySelectedClip() {
        guard let id = selection,
              let clip = timeline.clips.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clip.path, forType: .string)
        if let data = try? JSONEncoder().encode(clip) {
            let item = NSPasteboardItem()
            item.setString(clip.path, forType: .string)
            item.setData(data, forType: Self.clipPasteboardType)
            NSPasteboard.general.writeObjects([item])
        }
        copiedClip = clip
    }

    var copiedClip: TimelineClip?

    /// Paste inserts at the playhead with ripple. Playhead is captured at
    /// dispatch via ReduceContext; never read from the last pointer position.
    func pasteClipAtPlayhead() {
        if copiedClip == nil,
           let data = NSPasteboard.general.data(forType: Self.clipPasteboardType),
           let clip = try? JSONDecoder().decode(TimelineClip.self, from: data) {
            copiedClip = clip
        }
        guard let clip = copiedClip else { return }
        let ph = playhead
        dispatch(.pasteClip(clip: clip, atOutput: ph))
    }

    var snapEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "lumen.timeline.snapEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "lumen.timeline.snapEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "lumen.timeline.snapEnabled") }
    }

    /// Cut to clipboard: copy plus ripple delete, one gesture.
    func cutSelectedClip() {
        guard let id = selection,
              timeline.clips.contains(where: { $0.id == id }) else { return }
        copySelectedClip()
        dispatch(.rippleDeleteClip(id: id))
        selection = nil
    }

    /// Split the recording at the playhead (logical seam, no output change).
    func splitRecordingAtPlayhead() {
        let ph = playhead
        guard ph > 0.05, ph < timeline.timeMap.outputDuration - 0.05 else { return }
        dispatch(.splitRecording(atOutput: ph))
    }

    func trimClipEdge(id: UUID, isStart: Bool, toOutput: Double) {
        let ctx = ReduceContext(playhead: playhead, selection: id, duration: duration, fps: frameRate)
        var draft = timeline
        do {
            _ = try reduce(&draft, .trimClipEdge(id: id, isStart: isStart, toOutput: toOutput), ctx: ctx)
        } catch let CommandError.invalid(msg) { editIssue = msg; return }
          catch { editIssue = "That trim could not be applied."; return }
        edit(coalesce: true) { $0 = draft }
        editIssue = nil
    }

    func moveCutEdge(id: UUID, isStart: Bool, toOutput: Double) {
        let ctx = ReduceContext(playhead: playhead, selection: id, duration: duration, fps: frameRate)
        var draft = timeline
        do {
            _ = try reduce(&draft, .setCutEdge(id: id, isStart: isStart, toOutput: toOutput), ctx: ctx)
        } catch let CommandError.invalid(msg) { editIssue = msg; return }
          catch { editIssue = "That cut edge could not be moved."; return }
        edit(coalesce: true) { $0 = draft }
        editIssue = nil
    }

    func moveSeam(id: UUID, toOutput: Double) {
        let ctx = ReduceContext(playhead: playhead, selection: id, duration: duration, fps: frameRate)
        var draft = timeline
        do {
            _ = try reduce(&draft, .moveSeam(id: id, toOutput: toOutput), ctx: ctx)
        } catch let CommandError.invalid(msg) { editIssue = msg; return }
          catch { editIssue = "That seam could not be moved."; return }
        edit(coalesce: true) { $0 = draft }
        editIssue = nil
    }

    /// Arm manual click placement at the current playhead time.
    func addTapAtPlayhead() {
        placingTool = .tap
    }

    /// Drag a manual tap: coalesced so one gesture is one undo snapshot.
    func moveTap(id: UUID, x: Double, y: Double, atSource: Double?) {
        let ctx = ReduceContext(playhead: playhead, selection: id, duration: duration)
        edit(coalesce: true) { tl in _ = try? reduce(&tl, .moveTap(tap: id, x: x, y: y, atSource: atSource), ctx: ctx) }
    }

    /// Arm a glass loupe for placement on a visible source detail.
    func addLoupe() {
        placingTool = .loupe
    }

    func updateLoupe(_ loupe: Loupe) { dispatch(.updateLoupe(loupe)) }

    /// Imported movies are appended after the recording and addressed in OUTPUT
    /// seconds. Their pixel size is probed once so the Director never has to
    /// guess an aspect ratio at render time.
    func importClips() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        picker.allowsMultipleSelection = true
        picker.prompt = "Import video"
        guard picker.runModal() == .OK else { return }
        let urls = picker.urls
        Task { [weak self] in
            for url in urls {
                let asset = AVURLAsset(url: url)
                guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                      let duration = try? await asset.load(.duration).seconds, duration > 0.1 else { continue }
                let size = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
                guard let self else { return }
                let start = self.timeline.compositionDuration
                let clip = TimelineClip(path: url.path, name: url.deletingPathExtension().lastPathComponent,
                                        duration: duration, start: start,
                                        width: Int(size.width.rounded()), height: Int(size.height.rounded()))
                self.dispatch(.addClip(clip))
            }
        }
    }

    var transcriptWords: [WordToken] { session.input.transcript?.words ?? [] }

    func editTranscriptWord(_ index: Int, _ text: String) { dispatch(.editWord(index: index, text: text)) }

    /// Deleting a transcript word removes the matching VIDEO span too, via a
    /// `.transcript` cut. The word itself stays in the project so it can be
    /// restored; deletion is a mask over both captions and picture, never data loss.
    func setTranscriptWord(_ index: Int, deleted: Bool) {
        let spans = TranscriptEdits.spans(for: transcriptWords, at: [index])
        dispatch(deleted
                 ? .deleteTranscriptWords([index], cuts: spans)
                 : .restoreTranscriptWords([index], cuts: spans))
    }

    /// Delete a whole sentence by its word range. One cut, one undo step.
    func deleteSentence(words range: Range<Int>) {
        let indices = Array(range).filter { transcriptWords.indices.contains($0) }
        guard let cut = TranscriptEdits.sentenceSpan(for: transcriptWords, range: range) else { return }
        dispatch(.deleteTranscriptWords(indices, cuts: [cut]))
    }

    /// Bulk cleanup: filler words and long pauses go in one pass, and each one
    /// removes its picture span as well as its caption. A pause with a click or
    /// key press inside it is kept — that is deliberate interaction, not dead air.
    func removeFillerWords() {
        let transcript = Transcript(words: transcriptWords, locale: timeline.captions.locale)
        let terms = TranscriptEdits.terms(forLocale: transcript.locale)
        let indices = transcriptWords.enumerated().compactMap { index, word in
            terms.contains(TranscriptEdits.normalized(word.text)) ? index : nil
        }
        let cuts = TranscriptEdits.cleanupCuts(transcript: transcript, events: session.input.events)
        guard !indices.isEmpty || !cuts.isEmpty else { return }
        dispatch(.deleteTranscriptWords(indices, cuts: cuts))
    }
    func dispatch(_ c: Command) {
        let ctx = ReduceContext(playhead: playhead, selection: selection, duration: duration, fps: frameRate)
        var draft = timeline
        do {
            _ = try reduce(&draft, c, ctx: ctx)
        } catch let CommandError.invalid(msg) { editIssue = msg; return }
          catch { editIssue = "That edit could not be applied."; return }
        edit { $0 = draft }
        editIssue = nil
    }
    func deleteSelected() {
        guard let id = selection else { return }
        if timeline.zoom.contains(where: { $0.id == id }) { dispatch(.deleteZoom(id)) }
        else if timeline.overlays.texts.contains(where: { $0.id == id }) { dispatch(.deleteText(id)) }
        else if timeline.overlays.highlights.contains(where: { $0.id == id }) { dispatch(.deleteHighlight(id)) }
        else if timeline.overlays.loupes.contains(where: { $0.id == id }) { dispatch(.deleteLoupe(id)) }
        else if timeline.clips.contains(where: { $0.id == id }) { dispatch(.rippleDeleteClip(id: id)) }
        else if timeline.audio.lanes.contains(where: { $0.id == id && $0.role == .music }) { dispatch(.deleteAudioLane(id)) }
        else { return }
        selection = nil
    }
    func setFocus(box b: CGRect) {       // normalized source coords
        guard let id = selection, b.width > 0.02, b.height > 0.02 else { return }
        let width = Double(b.width), height = Double(b.height)
        let bounds = Focus.element(x: Double(b.minX), y: Double(b.minY), w: width, h: height)
        let widthFit = 1.0 / (width + 0.24)
        let heightFit = 1.0 / (height + 0.24)
        let targetScale = min(max((0.8 * min(widthFit, heightFit) * 10).rounded() / 10, 1.1), 4.0)
        edit { tl in
            guard let i = tl.zoom.firstIndex(where: { $0.id == id }) else { return }
            tl.zoom[i].focus = bounds
            tl.zoom[i].scale = targetScale
            tl.zoom[i].origin = .manual
        }
    }

    // MARK: Looks, music, export

    private nonisolated static var presetsDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumen/Presets")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    nonisolated static func loadPresets() -> [LookPreset] {
        ((try? FileManager.default.contentsOfDirectory(at: presetsDir, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? JSONDecoder().decode(LookPreset.self, from: Data(contentsOf: $0)) }.sorted { $0.name < $1.name }
    }
    /// The same list, read on a worker: the presets live on disk, and the
    /// inspector asks for them the moment the editor window appears.
    static func loadPresetsOffMain() async -> [LookPreset] {
        await Task.detached(priority: .userInitiated) { loadPresets() }.value
    }
    func savePreset(_ name: String) {
        let p = LookPreset(name: name, style: timeline.style, cursor: timeline.cursor, camera: timeline.camera, audio: timeline.audio)
        try? JSONEncoder().encode(p).write(to: Self.presetsDir.appendingPathComponent("\(name).json"))
    }
    func apply(_ p: LookPreset) { edit { $0.style = p.style; $0.cursor = p.cursor; $0.camera = p.camera; $0.audio = p.audio } }

    /// Auditions the selected click at the current click level without
    /// touching timeline playback.
    func previewClick() {
        var plan = timeline.audio
        plan.soundEffectsEnabled = true; plan.clickSounds = true
        player.previewClick(plan)
    }

    /// Clicking a sound tile both selects that click and auditions it, so the
    /// grid never needs a separate preview button or a dropdown.
    func chooseClick(_ sound: ClickSound) {
        edit { $0.audio.clickTone = sound; $0.audio.clickSounds = true; $0.audio.soundEffectsEnabled = true }
        var plan = timeline.audio
        plan.soundEffectsEnabled = true; plan.clickSounds = true
        player.previewClick(plan)
    }

    func importMusic() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { edit { $0.audio.musicPath = u.path } }
    }

    /// Adds a music track as a lane at the playhead so it appears on the music
    /// timeline lane. `nil` gain uses a bed level under the voice.
    func addMusicLane(path: String, at start: Double? = nil) {
        let place = max(0, start ?? playhead)
        var lane = AudioLane(role: .music, path: path, placement: place, gainDb: -18)
        lane.loops = false
        dispatch(.addAudioLane(lane))
    }

    func updateMusicLane(_ id: UUID, placement: Double? = nil, trimStart: Double? = nil, trimDuration: Double? = nil) {
        var draft = timeline
        let context = ReduceContext(playhead: playhead, selection: selection, duration: duration, fps: frameRate)
        do {
            _ = try reduce(&draft, .updateAudioLane(id, AudioClipPatch(placement: placement, trimStart: trimStart, trimDuration: trimDuration)), ctx: context)
            edit(coalesce: true) { $0 = draft }
            editIssue = nil
        } catch { editIssue = "Invalid music edit." }
    }

    func removeMusicLane(_ id: UUID) {
        dispatch(.deleteAudioLane(id))
        if selection == id { selection = nil }
    }

    /// External voice-over sits on an independent OUTPUT-time lane so translated
    /// narration isn't resampled a second time by source-time speed ramps.
    /// Imported images are owned by the project, not by a temporary download
    /// or a removable disk. A failed copy leaves the current style untouched.
    func setCanvasBackground(_ url: URL) {
        do {
            let directory = session.bundle.url.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("background-" + UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            try FileManager.default.copyItem(at: url, to: target)
            edit { $0.style.setPhotoBackground(target.path) }
        } catch {
            editIssue = "Could not import background: " + error.localizedDescription
        }
    }

    func importCanvasBackground() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.allowsMultipleSelection = false
        picker.prompt = "Choose background"
        if picker.runModal() == .OK, let url = picker.url { setCanvasBackground(url) }
    }

    func importWebcamBackground() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.allowsMultipleSelection = false
        picker.prompt = "Choose background"
        if picker.runModal() == .OK, let url = picker.url {
            edit { tl in
                tl.webcam?.backdropImagePath = url.path
                tl.webcam?.backdrop = .image
            }
        }
    }

    func importVoiceover() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.audio]
        picker.allowsMultipleSelection = false
        picker.prompt = "Import voice-over"
        if picker.runModal() == .OK, let url = picker.url {
            let start = playhead
            edit { tl in
                tl.audio.lanes.append(AudioLane(role: .voiceover, path: url.path,
                                                placement: start, gainDb: 0))
            }
        }
    }

    func openExportPanel() { exportPanelRequest += 1; exportPanelActive = true }

    func updateExportSettings(_ update: (inout ExportSettings) -> Void) {
        update(&exportSettings)
        if exportSettings.alpha { exportSettings.codec = .prores4444 }
        if exportSettings.codec.isProRes || exportSettings.alpha { exportSettings.container = .mov }
        if !exportSettings.codec.supportsAlpha { exportSettings.alpha = false }
        exportSettings.save()
    }

    func exportBinding<V>(_ key: WritableKeyPath<ExportSettings, V>) -> Binding<V> {
        Binding(get: { self.exportSettings[keyPath: key] },
                set: { value in self.updateExportSettings { $0[keyPath: key] = value } })
    }

    func chooseExportFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        picker.prompt = "Use folder"
        picker.directoryURL = URL(fileURLWithPath: (exportSettings.folder as NSString).expandingTildeInPath)
        // This is the ONLY picker allowed in the export workflow.
        if picker.runModal() == .OK, let url = picker.url {
            updateExportSettings { $0.folder = url.path }
        }
    }

    var estimatedExportSeconds: Double? {
        let throughput = UserDefaults.standard.double(forKey: "lumen.export.pixelsPerSecond")
        guard throughput > 0 else { return nil }
        let (w, h) = exportSettings.dimensions(source: session.meta.source, aspect: timeline.style.aspectRatio)
        let pixels = Double(w) * Double(h) * Double(exportSettings.frameRate.fps(source: session.meta.source.fps)) * duration
        return pixels / throughput
    }

    func setSeparateWavStems(_ enabled: Bool) {
        exportSeparateStems = enabled
        UserDefaults.standard.set(enabled, forKey: "lumen.export.separateWavStems")
    }

    func exportVideo() { startExport(settings: exportSettings, clipboard: false) }

    /// A self-contained package plus a `lumen://` link. The package is what
    /// another Mac opens; the link is what the user pastes into a message.
    func shareProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lumenshare") ?? .archive]
        panel.nameFieldStringValue = session.bundle.url.deletingPathExtension().lastPathComponent + ".lumenshare"
        panel.prompt = "Share"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    self.session.save(self.timeline)
                    try self.session.bundle.exportSharePackage(to: url)
                    let link = self.session.bundle.shareLink
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    self.notice = "Shared to \(url.lastPathComponent). Project link copied."
                } catch {
                    self.notice = "Couldn’t share this project. \(error.localizedDescription)"
                }
            }
        }
    }

    /// The Clipboard preset: a short 1080p H.264 file placed on the pasteboard as a file URL.
    func exportToClipboard() {
        var quick = exportSettings
        quick.kind = .video
        quick.resolution = .p1080
        quick.codec = .h264
        quick.container = .mp4
        quick.quality = .high
        quick.filename = "Lumen clip"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LumenClipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        quick.folder = directory.path
        startExport(settings: quick, clipboard: true)
    }

    private func startExport(settings: ExportSettings, clipboard: Bool) {
        if timeline.overlays.privacy.enabled && timeline.overlays.privacy.autoDetect {
            if privacyScanning {
                exportState = .failed("Sensitive-data scanning is still running. Wait for it to finish or turn off automatic detection.")
                return
            }
            if let error = privacyScanError {
                exportState = .failed("Sensitive-data analysis failed: \(error). Review masks or turn off automatic detection before exporting.")
                return
            }
        }
        guard let url = settings.destinationURL() else {
            exportState = .failed("Enter a valid filename.")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            exportState = .failed("Choose an existing output folder.")
            return
        }
        let preset = settings.preset(source: session.meta.source, aspect: timeline.style.aspectRatio)
        if settings.kind == .video,
           !ExportCapabilityMatrix.shared.supports(preset, aspect: timeline.style.aspectRatio) {
            exportState = .failed("This Mac cannot encode the chosen resolution, codec and frame rate.")
            return
        }
        let tl = timeline, session = session
        notice = nil
        exportElapsed = 0
        exportETA = nil
        exportTask?.cancel()
        pause()
        activeExportID = UUID()
        let exportID = activeExportID
        let start = HostClock.now()

        exportState = .running(0)
        // SMOOTHNESS: the export renderer is built off the main thread, so the
        // wallpaper URL is resolved here and handed over; otherwise a
        // wallpaper backdrop would export as a flat colour.
        Renderer.primeWallpaper(Renderer.resolveWallpaperURL())
        let stemExportEnabled = exportSeparateStems && !clipboard && settings.kind == .video
        exportTask = Task { [weak self] in
            let report: @Sendable (ExportProgress) -> Void = { [weak self] pr in
                guard let model = self else { return }
                Task { @MainActor in
                    guard model.activeExportID == exportID else { return }
                    guard case .running = model.exportState else { return }
                    let fraction = Double(pr.frame) / Double(max(pr.total, 1))
                    model.exportState = .running(fraction)
                    model.exportElapsed = HostClock.now() - start
                    model.exportETA = fraction > 0.01 ? max(0, model.exportElapsed * (1 - fraction) / fraction) : nil
                    if let n = pr.notice { model.notice = n }
                }
            }
            do {
                // Freeze one evidence snapshot and derive every aspect off
                // the UI actor. Export never consumes stale preview tracks.
                let input = session.input
                let worker = Task.detached(priority: .userInitiated) {
                    () throws -> [(url: URL, timeline: Timeline, preset: ExportPreset)] in
                    var cache = DeriveCache()
                    guard let primary = Director.deriveCancellable(tl, input: input, revision: (tl.derived?.revision ?? 0) + 1,
                                                                    cache: &cache, cancelled: { Task.isCancelled }) else { throw CancellationError() }
                    var jobs: [(url: URL, timeline: Timeline, preset: ExportPreset)] = [(url, primary, preset)]
                    if settings.batchAspects, settings.kind == .video {
                        for (index, aspect) in [CanvasAspect.r1x1, .r9x16].enumerated() {
                            var variant = tl
                            variant.style.customAspect = aspect.ratio
                            guard let derived = Director.deriveCancellable(variant, input: input, revision: (tl.derived?.revision ?? 0) + index + 2,
                                                                           cache: &cache, cancelled: { Task.isCancelled }) else { throw CancellationError() }
                            let suffix = aspect == .r1x1 ? "-1x1" : "-9x16"
                            let base = url.deletingPathExtension().lastPathComponent + suffix
                            let extra = url.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension(settings.fileExtension)
                            jobs.append((extra, derived, settings.preset(source: session.meta.source, aspect: aspect.ratio)))
                        }
                    }
                    return jobs
                }
                let jobs = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                var lastURL = url
                let jobCount = jobs.count
                for (index, job) in jobs.enumerated() {
                    try Task.checkCancellation()
                    let jobReport: @Sendable (ExportProgress) -> Void = { pr in
                        let inner = Double(pr.frame) / Double(max(pr.total, 1))
                        let base = Double(index) / Double(jobCount)
                        report(ExportProgress(frame: Int(((base + inner / Double(jobCount)) * 1000).rounded()),
                                              total: 1000, notice: pr.notice))
                    }
                    if settings.kind == .gif {
                        try await Exporter.gif(session: session, timeline: job.timeline, to: job.url, progress: jobReport)
                    } else {
                        try await Exporter.run(session: session, timeline: job.timeline, preset: job.preset, to: job.url,
                                               includeAudio: settings.includeAudio, audioBitrate: settings.audioBitrate,
                                               exportStems: stemExportEnabled,
                                               exportCursorLayer: settings.cursorLayer && !clipboard,
                                               progress: jobReport)
                    }
                    lastURL = job.url
                }
                let elapsed = max(HostClock.now() - start, 0.001)
                let (w, h) = settings.dimensions(source: session.meta.source, aspect: tl.style.aspectRatio)
                let pixels = Double(w) * Double(h) * Double(preset.fps) * tl.timeMap.outputDuration * Double(jobs.count)
                UserDefaults.standard.set(pixels / elapsed, forKey: "lumen.export.pixelsPerSecond")
                guard let self, self.activeExportID == exportID else { return }
                self.exportElapsed = elapsed
                self.exportETA = nil
                if clipboard {
                    NSPasteboard.general.clearContents()
                    _ = NSPasteboard.general.writeObjects([lastURL as NSURL])
                    self.notice = "Copied to clipboard."
                }
                self.exportState = .done(lastURL)
                self.recordExportFinished()
                Task { await EmailNotificationService.shared.exportFinished(file: lastURL) }
            } catch is CancellationError {
                if self?.activeExportID == exportID { self?.exportState = .idle }
            } catch {
                if self?.activeExportID == exportID { self?.exportState = .failed(error.localizedDescription) }
            }
        }
    }

    /// Restarts the raw-footage retention clock after a successful export and
    /// honours "Delete raw after export". No replan is needed: privacy fields
    /// do not affect the picture, so the timeline is saved directly.
    private func recordExportFinished() {
        var updated = timeline
        updated.overlays.privacy.lastExportAt = Date()
        timeline = updated
        box.set(updated)
        session.save(updated)
        if updated.overlays.privacy.deleteRawAfterExport {
            let removed = RawFootageSweep.deleteRaw(in: session.bundle)
            notice = removed.isEmpty ? nil : "Removed raw footage after export."
        }
    }

    func cancelExport() { exportTask?.cancel() }

}
