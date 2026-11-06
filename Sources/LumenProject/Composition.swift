import Foundation
import LumenCore

/// A span of wall-clock time that was deliberately not recorded.
///
/// Paused spans are kept in SOURCE seconds (the same clock as the captured
/// screen track). On stop they become ordinary cuts, so every downstream stage
/// — Director, TimeMap, audio, export — reuses the cut machinery instead of
/// inventing a second timeline concept.
public struct PauseInterval: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double, end: Double
    public init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id; self.start = start; self.end = end
    }
    public var duration: Double { max(end - start, 0) }
}

/// An imported video placed after the recording on the shared output timeline.
///
/// The primary recording keeps using `TimeMap` (cuts, trims, speed ramps). An
/// imported clip is addressed in OUTPUT seconds and contributes `duration`
/// seconds of footage starting at `start`. This keeps one unambiguous timeline
/// and lets the renderer compose both with the same `FrameState`.
public struct TimelineClip: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var name: String
    /// Seconds into the imported file where this clip begins.
    public var inPoint: Double
    /// Seconds of the imported file used.
    public var duration: Double
    /// OUTPUT seconds where this clip begins.
    public var start: Double
    /// Pixel size of the imported file, probed once at import time.
    public var width: Int, height: Int
    public init(id: UUID = UUID(), path: String, name: String = "", inPoint: Double = 0,
                duration: Double, start: Double, width: Int = 1920, height: Int = 1080) {
        self.id = id; self.path = path; self.name = name
        self.inPoint = max(inPoint, 0); self.duration = max(duration, 0.01); self.start = max(start, 0)
        self.width = max(width, 2); self.height = max(height, 2)
    }
    public var end: Double { start + duration }
    public func contains(output t: Double) -> Bool { t >= start && t < end }
    /// Output seconds -> seconds inside the imported file.
    public func sourceTime(atOutput t: Double) -> Double { inPoint + max(min(t - start, duration), 0) }
    public var url: URL { URL(fileURLWithPath: path) }
}

/// Crash-recovery journal written while a recording is in progress. Kept tiny
/// and rewritten atomically so a crash at any point leaves a readable file.
public struct RecordingJournal: Codable, Sendable {
    public var schemaVersion = 1
    public var started: Date
    public var updated: Date
    public var source: SourceInfo
    public var fps: Double
    public var mic: Bool, system: Bool, webcam: Bool
    public var pauseIntervals: [PauseInterval]
    /// Engine seconds of the last frame accepted by the writer.
    public var lastFramePTS: Double
    public var firstFramePTS: Double?
    public var droppedFrames: Int
    public init(started: Date = Date(), updated: Date? = nil, source: SourceInfo, fps: Double, mic: Bool, system: Bool,
                webcam: Bool, pauseIntervals: [PauseInterval] = [], lastFramePTS: Double = 0,
                firstFramePTS: Double? = nil, droppedFrames: Int = 0) {
        self.started = started; self.updated = updated ?? started; self.source = source; self.fps = fps
        self.mic = mic; self.system = system; self.webcam = webcam
        self.pauseIntervals = pauseIntervals; self.lastFramePTS = lastFramePTS
        self.firstFramePTS = firstFramePTS; self.droppedFrames = droppedFrames
    }
}

public extension ProjectBundle {
    /// Present for the whole life of a recording and removed only after the
    /// project file is safely written. A leftover journal is the recovery signal.
    var journalURL: URL { url.appendingPathComponent("recording.journal") }
    var isUnfinished: Bool { FileManager.default.fileExists(atPath: journalURL.path) }

    func writeJournal(_ j: RecordingJournal) {
        guard let data = try? JSONEncoder().encode(j) else { return }
        try? data.write(to: journalURL, options: .atomic)
    }
    func readJournal() -> RecordingJournal? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        return try? JSONDecoder().decode(RecordingJournal.self, from: data)
    }
    func clearJournal() { try? FileManager.default.removeItem(at: journalURL) }

    /// Rebuilds a usable project from a crashed session. Returns nil when the
    /// bundle never produced a decodable frame record.
    @discardableResult
    func recoverFromJournal() throws -> ProjectFile? {
        guard let j = readJournal() else { return nil }
        let origin = j.firstFramePTS ?? 0
        let duration = max(j.lastFramePTS - origin, 0)
        guard duration > 0.1 else { return nil }
        var info = j.source
        info.duration = duration
        var meta = ProjectMeta(name: url.deletingPathExtension().lastPathComponent, source: info,
                               clock: RecordingClock(originHostSeconds: origin, eventUnit: .machTicks))
        meta.droppedFrames = j.droppedFrames
        if j.mic, FileManager.default.fileExists(atPath: micURL.path) { meta.mic = TrackMeta(file: "mic.caf", startHostSeconds: origin) }
        if j.system, FileManager.default.fileExists(atPath: systemURL.path) { meta.system = TrackMeta(file: "system.caf", startHostSeconds: origin) }
        if j.webcam, FileManager.default.fileExists(atPath: webcamURL.path) { meta.webcam = TrackMeta(file: "webcam.mov", startHostSeconds: origin) }
        if let prior = try? load() {
            meta = prior.meta
            meta.source.duration = duration
            meta.droppedFrames = j.droppedFrames
        }
        var tl = Timeline(duration: duration)
        // Paused spans carry no footage; replay them as cuts so recovered
        // projects match what a clean stop would have produced.
        let pauses = j.pauseIntervals.compactMap { p -> CutRange? in
            let a = max(p.start - origin, 0), b = min(p.end - origin, duration)
            return b > a ? CutRange(start: a, end: b, origin: .manual) : nil
        }
        tl.timeMap.cuts = (tl.timeMap.cuts + pauses).sorted { $0.start < $1.start }
        if meta.webcam != nil { tl.webcam = WebcamLayout() }
        let file = ProjectFile(meta: meta, timeline: tl)
        try save(file)
        clearJournal()
        return file
    }
}

public enum RecoveryScanner {
    /// All bundles in `library` that still have an unfinished journal.
    public static func scan(library: URL) -> [ProjectBundle] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "lumen" }.map(ProjectBundle.init(url:)).filter(\.isUnfinished)
    }
}
