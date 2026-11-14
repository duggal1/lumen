import Foundation
import Darwin
import Metal
@preconcurrency import AVFoundation
import os
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
import LumenAnalysis

/// Where the recorded tracks are in their preparation. The editor opens before
/// this is `ready`; playback asks it before it lets the clock start.
public enum AudioPreparation: Sendable, Equatable {
    case idle
    case preparing
    case ready
    case failed(String)
}

/// An opened project: frame sources, Director inputs, audio mixer. Immutable after `open`; edits live in the Timeline value.
public final class ProjectSession: @unchecked Sendable {
    public let bundle: ProjectBundle
    public let meta: ProjectMeta
    public let screen: ReaderFrameSource
    public let webcam: (any FrameSource)?
    private let saveQueue = DispatchQueue(label: "lumen.project.save", qos: .userInitiated)
    // AGENT: editor saves must compare the last on-disk revision before replacing an agent's update.
    private let projectRevision: OSAllocatedUnfairLock<Int>
    private let saveConflictHandler = OSAllocatedUnfairLock<(@Sendable (Int, Int) -> Void)?>(initialState: nil)
    // AGENT: an open editor watches atomic project-file replacements to receive newer agent timelines.
    private let projectChangeHandler = OSAllocatedUnfairLock<(@Sendable (ProjectFile) -> Void)?>(initialState: nil)
    private var projectWatcher: DispatchSourceFileSystemObject?
    private let projectWatchQueue = DispatchQueue(label: "lumen.project.watch", qos: .utility)
    private let analysisSequence = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let inputState: OSAllocatedUnfairLock<DirectorInput>
    public var input: DirectorInput { inputState.withLock { $0 } }
    public var currentProjectRevision: Int { projectRevision.withLock { $0 } }
    public let mixer: AudioMixer
    public let transcriptFile: TranscriptFile?
    public let micOffset: Double
    /// The waveform is derived audio, not part of the project file: it is
    /// produced by the background preparation and published here when ready.
    /// `openEditor` returns before it exists, so every reader must accept an
    /// empty array (a not-yet-computed envelope draws as dust, never as zero).
    public var waveform: [Float] { audioState.withLock { $0.waveform } }
    public var audioPreparation: AudioPreparation { audioState.withLock { $0.state } }
    public let cursors: [CustomCursor]
    /// Shared across the project's decoder; imported clips open their own
    /// `ReaderFrameSource` lazily and keep it for the life of the session.
    private let device: SendableMetalDevice
    private let clipSources = OSAllocatedUnfairLock<[String: ReaderFrameSource]>(initialState: [:])
    private struct AudioState { var waveform: [Float] = []; var state: AudioPreparation = .idle }
    private let audioState = OSAllocatedUnfairLock(initialState: AudioState())
    private let audioTaskState = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    init(bundle: ProjectBundle, meta: ProjectMeta, revision: Int, screen: ReaderFrameSource, webcam: (any FrameSource)?, input: DirectorInput,
         mixer: AudioMixer, transcriptFile: TranscriptFile?, micOffset: Double, waveform: [Float], cursors: [CustomCursor], device: SendableMetalDevice) {
        self.bundle = bundle; self.meta = meta; self.screen = screen; self.webcam = webcam
        projectRevision = OSAllocatedUnfairLock(initialState: revision)
        inputState = OSAllocatedUnfairLock(initialState: input)
        self.mixer = mixer; self.transcriptFile = transcriptFile; self.micOffset = micOffset; self.cursors = cursors; self.device = device
        audioState.withLock { $0.waveform = waveform; $0.state = .ready }
        startProjectWatcher()
    }

    deinit { projectWatcher?.cancel() }

    private func startProjectWatcher() {
        let fd = Darwin.open(bundle.url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write,
                                                                queue: projectWatchQueue)
        source.setEventHandler { [weak self] in
            guard let session = self else { return }
            // AGENT: defer briefly so the atomic writer advances its in-memory revision before the watcher compares.
            session.projectWatchQueue.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak session] in
                session?.publishIfNewerProjectFile()
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        projectWatcher = source
    }

    private func publishIfNewerProjectFile() {
        guard let file = try? bundle.load(), let revision = file.revision,
              revision > currentProjectRevision else { return }
        projectChangeHandler.withLock { $0 }?(file)
    }

