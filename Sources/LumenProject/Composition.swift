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
///
/// Editing-layer rule: the magnetic main lane orders `clips` by OUTPUT `start`
/// and keeps them gapless. A split is a logical boundary inside a contiguous
/// source range, not a material edit — it never trims the underlying file and
/// never resets camera/cursor state.
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
        // NaN survives `max`, so reject non-finite geometry explicitly. One
        // bad imported clip must never poison the timeline's time map.
        self.inPoint = inPoint.isFinite ? max(inPoint, 0) : 0
        self.duration = duration.isFinite ? max(duration, 0.01) : 0.01
        self.start = start.isFinite ? max(start, 0) : 0
        self.width = max(width, 2); self.height = max(height, 2)
    }
    public var end: Double { start + duration }
    public func contains(output t: Double) -> Bool { t >= start && t < end }
    /// Output seconds -> seconds inside the imported file.
    public func sourceTime(atOutput t: Double) -> Double { inPoint + max(min(t - start, duration), 0) }
    public var url: URL { URL(fileURLWithPath: path) }

    /// Two clips are contiguous when the second starts exactly where the first
    /// ends, they share the same file, and their inPoints continue without a
    /// gap or overlap. Join only succeeds on this predicate.
    public func isContiguous(with other: TimelineClip) -> Bool {
        guard path == other.path else { return false }
        let eps = 0.001
        return abs(end - other.start) < eps && abs(other.inPoint - (inPoint + duration)) < eps
    }
}

extension Array where Element == TimelineClip {
    /// Magnetic normalize: sort by output start and close gaps by rippling
    /// later clips left so `clips[i].start == clips[i-1].end`.
    /// The first clip keeps its start (recording-end == after-recording
    /// annexed clips stay put; lane clips at 0 stay put).
    mutating func magneticNormalize() {
        // Keep sort stable w.r.t. insertion order for equal starts: Swift sort
        // is stable, so only the start value rewrites the order.
        sort { $0.start < $1.start }
        guard !isEmpty else { return }
        var cursor = self[0].start
        for i in indices {
            self[i].start = cursor
            cursor += self[i].duration
        }
    }

    /// Close gaps without re-sorting. Reordering is an explicit user decision
    /// about array order; sorting by the stale `start` values would silently
    /// undo it.
    mutating func magneticNormalizeInPlace(start laneStart: Double? = nil) {
        guard !isEmpty else { return }
        var cursor = laneStart ?? self[0].start
        for i in indices {
            self[i].start = cursor
            cursor += self[i].duration
        }
    }

    /// Snap a candidate start to the nearest clip edge when within `eps`.
    func snappedStart(_ start: Double, eps: Double = 0.05) -> Double {
        var best = start, bestDelta = eps
        for clip in self {
            for edge in [clip.start, clip.end] {
                let d = abs(edge - start)
                if d < bestDelta { bestDelta = d; best = edge }
            }
        }
        return best
    }
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
    /// Area-recording crop configuration in force while this take was captured.
    /// Absent on older journals (and on full-screen takes), so a crashed Area
    /// recording can rebuild the same intelligent crop instead of losing it.
    public var smartCrop: SmartCropConfig?
    enum CodingKeys: String, CodingKey {
        case schemaVersion, started, updated, source, fps, mic, system, webcam,
             pauseIntervals, lastFramePTS, firstFramePTS, droppedFrames, smartCrop
    }
    public init(started: Date = Date(), updated: Date? = nil, source: SourceInfo, fps: Double, mic: Bool, system: Bool,
                webcam: Bool, pauseIntervals: [PauseInterval] = [], lastFramePTS: Double = 0,
                firstFramePTS: Double? = nil, droppedFrames: Int = 0, smartCrop: SmartCropConfig? = nil) {
        self.started = started; self.updated = updated ?? started; self.source = source; self.fps = fps
        self.mic = mic; self.system = system; self.webcam = webcam
        self.pauseIntervals = pauseIntervals; self.lastFramePTS = lastFramePTS
        self.firstFramePTS = firstFramePTS; self.droppedFrames = droppedFrames
        self.smartCrop = smartCrop
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schemaVersion = c.opt(.schemaVersion, 1)
        let decodedStart = (try? c.decode(Date.self, forKey: .started)) ?? Date()
        started = decodedStart
        updated = (try? c.decode(Date.self, forKey: .updated)) ?? decodedStart
        source = try c.decode(SourceInfo.self, forKey: .source)
        fps = c.opt(.fps, 60)
        mic = c.opt(.mic, false); system = c.opt(.system, false); webcam = c.opt(.webcam, false)
        pauseIntervals = c.opt(.pauseIntervals, [])
        lastFramePTS = c.opt(.lastFramePTS, 0)
        firstFramePTS = try? c.decodeIfPresent(Double.self, forKey: .firstFramePTS)
        droppedFrames = c.opt(.droppedFrames, 0)
        // Backward compatible: journals written before smartCrop existed decode
        // to nil and recover exactly as they did before.
        smartCrop = try? c.decodeIfPresent(SmartCropConfig.self, forKey: .smartCrop)
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw RecoveryJournalError.unsupportedVersion(schemaVersion) }
        guard started.timeIntervalSince1970.isFinite, updated.timeIntervalSince1970.isFinite else {
            throw RecoveryJournalError.invalidValue("journal timestamps")
        }
        guard fps.isFinite, fps > 0, source.fps.isFinite, source.fps > 0,
              source.width > 0, source.height > 0, source.backingScale.isFinite,
              source.backingScale > 0, source.originX.isFinite, source.originY.isFinite,
              source.duration.isFinite else {
            throw RecoveryJournalError.invalidValue("capture format")
        }
        guard lastFramePTS.isFinite, lastFramePTS >= 0,
              firstFramePTS.map({ $0.isFinite && $0 >= 0 && $0 <= lastFramePTS }) ?? true,
              droppedFrames >= 0 else {
            throw RecoveryJournalError.invalidValue("frame checkpoint")
        }
        guard pauseIntervals.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }) else {
            throw RecoveryJournalError.invalidValue("pause intervals")
        }
        if let roi = smartCrop?.roi {
            guard roi.origin.x.isFinite, roi.origin.y.isFinite, roi.size.width.isFinite, roi.size.height.isFinite,
                  roi.size.width >= 0, roi.size.height >= 0 else {
                throw RecoveryJournalError.invalidValue("smart crop")
            }
        }
    }
}

