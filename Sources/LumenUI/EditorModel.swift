import SwiftUI
import AppKit
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
    func time(at h: Double) -> Double { s.withLock { $0.playing ? min($0.t0 + h - $0.h0, $0.dur) : $0.t0 } }
    func start(from t: Double, at h: Double, dur: Double) { s.withLock { $0 = S(playing: true, t0: t, h0: h, dur: dur) } }
    func pause(at h: Double) { s.withLock { if $0.playing { $0.t0 = min($0.t0 + h - $0.h0, $0.dur); $0.playing = false } } }
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
    private var exportTask: Task<Void, Never>?
    private let player = PreviewAudioPlayer()

    init(session: ProjectSession, renderer: Renderer, timeline: Timeline) {
        self.session = session; self.renderer = renderer; self.timeline = timeline; box = TimelineBox(timeline)
        renderer.setCustomCursors(session.cursors)
        remix()
    }

    static func open(url: URL) async throws -> EditorModel {
        let r = try Renderer()
        let (s, tl) = try await ProjectSession.open(ProjectBundle(url: url), device: r.device)
        var out = s.derive(tl, revision: 0)
        if out.style.background == .gradient || out.style.background == .mesh {
            out.style.background = .dither
            out.style.colors = DitherPalettes.all[0].1
        }
        return EditorModel(session: s, renderer: r, timeline: out)
    }

    // MARK: Edits (value-type timeline: undo is a stack of snapshots)

    func edit(coalesce: Bool = false, _ body: (inout Timeline) -> Void) {
        let old = timeline
        var new = old; body(&new)
        guard new != old else { return }
        if !(coalesce && Date().timeIntervalSince(lastEdit) < 0.6) { undoStack.append(old); if undoStack.count > 100 { undoStack.removeFirst() } }
        lastEdit = Date(); redoStack.removeAll()
        timeline = new; box.set(new)                                    // renderer shows the new look immediately, old derived tracks
        if old.cursor != new.cursor || old.camera != new.camera || old.zoom != new.zoom || old.timeMap != new.timeMap || old.audio != new.audio || old.webcam != new.webcam {
            replan()
        } else { session.save(new) }
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
        let tl = timeline, mixer = session.mixer, player = player
        Task.detached(priority: .utility) { player.load(mixer.mix(tl)) }
    }

    // MARK: Transport

    func seek(_ t: Double) {
        let c = min(max(t, 0), duration); playhead = c; clock.seek(c)
        if clock.playing { player.play(from: c, atHostSeconds: HostClock.now() + 0.03) }
    }
    func play() {
        let h = HostClock.now() + 0.03, t = playhead >= duration - 0.02 ? 0 : playhead
        clock.start(from: t, at: h, dur: duration); player.play(from: t, atHostSeconds: h)
    }
    func pause() { clock.pause(at: HostClock.now()); player.stop(); playhead = clock.time(at: HostClock.now()) }
    func togglePlay() { clock.playing ? pause() : play() }
    func tick(_ t: Double) { playhead = t; if clock.playing, t >= duration - 0.001 { pause() } }

    // MARK: Zoom segments

    func addZoom() {
        let s = playhead, e = min(s + 2.5, duration)
        guard e - s > 0.3 else { return }
        let z = ZoomSegment(start: s, end: e, scale: 2, focus: .follow, origin: .manual)
        edit { $0.zoom.append(z) }; selection = z.id
    }
    func deleteSelected() { if let id = selection { edit { $0.zoom.removeAll { $0.id == id } }; selection = nil } }
    func setFocus(box b: CGRect) {       // normalized source coords
        guard let id = selection, b.width > 0.02, b.height > 0.02 else { return }
        edit { tl in
            guard let i = tl.zoom.firstIndex(where: { $0.id == id }) else { return }
            tl.zoom[i].focus = .element(x: b.minX, y: b.minY, w: b.width, h: b.height)
            tl.zoom[i].scale = min(max((0.8 * min(1 / (b.width + 0.24), 1 / (b.height + 0.24)) * 10).rounded() / 10, 1.1), 4)
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

    func export(_ preset: ExportPreset, gif: Bool = false) {
        let p = NSSavePanel(); p.nameFieldStringValue = session.meta.name + (gif ? ".gif" : preset.codec == .prores ? ".mov" : ".mp4")
        guard p.runModal() == .OK, let url = p.url else { return }
        let tl = timeline, s = session
        exportState = .running(0); exportTask?.cancel()
        exportTask = Task { [weak self] in
            let report: @Sendable (ExportProgress) -> Void = { pr in Task { @MainActor in self?.exportState = .running(Double(pr.frame) / Double(pr.total)); if let n = pr.notice { self?.notice = n } } }
            do {
                if gif { try await Exporter.gif(session: s, timeline: tl, to: url, progress: report) }
                else { try await Exporter.run(session: s, timeline: tl, preset: preset, to: url, progress: report) }
                self?.exportState = .done(url)
            } catch is CancellationError { self?.exportState = .idle } catch { self?.exportState = .failed("\(error)") }
        }
    }
    func cancelExport() { exportTask?.cancel() }
}