    /// One frame for an OUTPUT time. Recording times read the screen track at
    /// the source time the TimeMap resolves; imported clips read their own file.
    /// Preview and export both go through here so a clip and the recording
    /// cannot disagree about what is on screen at a given moment.
    public func frames(atOutput t: Double, timeline tl: Timeline) async throws -> (screen: SourceFrame, webcam: SourceFrame?) {
        if let (clip, time) = tl.clipSource(atOutput: t) {
            let source = try await clipSource(for: clip.url)
            return (try await source.frame(atSource: time), nil)
        }
        let s = tl.timeMap.source(atOutput: t)
        // SMOOTHNESS: the webcam and the screen are two independent readers.
        // Awaiting the webcam first delayed the screen decode by a full frame.
        async let web: SourceFrame? = {
            guard tl.webcam != nil, let w = webcam else { return nil }
            return try? await w.frame(atSource: s)
        }()
        let screenFrame = try await screen.frame(atSource: s)
        return (screenFrame, await web)
    }

    private func clipSource(for url: URL) async throws -> ReaderFrameSource {
        if let existing = clipSources.withLock({ $0[url.path] }) { return existing }
        let source = try await ReaderFrameSource(url: url, device: device)
        clipSources.withLock { $0[url.path] = source }
        return source
    }

    public func derive(_ tl: Timeline, revision: Int) -> Timeline { Director.derive(tl, input: input, revision: revision) }
    public func setSaveConflictHandler(_ handler: @escaping @Sendable (Int, Int) -> Void) {
        saveConflictHandler.withLock { $0 = handler }
    }
    // AGENT: an accepted disk timeline is applied on the main actor before its revision becomes the editor's save base.
    public func setProjectChangeHandler(_ handler: @escaping @Sendable (ProjectFile) -> Void) {
        projectChangeHandler.withLock { $0 = handler }
    }
    // AGENT: update the editor's compare-and-swap base after its in-memory timeline is replaced.
    public func adoptExternalRevision(_ revision: Int) {
        projectRevision.withLock { $0 = max($0, revision) }
    }
    public func save(_ tl: Timeline) {
        saveQueue.async { [self] in
            let expected = projectRevision.withLock { $0 }
            do {
                let revision = try bundle.save(ProjectFile(meta: meta, timeline: tl), expectingRevision: expected)
                projectRevision.withLock { $0 = revision }
            } catch ProjectError.conflict(let expected, let actual) {
                saveConflictHandler.withLock { $0 }?(expected, actual)
            } catch {
                // AGENT: failed saves are no longer allowed to overwrite a newer project revision.
            }
        }
    }
    // AGENT: one-shot CLI edits must perform the same revision compare-and-swap as background editor saves.
    public func saveImmediately(_ timeline: Timeline) throws {
        let expected = projectRevision.withLock { $0 }
        let revision = try bundle.save(ProjectFile(meta: meta, timeline: timeline), expectingRevision: expected)
        projectRevision.withLock { $0 = revision }
    }
    public func updateTranscript(_ transcript: Transcript) {
        inputState.withLock { $0.transcript = transcript }
    }

    @discardableResult
    public func analyze(_ timeline: Timeline, privacyProgress: @escaping @Sendable (Double) -> Void = { _ in },
                        onTyping: @escaping @Sendable () -> Void = {},
                        onActivity: @escaping @Sendable () -> Void = {},
                        onPrivacy: @escaping @Sendable (String?) -> Void = { _ in },
                        onPrivacyStart: @escaping @Sendable () -> Void = {}) async -> AnalysisResult {
        let sequence = analysisSequence.withLock { value in value += 1; return value }
        let origin = meta.clock.originHostSeconds
        let micOffset = (meta.mic?.startHostSeconds ?? origin) - origin
        let webcamOffset = (meta.webcam?.startHostSeconds ?? origin) - origin
        let snapshot = input
        var request = AnalysisRequest(screen: bundle.screenURL, webcam: meta.webcam == nil ? nil : bundle.webcamURL,
                                      mic: nil, cacheDirectory: bundle.cacheURL,
                                      webcamOffset: webcamOffset, micOffset: micOffset, projectSalt: meta.analysisSalt,
                                      privacy: timeline.overlays.privacy, locale: timeline.captions.locale,
                                      vocabulary: timeline.captions.vocabulary, // Caption recognition runs once with Moonshine after capture, not
                                       // concurrently with the UI's file transcriber.
                                       includeSpeech: false,
                                      includeActivity: timeline.camera.autoZoom && timeline.camera.preset != .fixed,
                                      includeFace: meta.webcam != nil,
                                      includePersonMask: timeline.layouts.contains { $0.kind == .cameraCutout }
                                          || (timeline.webcam?.backdrop != nil && timeline.webcam?.backdrop != .original),
                                      includeTyping: !snapshot.events.isEmpty,
                                      events: snapshot.events)
        request.ax = snapshot.ax
        request.sourceDuration = meta.source.duration
        request.privacyProgress = privacyProgress
        let result = await AnalysisService.shared.run(request, onTyping: { [self] result in
            guard !Task.isCancelled, analysisSequence.withLock({ $0 == sequence }), result.errors["typing"] == nil else { return }
            inputState.withLock { $0.typing = result.typing }
            onTyping()
        }, onPrivacy: { [self] result in
            // Privacy fails closed: whatever the scan found is published even
            // when the analysis was cancelled, because a cancelled scan still
            // knows about every secret it detected so far. Only a newer
            // analysis (a higher sequence) may discard it.
            guard analysisSequence.withLock({ $0 == sequence }) else { return }
            inputState.withLock { $0.ocr = result.ocr }
            onPrivacy(result.errors["ocr"])
        }, onPrivacyStart: {
            guard self.analysisSequence.withLock({ $0 == sequence }) else { return }
            onPrivacyStart()
        }, onActivity: { [self] result in
            guard !Task.isCancelled, analysisSequence.withLock({ $0 == sequence }) else { return }
            inputState.withLock { $0.activity = result.activity }
            onActivity()
        })
        guard !Task.isCancelled else { return result }
        let appliedRequest = request
        inputState.withLock { current in
            if result.errors["face"] == nil, meta.webcam != nil { current.face = result.face }
            if result.errors["activity"] == nil, appliedRequest.includeActivity { current.activity = result.activity }
            if timeline.overlays.privacy.enabled, timeline.overlays.privacy.autoDetect { current.ocr = result.ocr }
            if result.errors["speech"] == nil, let transcript = result.transcript { current.transcript = transcript }
            if result.errors["personMask"] == nil, let personMask = result.personMask { current.personMask = personMask }
            if result.errors["typing"] == nil, appliedRequest.includeTyping { current.typing = result.typing }
        }
        return result
    }

