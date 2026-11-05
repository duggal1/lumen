import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
import LumenExport

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

struct LookPreset: Codable, Identifiable { var id: String { name }; var name: String; var style: Style; var cursor: CursorStyle; var camera: CameraParams; var audio: AudioPlan }

@MainActor @Observable final class EditorModel {
    enum ExportState: Equatable { case idle, running(Double), done(URL), failed(String) }
    let session: ProjectSession, renderer: Renderer, box: TimelineBox, clock = PlaybackClock()
    private(set) var timeline: Timeline
    var playhead = 0.0
    var selection: UUID?
    var exportState = ExportState.idle
    var exportSettings: ExportSettings
    var exportPanelRequest = 0
    var exportPanelActive = false
    var zoomDebug = false
    var exportElapsed = 0.0
    var exportETA: Double?
    var notice: String?
    var focusEditing = false
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var duration: Double { timeline.timeMap.outputDuration }
    private var undoStack: [Timeline] = []
    private var redoStack: [Timeline] = []
    private var lastEdit = Date.distantPast
    private var revision = 1
    private var replanTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var activeExportID = UUID()
    private var mixTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var wantsPlayback = false
    private let player = PreviewAudioPlayer()

    init(session: ProjectSession, renderer: Renderer, timeline: Timeline) {
        self.session = session; self.renderer = renderer; self.timeline = timeline; box = TimelineBox(timeline)
        self.exportSettings = ExportSettings.load(defaultName: AppModel.displayName(session.meta.name))
        renderer.setCustomCursors(session.cursors)
        remix()
    }

    static func open(url: URL) async throws -> EditorModel {
        let (r, s, derived) = try await Task.detached(priority: .userInitiated) {
            let renderer = try Renderer()
            let (session, timeline) = try await ProjectSession.open(ProjectBundle(url: url), device: renderer.device)
            return (renderer, session, session.derive(timeline, revision: 0))
        }.value
        var out = derived
        if out.style.background == .gradient || out.style.background == .mesh {
            out.style.background = .dither
            out.style.colors = DitherPalettes.all[0].1
        }
        let model = EditorModel(session: s, renderer: r, timeline: out)
        model.analyzeInBackground(out)
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
        if analysisChanged { analyzeInBackground(new) }
        if old.cursor != new.cursor || old.camera != new.camera || old.zoom != new.zoom || old.timeMap != new.timeMap
            || old.audio != new.audio || old.webcam != new.webcam || old.overlays.taps != new.overlays.taps
            || old.layouts != new.layouts || old.layoutSettings != new.layoutSettings
            || old.captions != new.captions
            || old.style.aspectRatio != new.style.aspectRatio || old.style.padding != new.style.padding
            || old.style.paddingInsets != new.style.paddingInsets {
            replan()
        } else { session.save(new) }
    }

    private func analyzeInBackground(_ snapshot: Timeline) {
        analysisTask?.cancel()
        let session = session
        analysisTask = Task { [weak self] in
            await session.analyze(snapshot)
            guard !Task.isCancelled, let self else { return }
            self.replan()
        }
    }
    func setWebcam(_ on: Bool) { edit { $0.webcam = on ? ($0.webcam ?? WebcamLayout()) : nil } }
    func undo() { if let p = undoStack.popLast() { redoStack.append(timeline); restore(p) } }
    func redo() { if let n = redoStack.popLast() { undoStack.append(timeline); restore(n) } }
    private func restore(_ t: Timeline) { replanTask?.cancel(); timeline = t; box.set(t); session.save(t); remix(); if clock.playing { play() } }

    func bind<V>(_ kp: WritableKeyPath<Timeline, V>) -> Binding<V> {
        Binding(get: { self.timeline[keyPath: kp] }, set: { v in self.edit(coalesce: true) { $0[keyPath: kp] = v } })
    }

