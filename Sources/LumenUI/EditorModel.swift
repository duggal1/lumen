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
    var playing: Bool { s.withLock { $0.playing } }
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
        // running. Discard cancelled requests before doing any CPU work.
        guard !Task.isCancelled else { return nil }
        let result = Director.derive(tl, input: input, revision: revision, cache: &cache)
        return Task.isCancelled ? nil : result
    }
}

struct LookPreset: Codable, Identifiable { var id: String { name }; var name: String; var style: Style; var cursor: CursorStyle; var camera: CameraParams; var audio: AudioPlan }

@MainActor @Observable final class EditorModel {
    enum ExportState: Equatable { case idle, running(Double), done(URL), failed(String) }
    let session: ProjectSession, renderer: Renderer, box: TimelineBox, clock = PlaybackClock()
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
    var exportState = ExportState.idle
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
    private var pendingInitialAnalysis = false
    private var exportTask: Task<Void, Never>?
    private var activeExportID = UUID()
    private var mixTask: Task<Void, Never>?
    private var hasMixed = false
    private var isMixing = false
    private var mixGeneration = 0
    private var playbackTask: Task<Void, Never>?
    private var wantsPlayback = false
    private let player = PreviewAudioPlayer()

    init(session: ProjectSession, renderer: Renderer, timeline: Timeline) {
        self.session = session; self.renderer = renderer; self.timeline = timeline; box = TimelineBox(timeline)
        self.exportSettings = ExportSettings.load(defaultName: AppModel.displayName(session.meta.name))
        renderer.setCustomCursors(session.cursors)
        // No eager remix at open: the full offline mix (WPE + studio chain)
        // is seconds of CPU and was competing with derive at open. It is
        // built lazily on first Play (see play()).
        setTranscript(session.transcriptFile?.transcript.shifted(by: session.micOffset))
    }

    static func open(url: URL) async throws -> EditorModel {
        let (r, s, initial) = try await Task.detached(priority: .userInitiated) {
            let renderer = try Renderer()
            let (session, timeline) = try await ProjectSession.open(ProjectBundle(url: url), device: renderer.device)
            return (renderer, session, timeline)
        }.value
        // Open the editor from persisted intent immediately. Cursor/camera
        // derivation is CPU-heavy and must not block the Studio window.
        let model = EditorModel(session: s, renderer: r, timeline: initial)
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
        guard new != old else { return }
        if !(coalesce && Date().timeIntervalSince(lastEdit) < 0.6) { undoStack.append(old); if undoStack.count > 100 { undoStack.removeFirst() } }
        lastEdit = Date(); redoStack.removeAll()
        timeline = new; box.set(new)                                    // renderer shows the new look immediately, old derived tracks
        let analysisChanged = old.overlays.privacy != new.overlays.privacy || old.captions.enabled != new.captions.enabled
            || old.captions.locale != new.captions.locale || old.captions.vocabulary != new.captions.vocabulary
            || old.layouts != new.layouts
            || old.webcam?.backdrop != new.webcam?.backdrop
        if analysisChanged { analyzeInBackground(new) }
        if old.cursor != new.cursor || old.camera != new.camera || old.zoom != new.zoom || old.timeMap != new.timeMap
            || old.audio != new.audio || old.webcam != new.webcam || old.overlays.taps != new.overlays.taps
            || old.layouts != new.layouts || old.layoutSettings != new.layoutSettings
            || old.captions != new.captions
            || old.style.aspectRatio != new.style.aspectRatio || old.style.padding != new.style.padding
            || old.style.paddingInsets != new.style.paddingInsets {
            replan(remixAudio: old.audio != new.audio, debounce: coalesce)
        } else { session.save(new) }
    }

    private func analyzeInBackground(_ snapshot: Timeline) {
        analysisTask?.cancel()
        let scansPrivacy = snapshot.overlays.privacy.enabled && snapshot.overlays.privacy.autoDetect
        privacyScanning = scansPrivacy
        privacyAnalysisComplete = !scansPrivacy
        privacyScanError = nil
        let session = session
        analysisTask = Task { [weak self] in
            let result = await session.analyze(snapshot)
            guard !Task.isCancelled, let self else { return }
            if scansPrivacy { self.privacyScanError = result.errors["ocr"] }
            self.privacyAnalysisComplete = true
            // The result must be applied by the Director before export
            // is re-enabled. A completion of OCR alone is not sufficient.
            self.replan()
            self.autoTranscribeIfNeeded()
        }
    }
    func setWebcam(_ on: Bool) { edit { $0.webcam = on ? ($0.webcam ?? WebcamLayout()) : nil } }
    func undo() { if let p = undoStack.popLast() { redoStack.append(timeline); restore(p) } }
    func redo() { if let n = redoStack.popLast() { undoStack.append(timeline); restore(n) } }
    private func restore(_ t: Timeline) { replanTask?.cancel(); timeline = t; box.set(t); session.save(t); remix(); if clock.playing { play() } }