    /// Full open: every track is decoded and analysed before returning. Used by
    /// the CLI, the daemon and export, where a caller is about to render the
    /// whole program. The editor uses `openEditor`, which does not pay this.
    public static func open(_ b: ProjectBundle, device: MTLDevice) async throws -> (ProjectSession, Timeline) {
        let (session, timeline) = try await openEditor(b, device: device, prepareAudio: false)
        await session.prepareAudio()
        return (session, timeline)
    }

    /// Minimal open: the persisted project, the event log, the transcript and
    /// the frame readers. No audio track is decoded, no VAD runs, no envelope
    /// is computed and no neural pass starts. Everything audio-related is
    /// prepared incrementally by `prepareAudio`, which this function starts
    /// unless the caller asks to drive it (tests do).
    public static func openEditor(_ b: ProjectBundle, device: MTLDevice,
                                  prepareAudio shouldPrepare: Bool = true) async throws -> (ProjectSession, Timeline) {
        let file = try b.load(), meta = file.meta, origin = meta.clock.originHostSeconds
        let events = (try? b.events(origin: origin)) ?? []
        var ax = (try? JSONDecoder().decode([AXFrame].self, from: Data(contentsOf: b.axURL))) ?? []
        for i in ax.indices { if let time = ax[i].sampledAt { ax[i].sampledAt = time - origin } }
        let micOff = (meta.mic?.startHostSeconds ?? origin) - origin
        let sysOff = (meta.system?.startHostSeconds ?? origin) - origin
        let tf = b.loadTranscript()
        let sharedDevice = SendableMetalDevice(device)
        let screen = try await ReaderFrameSource(url: b.screenURL, device: sharedDevice)
        var web: (any FrameSource)?, aspect: Float = 16.0 / 9
        if let w = meta.webcam {
            let off = w.startHostSeconds - origin
            web = OffsetFrameSource(try await ReaderFrameSource(url: b.webcamURL, device: sharedDevice), offset: off)
            if let tr = try? await AVURLAsset(url: b.webcamURL).loadTracks(withMediaType: .video).first,
               let sz = try? await tr.load(.naturalSize), sz.height > 0 { aspect = Float(sz.width / sz.height) }
        }
        // VAD is empty until the background preparation publishes it. A derive
        // with no voice regions simply has no speed ramps yet; it is replanned
        // when the regions arrive.
        let input = DirectorInput(events: events, source: meta.source, vad: [], ax: ax, face: [],
                                  webcamAspect: aspect, transcript: tf?.transcript.shifted(by: micOff))
        // Declick windows are source-time; convert to mic-file time by micOff.
        let keyTimesInMicFile = events.filter { $0.kind == .keyDown }.map { $0.t - micOff }.filter { $0 >= 0 }
        let mixer = AudioMixer(micURL: meta.mic == nil ? nil : b.micURL, micOffset: micOff,
                               systemURL: meta.system == nil ? nil : b.systemURL, systemOffset: sysOff,
                               additionalMicrophones: meta.additionalMicrophones.compactMap { item in
                                   let url = b.url.appendingPathComponent(item.track.file)
                                   guard url.deletingLastPathComponent().standardizedFileURL == b.url.standardizedFileURL else { return nil }
                                   return RecordedMicrophoneSource(deviceName: item.deviceName, url: url,
                                                                   offset: item.track.startHostSeconds - origin)
                               },
                               cacheDir: b.cacheURL, keyTimes: keyTimesInMicFile)
        let s = ProjectSession(bundle: b, meta: meta, revision: file.revision ?? 0, screen: screen, webcam: web, input: input,
                               mixer: mixer, transcriptFile: tf, micOffset: micOff, waveform: [],
                               cursors: CursorLibrary.load(from: b.cursorsURL), device: sharedDevice)
        // A full open already paid for the audio, so the preparation has
        // nothing left to do; the editor path gets it in the background.
        s.audioState.withLock { $0.state = .idle }
        if shouldPrepare {
            s.audioTaskState.withLock { $0 = Task.detached(priority: .userInitiated) { await s.performAudioPreparation() } }
        }
        return (s, file.timeline)
    }