    /// Debounced 100 ms. Director runs off-main on a snapshot; a newer edit cancels this one.
    private func replan() {
        replanTask?.cancel()
        let snap = timeline, s = session; revision += 1; let rev = revision
        replanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let out = await Task.detached(priority: .userInitiated) { s.derive(snap, revision: rev) }.value
            guard !Task.isCancelled, let self else { return }
            self.timeline = out; self.box.set(out); s.save(out); self.remix()
            self.playhead = min(self.playhead, out.timeMap.outputDuration); self.clock.seek(self.playhead)
        }
    }

    private func remix() {
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
            if let self, self.wantsPlayback { self.play() }
        }
    }

    // MARK: Transport

    func seek(_ t: Double) {
        let wasPlaying = wantsPlayback
        playbackTask?.cancel()
        let c = min(max(t, 0), duration); playhead = c; clock.seek(c)
        if wasPlaying { play() }
    }
    func play() {
        wantsPlayback = true
        playbackTask?.cancel()
        let ready = mixTask
        playbackTask = Task { [weak self] in
            await ready?.value
            guard !Task.isCancelled, let self, self.wantsPlayback else { return }
            let t = self.playhead >= self.duration - 0.02 ? 0 : self.playhead
            let h = self.player.play(from: t, atHostSeconds: HostClock.now() + 0.03)
            self.clock.start(from: t, at: h, dur: self.duration)
        }
    }
    func pause() {
        wantsPlayback = false
        playbackTask?.cancel()
        clock.pause(at: HostClock.now()); player.stop(); playhead = clock.time(at: HostClock.now())
    }
    func togglePlay() { wantsPlayback ? pause() : play() }

    func tick(_ t: Double) { playhead = t; if clock.playing, t >= duration - 0.001 { pause() } }

    // MARK: Zoom segments

    func addZoom() {
        let s = playhead, e = min(s + 2.5, duration)
        guard e - s > 0.3 else { return }
        let tm = timeline.timeMap
        let z = ZoomSegment(start: tm.source(atOutput: s), end: tm.source(atOutput: e), scale: 2, focus: .follow, origin: .manual)
        edit { $0.zoom.append(z) }; selection = z.id
    }
    func dispatch(_ c: Command) {
        let ctx = ReduceContext(playhead: playhead, selection: selection, duration: duration)
        edit { tl in _ = try? reduce(&tl, c, ctx: ctx) }
    }
    func deleteSelected() { if let id = selection { edit { $0.zoom.removeAll { $0.id == id } }; selection = nil } }
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

    func importMusic() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { edit { $0.audio.musicPath = u.path } }
    }

    func openExportPanel() { exportPanelRequest += 1; exportPanelActive = true }

    func updateExportSettings(_ update: (inout ExportSettings) -> Void) {
        update(&exportSettings)
        if exportSettings.codec == .prores { exportSettings.container = .mov }
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

    func exportVideo() {
        let settings = exportSettings
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
        guard ExportCapabilityMatrix.shared.supports(preset, aspect: timeline.style.aspectRatio) else {
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
                try await Exporter.run(session: session, timeline: tl, preset: preset, to: url,
                                       includeAudio: settings.includeAudio, audioBitrate: settings.audioBitrate,
                                       progress: report)
                let elapsed = max(HostClock.now() - start, 0.001)
                let (w, h) = settings.dimensions(source: session.meta.source, aspect: tl.style.aspectRatio)
                let pixels = Double(w) * Double(h) * Double(preset.fps) * tl.timeMap.outputDuration
                UserDefaults.standard.set(pixels / elapsed, forKey: "lumen.export.pixelsPerSecond")
                guard let self, self.activeExportID == exportID else { return }
                self.exportElapsed = elapsed
                self.exportETA = nil
                self.exportState = .done(url)
            } catch is CancellationError {
                if self?.activeExportID == exportID { self?.exportState = .idle }
            } catch {
                if self?.activeExportID == exportID { self?.exportState = .failed(error.localizedDescription) }
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

}