    func bind<V>(_ kp: WritableKeyPath<Timeline, V>) -> Binding<V> {
        Binding(get: { self.timeline[keyPath: kp] }, set: { v in self.edit(coalesce: true) { $0[keyPath: kp] = v } })
    }

    /// No artificial debounce: a yield coalesces a burst of slider events and
    /// the actor pipeline keeps the cursor stage warm. A newer edit cancels the
    /// awaiting task before it can publish a stale timeline.
    private func replan(remixAudio: Bool = false, debounce: Bool = false) {
        replanTask?.cancel()
        let snap = timeline, s = session, pl = pipeline; revision += 1; let rev = revision
        replanTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(60)) }
            else { await Task.yield() }
            guard !Task.isCancelled else { return }
            guard let out = await pl.derive(snap, input: s.input, revision: rev),
                  !Task.isCancelled, let self else { return }
            // Visual-only changes must never restart a full-recording audio mix.
            let audioChanged = remixAudio || snap.audio != out.audio || snap.timeMap != out.timeMap
                || snap.clips != out.clips || snap.derived?.cues != out.derived?.cues
                || snap.derived?.duck != out.derived?.duck
            self.timeline = out; self.box.set(out); s.save(out)
            if self.pendingInitialAnalysis {
                self.pendingInitialAnalysis = false
                self.analyzeInBackground(out)
            }
            if audioChanged, self.hasMixed { self.remix() }
            self.playhead = min(self.playhead, out.compositionDuration)
            self.published = self.playhead
            self.clock.seek(self.playhead)
            if self.privacyAnalysisComplete { self.privacyScanning = false }
        }
    }

    private func remix() {
        hasMixed = true
        let resume = wantsPlayback
        if clock.playing { pause() }
        wantsPlayback = resume
        playbackTask?.cancel()
        let previous = mixTask
        previous?.cancel()
        let tl = timeline, mixer = session.mixer, player = player
        mixTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            let audio = await Task.detached(priority: .userInitiated) { mixer.mix(tl) }.value
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .userInitiated) { player.load(audio) }.value
            guard !Task.isCancelled else { return }
            if let self {
                self.mixStats = audio.map { ($0.lufs, $0.truePeakDb) }
                if self.wantsPlayback { self.play() }
            }
        }
    }

    // MARK: Transport

    func seek(_ t: Double) {
        let wasPlaying = wantsPlayback
        playbackTask?.cancel()
        let c = min(max(t, 0), duration); playhead = c; published = c; clock.seek(c)
        if wasPlaying { play() }
    }
    func play() {
        wantsPlayback = true
        if !hasMixed { remix() }
        playbackTask?.cancel()
        let ready = mixTask
        playbackTask = Task { [weak self] in
            await ready?.value
            guard !Task.isCancelled, let self, self.wantsPlayback else { return }
            let t = self.playhead >= self.duration - 0.02 ? 0 : self.playhead
            // Start audio and video on the same host instant. The player
            // subtracts the output device latency, so a Bluetooth sink does
            // not make clicks land late.
            let audible = HostClock.now() + max(0.05, self.player.outputLatency + 0.03)
            // The player returns the host instant the first sample reaches the
            // speakers (it clamps when the requested start is already past).
            let start = self.player.play(from: t, atHostSeconds: audible)
            self.clock.start(from: t, at: start, dur: self.duration)
            self.isPlaying = true
        }
    }
    func pause() {
        wantsPlayback = false
        playbackTask?.cancel()
        clock.pause(at: HostClock.now()); player.stop()
        playhead = clock.time(at: HostClock.now()); published = playhead
        isPlaying = false
    }
    func togglePlay() { wantsPlayback ? pause() : play() }

    /// Publishing the playhead at display rate invalidates the whole editor
    /// (including the waveform canvas) 60-120 times a second. The preview reads
    /// the clock directly, so the inspector only needs ~12 Hz.
    func tick(_ t: Double) {
        if abs(t - published) >= 1.0 / 12 { playhead = t; published = t }
        if clock.playing, t >= duration - 0.001 { pause() }
    }

    func setTranscript(_ t: Transcript?) { transcript = t; sentences = t.map { Sentences.split($0.words) } ?? [] }
    func seekSource(_ s: Double) { seek(timeline.timeMap.output(atSource: s)) }

    func transcribe() {
        guard session.meta.mic != nil else { return }
        guard MoonshineRuntime.isAvailable, ModelStore.isInstalled(.current) else {
            // No Moonshine runtime/model: fall back to Apple Speech instead of
            // leaving the timeline untranscribed (model download stays optional).
            transcribeWithAppleSpeech()
            return
        }
        let b = session.bundle, off = session.micOffset, size = MoonshineSize.current
        transcribeState = .running(0); transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            let res = await FileTranscriber.run(url: b.micURL, size: size) { p in Task { @MainActor in self?.transcribeState = .running(p) } }
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

    /// On-device Apple Speech path used when the optional Moonshine model
    /// is not installed. Same commit path (save + align + replan) as Moonshine.
    private func transcribeWithAppleSpeech() {
        let b = session.bundle, off = session.micOffset
        transcribeState = .running(0); transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            do {
                let tr = try await AppleSpeechEngine().transcribe(audio: b.micURL, locale: Locale(identifier: "en-US"), vocabulary: [])
                guard let self, !Task.isCancelled else { return }
                try? b.saveTranscript(TranscriptFile(engine: "apple-speech", complete: true, transcript: tr))
                let aligned = tr.shifted(by: off)
                self.setTranscript(aligned)
                self.session.updateTranscript(aligned)
                self.replan()
                self.transcribeState = .idle
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.transcribeState = .failed("Apple Speech: \(error)")
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

    /// Blade: removes one second from the playhead. The cut appears in the
    /// Inspector's cut list, so it stays reversible without an undo hunt.
    func cutAtPlayhead() {
        guard playhead < timeline.timeMap.outputDuration - 0.1 else { return }
        dispatch(.cutAtPlayhead(length: 1))
    }

    /// Arm manual click placement at the current playhead time.
    func addTapAtPlayhead() {
        placingTool = .tap
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

    func setTranscriptWord(_ index: Int, deleted: Bool) {
        dispatch(deleted ? .deleteWords([index]) : .restoreWords([index]))
    }

    /// Removes filler words from both captions and the cut map. The word list
    /// stays intact in the project: deletion is a mask, never data loss.
    func removeFillerWords() {
        let fillers: Set<String> = ["um", "uh", "erm", "hmm", "like", "basically", "actually", "you know", "i mean", "sort of", "kind of"]
        let indices = transcriptWords.enumerated().compactMap { index, word in
            fillers.contains(word.text.lowercased().trimmingCharacters(in: .punctuationCharacters)) ? index : nil
        }
        guard !indices.isEmpty else { return }
        dispatch(.deleteWords(indices))
    }
    func dispatch(_ c: Command) {
        let ctx = ReduceContext(playhead: playhead, selection: selection, duration: duration)
        edit { tl in _ = try? reduce(&tl, c, ctx: ctx) }
    }
    func deleteSelected() {
        guard let id = selection else { return }
        if timeline.zoom.contains(where: { $0.id == id }) { dispatch(.deleteZoom(id)) }
        else if timeline.overlays.texts.contains(where: { $0.id == id }) { dispatch(.deleteText(id)) }
        else if timeline.overlays.highlights.contains(where: { $0.id == id }) { dispatch(.deleteHighlight(id)) }
        else if timeline.overlays.loupes.contains(where: { $0.id == id }) { dispatch(.deleteLoupe(id)) }
        else if timeline.clips.contains(where: { $0.id == id }) { dispatch(.deleteClip(id)) }
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

    private static var presetsDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumen/Presets")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    static func loadPresets() -> [LookPreset] {
        ((try? FileManager.default.contentsOfDirectory(at: presetsDir, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? JSONDecoder().decode(LookPreset.self, from: Data(contentsOf: $0)) }.sorted { $0.name < $1.name }
    }
    func savePreset(_ name: String) {
        let p = LookPreset(name: name, style: timeline.style, cursor: timeline.cursor, camera: timeline.camera, audio: timeline.audio)
        try? JSONEncoder().encode(p).write(to: Self.presetsDir.appendingPathComponent("\(name).json"))
    }
    func apply(_ p: LookPreset) { edit { $0.style = p.style; $0.cursor = p.cursor; $0.camera = p.camera; $0.audio = p.audio } }

    /// Auditions the selected click at the current click level without
    /// touching timeline playback.
    func previewClick() { player.previewClick(timeline.audio) }

    func importMusic() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { edit { $0.audio.musicPath = u.path } }
    }

    /// External voice-over sits on an independent OUTPUT-time lane so translated
    /// narration isn't resampled a second time by source-time speed ramps.
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

        // One job per aspect. The primary output keeps the project's own ratio.
        var jobs: [(url: URL, timeline: Timeline, preset: ExportPreset)] = [(url, tl, preset)]
        if settings.batchAspects, settings.kind == .video {
            for (index, aspect) in [CanvasAspect.r1x1, .r9x16].enumerated() {
                var variant = tl
                variant.style.customAspect = aspect.ratio
                let derived = session.derive(variant, revision: (tl.derived?.revision ?? 0) + index + 1)
                let suffix = aspect == .r1x1 ? "-1x1" : "-9x16"
                let base = url.deletingPathExtension().lastPathComponent + suffix
                let extra = url.deletingLastPathComponent().appendingPathComponent(base)
                    .appendingPathExtension(settings.fileExtension)
                jobs.append((extra, derived, settings.preset(source: session.meta.source, aspect: aspect.ratio)))
            }
        }

        exportState = .running(0)
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
                Task { await EmailNotificationService.shared.exportFinished(file: lastURL) }
            } catch is CancellationError {
                if self?.activeExportID == exportID { self?.exportState = .idle }
            } catch {
                if self?.activeExportID == exportID { self?.exportState = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

}