    /// Decodes and analyses the recorded tracks, then publishes the waveform,
    /// the VAD regions and the mixer's source samples. Single-flight and
    /// idempotent: warm reopening reuses the result instead of rescheduling it.
    /// Cancellation is cooperative, so a closed editor does not leave a decode
    /// or a denoiser running.
    public func prepareAudio(cancelled: (@Sendable () -> Bool)? = nil) async -> Bool {
        if audioPreparation == .ready { return true }
        if let running = audioTaskState.withLock({ $0 }) {
            await running.value
            return audioPreparation == .ready
        }
        let task = Task.detached(priority: .userInitiated) { [self] in
            await self.performAudioPreparation(cancelled: cancelled)
        }
        // A concurrent caller may have installed its own task in the meantime;
        // the loser's task sees `.preparing` and returns without doing work.
        let installed = audioTaskState.withLock { state -> Bool in
            guard state == nil else { return false }
            state = task
            return true
        }
        await task.value
        if installed { audioTaskState.withLock { $0 = nil } }
        return audioPreparation == .ready
    }

    private func performAudioPreparation(cancelled: (@Sendable () -> Bool)? = nil) async {
        guard audioPreparation == .idle else { return }
        audioState.withLock { $0.state = .preparing }
        let meta = self.meta, b = bundle, origin = meta.clock.originHostSeconds
        var micOff = micOffset, sysOff = 0.0
        var mic: [Float]?, sys: [Float]?, sysRight: [Float]?
        var extras: [RecordedMicrophone] = []
        if let m = meta.mic, cancelled?() != true {
            mic = try? AudioIO.readMono(b.micURL)
            micOff = m.startHostSeconds - origin
        }
        if let s = meta.system, cancelled?() != true {
            if let (left, right) = try? AudioIO.readStereo(b.systemURL) { sys = left; sysRight = right }
            sysOff = s.startHostSeconds - origin
        }
        // Older projects have no extra tracks. An unavailable/missing device
        // recording is skipped on reopen without losing the rest of the project.
        for item in meta.additionalMicrophones where cancelled?() != true {
            let url = b.url.appendingPathComponent(item.track.file)
            guard url.deletingLastPathComponent().standardizedFileURL == b.url.standardizedFileURL,
                  let samples = try? AudioIO.readMono(url), !samples.isEmpty else { continue }
            extras.append(RecordedMicrophone(deviceName: item.deviceName, samples: samples,
                                             offset: item.track.startHostSeconds - origin))
        }
        if cancelled?() == true {
            audioState.withLock { $0.state = .failed("Cancelled") }
            return
        }
        let primaryVAD = (mic.map { VAD.regions($0) } ?? [])
            .map { ($0.lowerBound + micOff) ... ($0.upperBound + micOff) }
        let secondaryVAD = extras.flatMap { track in
            VAD.regions(track.samples).map {
                ($0.lowerBound + track.offset) ... ($0.upperBound + track.offset)
            }
        }
        let vad = (primaryVAD + secondaryVAD).sorted { $0.lowerBound < $1.lowerBound }
        let wave = mic.map { Self.envelope($0, offset: micOff) } ?? []
        mixer.installAudio(mic: mic, system: sys, systemRight: sysRight, additionalMicrophones: extras)
        inputState.withLock { $0.vad = vad }
        audioState.withLock { $0.waveform = wave; $0.state = .ready }
    }

    private static func envelope(_ x: [Float], offset: Double) -> [Float] {
        let hop = 480, pre = max(Int(offset * 100), 0)
        var out = [Float](repeating: 0, count: pre + x.count / hop)
        for f in 0..<(x.count / hop) { var m: Float = 0; for i in 0..<hop { m = max(m, abs(x[f * hop + i])) }; out[pre + f] = min(m * 1.5, 1) }
        return out
    }

}
