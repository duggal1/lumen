import Foundation
import Metal
import AVFoundation
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio

/// An opened project: frame sources, Director inputs, audio mixer. Immutable after `open`; edits live in the Timeline value.
public final class ProjectSession: @unchecked Sendable {
    public let bundle: ProjectBundle
    public let meta: ProjectMeta
    public let screen: ReaderFrameSource
    public let webcam: (any FrameSource)?
    public let input: DirectorInput
    public let mixer: AudioMixer
    public let waveform: [Float]                 // 100 Hz peaks in SOURCE time, 0...1
    public let cursors: [CustomCursor]
    init(bundle: ProjectBundle, meta: ProjectMeta, screen: ReaderFrameSource, webcam: (any FrameSource)?, input: DirectorInput,
         mixer: AudioMixer, waveform: [Float], cursors: [CustomCursor]) {
        self.bundle = bundle; self.meta = meta; self.screen = screen; self.webcam = webcam; self.input = input
        self.mixer = mixer; self.waveform = waveform; self.cursors = cursors
    }

    public func derive(_ tl: Timeline, revision: Int) -> Timeline { Director.derive(tl, input: input, revision: revision) }
    public func save(_ tl: Timeline) { try? bundle.save(ProjectFile(meta: meta, timeline: tl)) }

    public static func open(_ b: ProjectBundle, device: MTLDevice) async throws -> (ProjectSession, Timeline) {
        let file = try b.load(), meta = file.meta, origin = meta.clock.originHostSeconds
        let events = (try? b.events(origin: origin)) ?? []
        let ax = (try? JSONDecoder().decode([AXFrame].self, from: Data(contentsOf: b.axURL))) ?? []
        var mic: [Float]?, sys: [Float]?, micOff = 0.0, sysOff = 0.0
        if let m = meta.mic { mic = try? AudioIO.readMono(b.micURL); micOff = m.startHostSeconds - origin }
        if let s = meta.system { sys = try? AudioIO.readMono(b.systemURL); sysOff = s.startHostSeconds - origin }
        let vad = (mic.map { VAD.regions($0) } ?? []).map { ($0.lowerBound + micOff) ... ($0.upperBound + micOff) }
        let wave = mic.map { envelope($0, offset: micOff) } ?? []
        let screen = try await ReaderFrameSource(url: b.screenURL, device: device)
        var web: (any FrameSource)?, face: [FaceSample] = [], aspect: Float = 16.0 / 9
        if let w = meta.webcam {
            let off = w.startHostSeconds - origin
            web = OffsetFrameSource(try await ReaderFrameSource(url: b.webcamURL, device: device), offset: off)
            if let tr = try? await AVURLAsset(url: b.webcamURL).loadTracks(withMediaType: .video).first,
               let sz = try? await tr.load(.naturalSize), sz.height > 0 { aspect = Float(sz.width / sz.height) }
            face = await faces(b, offset: off)
        }
        let input = DirectorInput(events: events, source: meta.source, vad: vad, ax: ax, face: face, webcamAspect: aspect)
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

    /// face.json cache (rows of [t, cx, cy, h]); rebuilt if missing.
    private static func faces(_ b: ProjectBundle, offset: Double) async -> [FaceSample] {
        let url = b.cacheURL.appendingPathComponent("face.json")
        if let d = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([[Double]].self, from: d) {
            return rows.map { FaceSample(t: $0[0], cx: Float($0[1]), cy: Float($0[2]), h: Float($0[3])) }
        }
        let f = (try? await FaceAnalyzer.analyze(url: b.webcamURL, startOffset: offset)) ?? []
        try? JSONEncoder().encode(f.map { [$0.t, Double($0.cx), Double($0.cy), Double($0.h)] }).write(to: url)
        return f
    }
}