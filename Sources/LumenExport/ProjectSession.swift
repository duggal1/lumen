import Foundation
import Metal
@preconcurrency import AVFoundation
import os
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
import LumenAnalysis

/// An opened project: frame sources, Director inputs, audio mixer. Immutable after `open`; edits live in the Timeline value.
public final class ProjectSession: @unchecked Sendable {
    public let bundle: ProjectBundle
    public let meta: ProjectMeta
    public let screen: ReaderFrameSource
    public let webcam: (any FrameSource)?
    private let inputState: OSAllocatedUnfairLock<DirectorInput>
    public var input: DirectorInput { inputState.withLock { $0 } }
    public let mixer: AudioMixer
    public let waveform: [Float]                 // 100 Hz peaks in SOURCE time, 0...1
    public let cursors: [CustomCursor]
    init(bundle: ProjectBundle, meta: ProjectMeta, screen: ReaderFrameSource, webcam: (any FrameSource)?, input: DirectorInput,
         mixer: AudioMixer, waveform: [Float], cursors: [CustomCursor]) {
        self.bundle = bundle; self.meta = meta; self.screen = screen; self.webcam = webcam
        inputState = OSAllocatedUnfairLock(initialState: input)
        self.mixer = mixer; self.waveform = waveform; self.cursors = cursors
    }

    public func derive(_ tl: Timeline, revision: Int) -> Timeline { Director.derive(tl, input: input, revision: revision) }
    public func save(_ tl: Timeline) { try? bundle.save(ProjectFile(meta: meta, timeline: tl)) }

    @discardableResult
    public func analyze(_ timeline: Timeline) async -> AnalysisResult {
        let origin = meta.clock.originHostSeconds
        let micOffset = (meta.mic?.startHostSeconds ?? origin) - origin
        let webcamOffset = (meta.webcam?.startHostSeconds ?? origin) - origin
        let snapshot = input
        let request = AnalysisRequest(screen: bundle.screenURL, webcam: meta.webcam == nil ? nil : bundle.webcamURL,
                                      mic: meta.mic == nil ? nil : bundle.micURL, cacheDirectory: bundle.cacheURL,
                                      webcamOffset: webcamOffset, micOffset: micOffset, projectSalt: meta.analysisSalt,
                                      privacy: timeline.overlays.privacy, locale: timeline.captions.locale,
                                      vocabulary: timeline.captions.vocabulary, includeSpeech: timeline.captions.enabled,
                                      includeActivity: !snapshot.events.contains(where: \.hasPosition),
                                      includeFace: meta.webcam != nil,
                                      includePersonMask: timeline.layouts.contains { $0.kind == .cameraCutout })
        let result = await AnalysisService.shared.run(request)
        guard !Task.isCancelled else { return result }
        inputState.withLock { current in
            if result.errors["face"] == nil, meta.webcam != nil { current.face = result.face }
            if result.errors["activity"] == nil, request.includeActivity { current.activity = result.activity }
            if result.errors["ocr"] == nil, timeline.overlays.privacy.enabled, timeline.overlays.privacy.autoDetect { current.ocr = result.ocr }
            if result.errors["speech"] == nil, let transcript = result.transcript { current.transcript = transcript }
            if result.errors["personMask"] == nil, let personMask = result.personMask { current.personMask = personMask }
        }
        return result
    }

    public static func open(_ b: ProjectBundle, device: MTLDevice) async throws -> (ProjectSession, Timeline) {
        let file = try b.load(), meta = file.meta, origin = meta.clock.originHostSeconds
        let events = (try? b.events(origin: origin)) ?? []
        let ax = (try? JSONDecoder().decode([AXFrame].self, from: Data(contentsOf: b.axURL))) ?? []
        var mic: [Float]?, sys: [Float]?, micOff = 0.0, sysOff = 0.0
        if let m = meta.mic { mic = try? AudioIO.readMono(b.micURL); micOff = m.startHostSeconds - origin }
        if let s = meta.system { sys = try? AudioIO.readMono(b.systemURL); sysOff = s.startHostSeconds - origin }
        let vad = (mic.map { VAD.regions($0) } ?? []).map { ($0.lowerBound + micOff) ... ($0.upperBound + micOff) }
        let wave = mic.map { envelope($0, offset: micOff) } ?? []
        let sharedDevice = SendableMetalDevice(device)
        let screen = try await ReaderFrameSource(url: b.screenURL, device: sharedDevice)
        var web: (any FrameSource)?, aspect: Float = 16.0 / 9
        if let w = meta.webcam {
            let off = w.startHostSeconds - origin
            web = OffsetFrameSource(try await ReaderFrameSource(url: b.webcamURL, device: sharedDevice), offset: off)
            if let tr = try? await AVURLAsset(url: b.webcamURL).loadTracks(withMediaType: .video).first,
               let sz = try? await tr.load(.naturalSize), sz.height > 0 { aspect = Float(sz.width / sz.height) }
        }
        let input = DirectorInput(events: events, source: meta.source, vad: vad, ax: ax, face: [], webcamAspect: aspect)
        let s = ProjectSession(bundle: b, meta: meta, screen: screen, webcam: web, input: input,
                               mixer: AudioMixer(mic: mic, micOffset: micOff, system: sys, systemOffset: sysOff),
                               waveform: wave, cursors: CursorLibrary.load(from: b.cursorsURL))
        return (s, file.timeline)
    }

    private static func envelope(_ x: [Float], offset: Double) -> [Float] {
        let hop = 480, pre = max(Int(offset * 100), 0)
        var out = [Float](repeating: 0, count: pre + x.count / hop)
        for f in 0..<(x.count / hop) { var m: Float = 0; for i in 0..<hop { m = max(m, abs(x[f * hop + i])) }; out[pre + f] = min(m * 1.5, 1) }
        return out
    }

}