public enum RecoveryJournalError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Recovery journal version \(version) is not supported."
        case .invalidValue(let field): "Recovery journal has invalid \(field)."
        }
    }
}

public extension ProjectBundle {
    /// Present for the whole life of a recording and removed only after the
    /// project file is safely written. A leftover journal is the recovery signal.
    var journalURL: URL { url.appendingPathComponent("recording.journal") }
    var isUnfinished: Bool { FileManager.default.fileExists(atPath: journalURL.path) }

    @discardableResult
    func writeJournal(_ j: RecordingJournal) -> Result<Void, Error> {
        Result {
            try j.validate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(j).write(to: journalURL, options: .atomic)
        }
    }
    func readJournal() throws -> RecordingJournal? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        let journal = try JSONDecoder().decode(RecordingJournal.self, from: Data(contentsOf: journalURL))
        try journal.validate()
        return journal
    }
    @discardableResult
    func clearJournal() -> Result<Void, Error> {
        Result {
            guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
            try FileManager.default.removeItem(at: journalURL)
        }
    }

    /// Rebuilds a usable project from a crashed session. Returns nil when the
    /// bundle has no journal or the checkpoint contains no usable frames.
    @discardableResult
    func recoverFromJournal() throws -> ProjectFile? {
        guard isUnfinished else { return nil }
        if let existing = try? load(), existing.meta.source.duration.isFinite,
           existing.meta.source.duration > 0 {
            try clearJournal().get()
            return existing
        }
        guard let j = try readJournal() else { return nil }
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
        var tl = Timeline(duration: duration)
        // An Area take must come back with the same intelligent crop it was
        // recording with, not a fresh full-frame timeline.
        tl.smartCrop = j.smartCrop ?? SmartCropConfig()
        // Paused spans carry no footage; replay them as cuts so recovered
        // projects match what a clean stop would have produced.
        let pauses = j.pauseIntervals.compactMap { p -> CutRange? in
            let a = max(p.start - origin, 0), b = min(p.end - origin, duration)
            return b > a ? CutRange(start: a, end: b, origin: .manual) : nil
        }
        tl.timeMap.cuts = (tl.timeMap.cuts + pauses).sorted { $0.start < $1.start }
        if meta.webcam != nil { tl.webcam = WebcamLayout() }
        guard meta.source.duration > 0, tl.timeMap.trimEnd > tl.timeMap.trimStart else { return nil }
        // F1: a crash can leave a partial viewport record; keep whole records only.
        ViewportLog.truncateToWholeRecords(at: url.appendingPathComponent("viewport.bin"))
        let file = ProjectFile(meta: meta, timeline: tl)
        try save(file)
        try clearJournal().get()
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

public extension ProjectBundle {
    /// Writes a self-contained `.lumenshare` package. Caches, analysis, and
    /// journals are left out; imported clips are copied inside and their paths
    /// become bundle-relative so the package works on another Mac.
    @discardableResult
    func exportSharePackage(to destination: URL) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("lumen-share-\(UUID().uuidString).lumen")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let keep = ["project.json", "screen.mov", "mic.caf", "system.caf", "webcam.mov",
                    "cursors.json", "events.bin", "ax.json", "frames.meta"]
        for name in keep {
            let source = url.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: staging.appendingPathComponent(name))
        }
        var file = try load()
        if !file.timeline.clips.isEmpty {
            let clips = staging.appendingPathComponent("clips", isDirectory: true)
            try fm.createDirectory(at: clips, withIntermediateDirectories: true)
            for i in file.timeline.clips.indices {
                let source = file.timeline.clips[i].url
                guard fm.fileExists(atPath: source.path) else { continue }
                let name = "\(file.timeline.clips[i].id.uuidString).\(source.pathExtension)"
                try fm.copyItem(at: source, to: clips.appendingPathComponent(name))
                file.timeline.clips[i].path = "clips/" + name
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: staging.appendingPathComponent("project.json"), options: .atomic)

        let zip = destination
        try? fm.removeItem(at: zip)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, zip.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return zip
    }

    /// Expands a `.lumenshare` package into the library and returns the local
    /// bundle. Names are uniqued so importing twice never overwrites work.
    static func installSharePackage(_ package: URL, into library: URL) throws -> ProjectBundle {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("lumen-unpack-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", package.path, temp.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        let unpacked = (try fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil))
            .first { $0.pathExtension == "lumen" }
            ?? temp.appendingPathComponent(package.deletingPathExtension().lastPathComponent)
        var name = unpacked.deletingPathExtension().lastPathComponent
        var destination = library.appendingPathComponent(name).appendingPathExtension("lumen")
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = library.appendingPathComponent("\(name) \(n)").appendingPathExtension("lumen")
            n += 1
        }
        try fm.copyItem(at: unpacked, to: destination)
        return ProjectBundle(url: destination)
    }

    /// A link other Lumen installs on this Mac can open directly.
    var shareLink: String {
        var components = URLComponents()
        components.scheme = "lumen"; components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        return components.string ?? url.absoluteString
    }
}
