import Foundation
import os
import AppKit
import Metal
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
import LumenAnalysis
import LumenExport
import LumenActuator
import LumenSpeech

/// The command layer. Every capture, edit, verify and export action the agent
/// can take goes through here, and every one of them calls the SAME existing
/// code the UI calls: `Director.derive`, `ProjectSession`, `Exporter`,
/// `AudioMixer`, `AccuracyReport` and the privacy scan.
///
/// The engine is an actor. Long work runs in jobs, never on the main actor.
public actor Engine {
    public struct ProjectRef: Sendable, Equatable {
        public let identifier: String
        public let url: URL
        public var name: String { url.deletingPathExtension().lastPathComponent }
    }

    struct Handle {
        var bundle: ProjectBundle
        var meta: ProjectMeta
        var timeline: Timeline
        var revision: Int
        var undoStack: [Timeline] = []
        var redoStack: [Timeline] = []
        var session: ProjectSession?
        /// AGENT: an empty scan used to look identical to a clean one, so privacy
        /// failed open. The state is now explicit and gates export and QA.
        var privacy: PrivacyState = .notScanned
    }

    enum PrivacyState: Sendable, Equatable {
        case notRequired
        case notScanned
        case scanning
        case scanned(detections: Int)
        case failed(String)
    }

    public let runtime: LumenRuntime
    public let jobs: JobManager
    public let policy: Policy
    private var handles: [String: Handle] = [:]
    private let refs = OSAllocatedUnfairLock<[ProjectRef]>(initialState: [])

    public init(runtime: LumenRuntime, jobs: JobManager, policy: Policy) {
        self.runtime = runtime
        self.jobs = jobs
        self.policy = policy
    }

    // MARK: Projects

    /// Projects known to the engine (the library plus everything opened).
    public nonisolated func knownProjects() -> [ProjectRef] {
        refs.withLock { $0 }
    }

    private func remember(_ ref: ProjectRef) {
        refs.withLock { list in
            if !list.contains(where: { $0.identifier == ref.identifier }) { list.append(ref) }
        }
    }

    /// Opens a project bundle and returns its handle.
    @discardableResult
    public func openProject(at path: String) async throws -> ProjectRef {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let bundle = ProjectBundle(url: url)
        guard FileManager.default.fileExists(atPath: bundle.projectURL.path) else {
            if bundle.isUnfinished {
                throw ToolError(code: "PROJECT_UNFINISHED",
                                hint: "This recording was interrupted before it was finished. Recover it from the Library, or record again.")
            }
            throw ToolError(code: "PROJECT_NOT_FOUND",
                            hint: "There is no project at \(url.path).")
        }
        let file = try bundle.load()
        let identifier = url.deletingPathExtension().lastPathComponent
        let ref = ProjectRef(identifier: identifier, url: url)
        remember(ref)
        var handle = Handle(bundle: bundle, meta: file.meta, timeline: file.timeline, revision: 1)
        // The session is what the editor uses: it owns the frame source, the
        // mixer and the Director inputs.
        if let device = MTLCreateSystemDefaultDevice() {
            if let opened = try? await ProjectSession.open(bundle, device: device) {
                handle.session = opened.0
                handle.timeline = opened.1
                // AGENT: a project that already carries detections counts as scanned.
                let count = opened.0.input.ocr.count
                handle.privacy = count > 0 ? .scanned(detections: count) : .notScanned
            }
        }
        handles[identifier] = handle
        return ref
    }

    /// Ensures a project is open, opening it from the library when needed.
    private func requireHandle(_ projectID: String) async throws -> Handle {
        if let h = handles[projectID] { return h }
        let library = await runtime.recordingLibrary()
        if let match = library.first(where: { $0.deletingPathExtension().lastPathComponent == projectID }) {
            let ref = try await openProject(at: match.path)
            return handles[ref.identifier] ?? handles[projectID]!
        }
        throw ToolError.failed("Unknown project \(projectID). Call project_open first.")
    }

    // MARK: Timeline reads

    public func timelineValue(projectID: String) async throws -> JSONValue {
        var h = try await requireHandle(projectID)
        if let session = h.session { h.timeline = session.derive(h.timeline, revision: h.revision) }
        handles[projectID] = h
        return encode(timeline: h.timeline, revision: h.revision)
    }

    public func markersValue(projectID: String) async throws -> JSONValue {
        let h = try await requireHandle(projectID)
        let markers = h.bundle.loadMarkers().markers
        let origin = h.meta.clock.originHostSeconds
        let rows: [JSONValue] = markers.map { m -> JSONValue in
            .object(["id": .string(m.id),
                     "label": m.label.map { .string($0) } ?? .null,
                     "host_start": .number(m.startHostSeconds),
                     "host_end": .number(m.endHostSeconds),
                     "source_start": .number(max(m.startHostSeconds - origin, 0)),
                     "source_end": .number(max(m.endHostSeconds - origin, 0)),
                     "rect": m.rect.map { .array([.number($0.origin.x), .number($0.origin.y), .number($0.size.width), .number($0.size.height)]) } ?? .null])
        }
        return .object(["markers": .array(rows), "origin_host_seconds": .number(origin)])
    }

    /// The Timeline as JSON: the agent patches the same fields the UI edits.
    func encode(timeline: Timeline, revision: Int) -> JSONValue {
        var out: [String: JSONValue] = [
            "revision": .int(revision),
            "duration": .number(timeline.compositionDuration),
            "zoom": .array(timeline.zoom.map { z in
                .object(["id": .string(z.id.uuidString),
                         "start": .number(z.start), "end": .number(z.end),
                         "scale": .number(z.scale),
                         "focus": focusJSON(z.focus),
                         "origin": .string(originName(z.origin))])
            }),
            "cuts": .array(timeline.timeMap.cuts.map { c in
                .object(["id": .string(c.id.uuidString), "start": .number(c.start), "end": .number(c.end)])
            }),
            "ramps": .array(timeline.timeMap.ramps.map { r in
                .object(["id": .string(r.id.uuidString), "start": .number(r.start), "end": .number(r.end),
                         "speed": .number(r.speed), "origin": .string(originName(r.origin))])
            }),
            "style": .object([
                "background": .string(timeline.style.background.rawValue),
                "padding": .number(timeline.style.padding),
                "corner_radius": .number(timeline.style.cornerRadius),
                "shadow": .number(timeline.style.shadow),
                "aspect": .number(timeline.style.aspectRatio),
                "canvas": .string(timeline.style.canvas.rawValue),
                "wallpaper_blur": .number(timeline.style.wallpaperBlur),
                "background_image_path": timeline.style.backgroundImagePath.map { .string($0) } ?? .null,
            ]),
            "cursor": .object([
                "pack": .string(timeline.cursor.pack.rawValue),
                "size": .number(timeline.cursor.size),
            ]),
            "audio": .object([
                "music_path": timeline.audio.musicPath.map { .string($0) } ?? .null,
                "music_gain_db": .number(timeline.audio.musicGainDb),
                "target_lufs": .number(timeline.audio.targetLUFS),
                "lanes": .array(timeline.audio.lanes.map { l in
                    .object(["id": .string(l.id.uuidString), "role": .string(l.role.rawValue),
                             "path": l.path.map { .string($0) } ?? .null,
                             "placement": .number(l.placement), "gain_db": .number(l.gainDb),
                             "mute": .bool(l.mute)])
                }),
            ]),
            "captions": .object([
                "enabled": .bool(timeline.captions.enabled),
                "locale": .string(timeline.captions.locale),
            ]),
            "privacy": .object([
                "enabled": .bool(timeline.overlays.privacy.enabled),
                "auto_detect": .bool(timeline.overlays.privacy.autoDetect),
                "mode": .string(timeline.overlays.privacy.mode.rawValue),
            ]),
        ]
        return .object(out)
    }

    private func focusJSON(_ focus: Focus) -> JSONValue {
        switch focus {
        case .follow: return .object(["mode": .string("follow")])
        case .fixed(let x, let y): return .object(["mode": .string("fixed"), "x": .number(x), "y": .number(y)])
        case .element(let x, let y, let w, let h):
            return .object(["mode": .string("element"), "x": .number(x), "y": .number(y),
                            "w": .number(w), "h": .number(h)])
        }
    }

    private func originName(_ origin: Origin) -> String {
        switch origin {
        case .manual: return "manual"
        case .auto: return "auto"
        }
    }

    // MARK: Editing

    /// Applies an edit to the Timeline and saves the project, exactly the way
    /// the editor does: same value type, same undo stack, same save call.
    /// The revision check keeps a human and an agent from clobbering each
    /// other.
    @discardableResult
    public func edit(projectID: String, expectRevision: Int?, describe: String,
                     _ body: @escaping @Sendable (inout Timeline) throws -> Void) async throws -> [String: JSONValue] {
        var h = try await requireHandle(projectID)
        if let expectRevision, expectRevision != h.revision {
            throw ToolError.revisionConflict(expected: expectRevision, actual: h.revision)
        }
        let old = h.timeline
        var updated = h.timeline
        try body(&updated)
        if updated == old {
            return ["project_id": .string(projectID), "revision": .int(h.revision), "changed": .bool(false)]
        }
        h.undoStack.append(old)
        if h.undoStack.count > 100 { h.undoStack.removeFirst() }
        h.redoStack.removeAll()
        h.timeline = updated
        h.revision += 1
        try save(&h)
        handles[projectID] = h
        return ["project_id": .string(projectID),
                "revision": .int(h.revision),
                "changed": .bool(true),
                "summary": .string(describe)]
    }

    /// Undoes the last agent edit.
    @discardableResult
    public func undo(projectID: String) async throws -> [String: JSONValue] {
        var h = try await requireHandle(projectID)
        guard let previous = h.undoStack.popLast() else {
            throw ToolError.failed("Nothing to undo in \(projectID).")
        }
        h.redoStack.append(h.timeline)
        h.timeline = previous
        h.revision += 1
        try save(&h)
        handles[projectID] = h
        return ["project_id": .string(projectID), "revision": .int(h.revision), "changed": .bool(true)]
    }

    /// Saves and re-derives. The derive is the existing pure Director.
    private func save(_ h: inout Handle) throws {
        var timeline = h.timeline
        if let session = h.session {
            timeline = session.derive(timeline, revision: h.revision)
        }
        h.timeline = timeline
        try h.bundle.save(ProjectFile(meta: h.meta, timeline: timeline))
    }

    // MARK: Verification

    /// Renders one frame of the project and returns PNG bytes.
    public func previewFrame(projectID: String, time: Double, maxWidth: Int = 960) async throws -> (Data, String) {
        let image = try await renderFrame(projectID: projectID, time: time, maxWidth: maxWidth)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ToolError.failed("The frame could not be encoded.")
        }
        return (png, "frame-" + String(Int(time * 1000)) + "ms.png")
    }

    /// N frames across the project as one contact sheet.
    public func previewSheet(projectID: String, frames: Int, duration: Double, maxWidth: Int) async throws -> Data {
        let h = try await requireHandle(projectID)
        let total = duration > 0 ? duration : (h.meta.source.duration > 0 ? h.meta.source.duration : 1)
        let count = max(1, min(frames, 12))
        var images: [CGImage] = []
        for i in 0..<count {
            let t = total * (Double(i) + 0.5) / Double(count)
            images.append(try await renderFrame(projectID: projectID, time: t, maxWidth: maxWidth))
        }
        guard let first = images.first else { throw ToolError.failed("No frames rendered.") }
        let columns = min(3, images.count)
        let rows = Int(ceil(Double(images.count) / Double(columns)))
        let cellWidth = Int(first.width), cellHeight = Int(first.height)
        let canvas = CGSize(width: CGFloat(cellWidth * columns), height: CGFloat(cellHeight * rows))
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ToolError.failed("Could not build the contact sheet.")
        }
        context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvas))
        for (index, image) in images.enumerated() {
            let column = index % columns, row = index / columns
            let x = CGFloat(column * cellWidth)
            let y = canvas.height - CGFloat(row + 1) * CGFloat(cellHeight)
            context.draw(image, in: CGRect(x: x, y: y, width: CGFloat(cellWidth), height: CGFloat(cellHeight)))
        }
        guard let sheet = context.makeImage() else { throw ToolError.failed("Could not build the contact sheet.") }
        let rep = NSBitmapImageRep(cgImage: sheet)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ToolError.failed("The contact sheet could not be encoded.")
        }
        return png
    }

    private func renderFrame(projectID: String, time: Double, maxWidth: Int) async throws -> CGImage {
        let h = try await requireHandle(projectID)
        guard let session = h.session else {
            throw ToolError.failed("This project cannot be opened for rendering (no Metal device).")
        }
        let timeline = session.derive(h.timeline, revision: h.revision)
        let renderer = try Renderer()
        renderer.setCustomCursors(session.cursors)
        let aspect = timeline.style.aspectRatio
        let width = max(maxWidth, 160)
        let height = Int((Double(width) / max(aspect, 0.1)).rounded())
        let buffer = try await FrameImage.render(renderer: renderer, session: session, timeline: timeline,
                                                t: time, canvas: SIMD2<Int>(width, height),
                                                fps: session.meta.source.fps)
        guard let image = FrameImage.cgImage(buffer) else {
            throw ToolError.failed("The frame could not be rendered.")
        }
        return image
    }

    /// The QA report an agent loops on.
    public func qaReport(projectID: String) async throws -> JSONValue {
        let h = try await requireHandle(projectID)
        guard let session = h.session else {
            throw ToolError.failed("This project cannot be opened for analysis (no Metal device).")
        }
        let timeline = session.derive(h.timeline, revision: h.revision)
        let events = session.input.events

        // Zoom accuracy — the existing measurement.
        let accuracy = AccuracyReport.measure(timeline, events: events)
        let zoomTargetsMet = accuracy.zoomedClicks > 0
            && accuracy.centeredClicks == accuracy.zoomedClicks
            && accuracy.settled == accuracy.zoomedClicks

        // Loudness — the existing mixer measurement.
        var loudness: Double = 0
        var truePeak: Double = 0
        if let mixed = session.mixer.mix(timeline) {
            loudness = mixed.lufs
            truePeak = mixed.truePeakDb
        }
        let loudnessOK = loudness <= -14 && loudness >= -24 && truePeak <= -1.0

        // Privacy: only a completed scan can pass, and a mask must actually cover.
        let plan = timeline.overlays.privacy
        let W = Double(h.meta.source.width), H = Double(h.meta.source.height)
        var privacyOK = true
        var privacyDetail = "not required"
        if plan.enabled && plan.autoDetect {
            switch h.privacy {
            case .scanned(let count):
                // AGENT: containment, not a 1 px overlap, decides whether a mask covers.
                let unmasked = session.input.ocr.filter { d in
                    !covered(rect(d, W: W, H: H), by: maskRects(at: d.t, timeline: timeline))
                }
                privacyOK = unmasked.isEmpty
                privacyDetail = "\(count) detections, \(unmasked.count) unmasked"
            case .scanning:
                privacyOK = false
                privacyDetail = "privacy scan still running"
            case .failed(let message):
                privacyOK = false
                privacyDetail = "privacy scan failed: \(message)"
            case .notRequired, .notScanned:
                // AGENT: never report OK when the scan simply never ran.
                privacyOK = false
                privacyDetail = "not scanned: run privacy_scan, then retry"
            }
        }

        // Dropped frames — from the capture metadata.
        let dropped = h.meta.droppedFrames
        let droppedOK = dropped == 0

        // Silence: an all-zero master is a bug, not a mix.
        let silenceOK = loudness > -70

        func check(_ name: String, _ ok: Bool, _ detail: String) -> JSONValue {
            .object(["name": .string(name), "ok": .bool(ok), "detail": .string(detail)])
        }
        return .object([
            "project_id": .string(projectID),
            "checks": .array([
                check("zoom_targets", zoomTargetsMet,
                      "clicks=\(accuracy.clicks) zoomed=\(accuracy.zoomedClicks) settled=\(accuracy.settled) centered=\(accuracy.centeredClicks) arrival=\(String(format: "%.3f", accuracy.medianArrival))"),
                check("privacy_masked", privacyOK, privacyDetail),
                check("loudness", loudnessOK,
                      String(format: "%.1f LUFS, true peak %.2f dBTP", loudness, truePeak)),
                check("not_silent", silenceOK, String(format: "%.1f LUFS", loudness)),
                check("no_dropped_frames", droppedOK, "\(dropped) dropped"),
            ]),
            "zoom_accuracy": .object([
                "clicks": .int(accuracy.clicks),
                "zoomed_clicks": .int(accuracy.zoomedClicks),
                "settled": .int(accuracy.settled),
                "centered": .int(accuracy.centeredClicks),
                "median_arrival": .number(accuracy.medianArrival),
                "max_axis_center_error": .number(accuracy.maxAxisCenterError),
            ]),
        ])
    }

    // MARK: Export and scanning

    /// Starts an export as a job. Uses the existing exporter, unchanged.
    public func startExport(projectID: String, presetName: String, outputPath: String,
                            includeAudio: Bool, exportStems: Bool) async throws -> String {
        let h = try await requireHandle(projectID)
        guard let session = h.session else {
            throw ToolError.failed("This project cannot be opened for export (no Metal device).")
        }
        guard let preset = ExportPresets.parse(presetName) else {
            throw ToolError.invalidArguments("Unknown preset \(presetName). Use one of: "
                + ExportPresets.all.map(\.name).joined(separator: ", "))
        }
        let timeline = session.derive(h.timeline, revision: h.revision)
        // The export gate: never ship a video whose masks are unresolved.
        if timeline.overlays.privacy.enabled && timeline.overlays.privacy.autoDetect {
            switch h.privacy {
            case .scanned:
                let W = Double(h.meta.source.width), H = Double(h.meta.source.height)
                let unmasked = session.input.ocr.filter { d in
                    !covered(rect(d, W: W, H: H), by: maskRects(at: d.t, timeline: timeline))
                }
                if !unmasked.isEmpty {
                    throw ToolError(code: "PRIVACY_SCAN_PENDING",
                                    hint: "\(unmasked.count) sensitive detections are not masked yet. Run privacy_scan, review the masks, then export.")
                }
            case .scanning:
                // AGENT: exporting mid-scan shipped unmasked frames.
                throw ToolError(code: "PRIVACY_SCAN_RUNNING",
                                hint: "Wait for the privacy_scan job to finish (job_status), then retry.")
            case .notRequired, .notScanned, .failed:
                // AGENT: an unscanned project used to export because the detection list was empty.
                throw ToolError(code: "PRIVACY_SCAN_REQUIRED",
                                hint: "Run privacy_scan, then retry. Export refuses to run unscanned.")
            }
        }
        let output = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
        return jobs.start(kind: "export") { reporter in
            await MainActor.run { Renderer.primeWallpaper(Renderer.resolveWallpaperURL()) }
            try await Exporter.run(session: session, timeline: timeline, preset: preset, to: output,
                                   includeAudio: includeAudio, exportStems: exportStems) { progress in
                reporter.progress(progress.total > 0 ? Double(progress.frame) / Double(progress.total) : 0,
                                  progress.notice)
            }
            return .object(["output": .string(output.path)])
        }
    }

    /// Runs the existing privacy scan on a project as a job.
    public func startPrivacyScan(projectID: String) async throws -> String {
        let h = try await requireHandle(projectID)
        guard let session = h.session else {
            throw ToolError.failed("This project cannot be opened for scanning (no Metal device).")
        }
        let timeline = h.timeline
        // AGENT: record that a scan is in flight so export and QA stop guessing.
        handles[projectID]?.privacy = .scanning
        return jobs.start(kind: "privacy_scan") { [weak self] reporter in
            let result = await session.analyze(timeline,
                                               privacyProgress: { p in reporter.progress(p * 0.9, "Scanning") },
                                               onPrivacy: { error in reporter.progress(0.95, error) })
            let detections = result.ocr.count
            reporter.progress(1, nil)
            // AGENT: the completed scan is the only thing that can make privacy pass.
            if let error = result.errors["privacy"] {
                await self?.setPrivacy(.failed(error), for: projectID)
            } else {
                await self?.setPrivacy(.scanned(detections: detections), for: projectID)
            }
            return .object(["detections": .int(detections),
                            "errors": .object(result.errors.mapValues { .string($0) })])
        }
    }

    private func setPrivacy(_ state: PrivacyState, for projectID: String) {
        handles[projectID]?.privacy = state
    }

    /// AGENT: auto-masking means the scan must start on stop, not when the agent remembers.
    public func privacyAutoMasked(projectID: String) async throws -> Bool {
        let h = try await requireHandle(projectID)
        return h.timeline.overlays.privacy.enabled && h.timeline.overlays.privacy.autoDetect
    }

    private func rect(_ d: OCRDetection, W: Double, H: Double) -> CGRect {
        CGRect(x: d.x * W, y: d.y * H, width: d.w * W, height: d.h * H)
    }

    private func maskRects(at t: Double, timeline: Timeline) -> [CGRect] {
        var rects: [CGRect] = []
        for mask in timeline.derived?.autoMasks ?? [] {
            for key in mask.keys where abs(key.t - t) < 1.0 {
                rects.append(CGRect(x: key.x, y: key.y, width: key.w, height: key.h))
            }
        }
        return rects
    }

    /// AGENT: "covered" used to mean any 1 px overlap; require 90% containment.
    private func covered(_ d: CGRect, by masks: [CGRect]) -> Bool {
        guard d.width > 0, d.height > 0 else { return false }
        return masks.contains { m in
            let i = d.intersection(m)
            return !i.isNull && i.width * i.height >= 0.9 * d.width * d.height
        }
    }

    // MARK: Markers and caches

    /// The project's cache folder (voice clips, generated audio).
    public nonisolated func cacheDirectory(projectID: String) -> URL {
        let known = refs.withLock { $0.first { $0.identifier == projectID } }
        if let known { return known.url.appendingPathComponent("cache") }
        let library = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Lumen") ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent(projectID).appendingPathComponent("cache")
    }

    /// Records a marker on the running recording.
    public func addMarker(_ marker: CaptureMarker) async throws {
        try await runtime.addMarker(marker)
    }

    /// A marker sink that forwards to the runtime.
    public nonisolated func markerSink() -> MarkerSink {
        EngineMarkerSink(engine: self)
    }

    // MARK: Replanning

    /// Re-runs the automatic zoom planner over the recorded input.
    public func replanZoom(projectID: String) async throws -> [String: JSONValue] {
        let h = try await requireHandle(projectID)
        guard let session = h.session else {
            throw ToolError.failed("This project cannot be opened for replanning (no Metal device).")
        }
        let ax = (try? JSONDecoder().decode([AXFrame].self, from: Data(contentsOf: h.bundle.axURL))) ?? []
        let plan = Director.planRecordingZoom(events: session.input.events, ax: ax,
                                             source: h.meta.source, timeline: h.timeline)
        let result = try await edit(projectID: projectID, expectRevision: nil,
                                   describe: "automatic zoom replan") { timeline in
            timeline.zoom = plan
        }
        var payload = result
        payload["zoom_segments"] = .int(plan.count)
        return payload
    }

    /// Transcribes the microphone with the local speech model and turns
    /// captions on. Runs as a job.
    public func startTranscription(projectID: String, locale: String) async throws -> String {
        let h = try await requireHandle(projectID)
        guard let session = h.session else {
            throw ToolError.failed("This project cannot be opened for transcription (no Metal device).")
        }
        guard h.meta.mic != nil else {
            throw ToolError.failed("This recording has no microphone track to transcribe.")
        }
        let bundle = h.bundle
        let offset = session.micOffset
        let settings = h.timeline.audio
        return jobs.start(kind: "transcribe") { reporter in
            let voiceURL = try await cleanVoiceURL(for: bundle, settings: settings)
            let result = await FileTranscriber.run(url: voiceURL, size: .current) { p in
                reporter.progress(p, "Transcribing")
            }
            switch result {
            case .success(let transcript):
                try? bundle.saveTranscript(TranscriptFile(engine: "moonshine-streaming", complete: true,
                                                           transcript: transcript))
                let aligned = transcript.shifted(by: offset)
                _ = try? await self.edit(projectID: projectID, expectRevision: nil,
                                         describe: "captions") { timeline in
                    timeline.captions.enabled = true
                    if !locale.isEmpty { timeline.captions.locale = locale }
                }
                return .object(["words": .int(aligned.words.count), "locale": .string(aligned.locale)])
            case .failure(let failure):
                throw ToolError.failed(failure.description)
            }
        }
    }

    // MARK: Schema text

    /// The editable surface, published as an MCP resource.
    public static let timelineSchemaText = """
    {
      "zoom": [{ "id": "uuid", "start": 0.0, "end": 1.0, "scale": 2.0, "focus": { "mode": "follow|fixed|element", "x": 0, "y": 0, "w": 0, "h": 0 }, "origin": "manual|auto" }],
      "cuts": [{ "id": "uuid", "start": 0.0, "end": 1.0 }],
      "ramps": [{ "id": "uuid", "start": 0.0, "end": 1.0, "speed": 2.0, "origin": "manual|auto" }],
      "style": { "background": "dither|canvas|wallpaper|solid|gradient|mesh|wave|field|image", "padding": 0.025, "corner_radius": 14, "shadow": 0.45, "aspect": 1.777, "canvas": "r16x9|...", "wallpaper_blur": 0, "background_image_path": "/path.jpg" },
      "cursor": { "pack": "system|minimal|dot|ring|pro|holiday", "size": 1.0 },
      "audio": { "music_path": "/path.mp3", "music_gain_db": -18, "target_lufs": -16, "lanes": [{ "id": "uuid", "role": "mic|system|voiceover|music|sfx", "path": "/path.wav", "placement": 0.0, "gain_db": 0, "mute": false }] },
      "captions": { "enabled": false, "locale": "en-US" },
      "privacy": { "enabled": true, "auto_detect": true, "mode": "blur|pixelate|solid" }
    }
    All times are SOURCE seconds. Anchoring to a marker is preferred over magic seconds.
    """
}
