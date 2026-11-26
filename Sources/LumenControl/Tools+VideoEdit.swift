import Foundation
import CoreGraphics
import ImageIO
import LumenCore
import LumenProject

// MARK: - Shared input

/// One flat, partially-decodable argument object for the video-edit verbs.
/// The *published* schemas stay precise per tool; this shared carrier keeps the
/// registry surface identical to every other tool in the app.
public struct VideoEditInput: ToolInput {
    public var projectID = ""
    public var revision: Int?
    public var start: Double?
    public var end: Double?
    public var at: Double?
    public var duration: Double?
    public var basis: String?
    public var clipID: String?
    public var orderedIDs: [String]?
    public var toIndex: Int?
    public var speed: Double?
    public var path: String?
    public var gainDb: Double?
    public var text: String?
    public var id: String?
    public var scale: Double?
    public var focusMode: String?
    public var focusX: Double?
    public var focusY: Double?
    public var time: Double?
    public var maxWidth: Int?
    public var png: Bool?
    public var frames: Int?
    public var output: String?
    public var preset: String?
    public var includeAudio: Bool?
    public var exportStems: Bool?
    public var wait: Bool?
    public var overwrite: Bool?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id", revision, start, end, at, duration, basis
        case clipID = "clip_id", orderedIDs = "ordered_ids", toIndex = "to_index"
        case speed, path, gainDb = "gain_db", text, id, scale
        case focusMode = "focus_mode", focusX = "focus_x", focusY = "focus_y"
        case time, maxWidth = "max_width", png, frames, output, preset
        case includeAudio = "include_audio", exportStems = "export_stems", wait, overwrite
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        start = try c.decodeIfPresent(Double.self, forKey: .start)
        end = try c.decodeIfPresent(Double.self, forKey: .end)
        at = try c.decodeIfPresent(Double.self, forKey: .at)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        basis = try c.decodeIfPresent(String.self, forKey: .basis)
        clipID = try c.decodeIfPresent(String.self, forKey: .clipID)
        orderedIDs = try c.decodeIfPresent([String].self, forKey: .orderedIDs)
        toIndex = try c.decodeIfPresent(Int.self, forKey: .toIndex)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        gainDb = try c.decodeIfPresent(Double.self, forKey: .gainDb)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale)
        focusMode = try c.decodeIfPresent(String.self, forKey: .focusMode)
        focusX = try c.decodeIfPresent(Double.self, forKey: .focusX)
        focusY = try c.decodeIfPresent(Double.self, forKey: .focusY)
        time = try c.decodeIfPresent(Double.self, forKey: .time)
        maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth)
        png = try c.decodeIfPresent(Bool.self, forKey: .png)
        frames = try c.decodeIfPresent(Int.self, forKey: .frames)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        includeAudio = try c.decodeIfPresent(Bool.self, forKey: .includeAudio)
        exportStems = try c.decodeIfPresent(Bool.self, forKey: .exportStems)
        wait = try c.decodeIfPresent(Bool.self, forKey: .wait)
        overwrite = try c.decodeIfPresent(Bool.self, forKey: .overwrite)
    }
}

// MARK: - Schemas (declared here: ToolSchemas.swift is outside M2's file scope)

private enum VideoEditSchemas {
    static let projectID = J.str("Project id returned by project_open, project_list or record_stop.")
    static let basis = J.str("Clock for the supplied times.", enum: ["source", "output"], def: "source")
    static let time = J.num("Time in seconds on the chosen basis.", min: 0)
    static let outputTime = J.num("Output-clock time in seconds after cuts and ramps.", min: 0)

    static func input(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var props = properties
        props["project_id"] = projectID
        return J.obj(props, required: ["project_id"] + required)
    }

    static let editResult = J.obj([
        "project_id": projectID,
        "revision": J.int("Revision after the edit.", min: 0),
        "changed": J.bool("False when the edit was already applied (idempotent no-op)."),
        "dry_run": J.bool("Present and true when dry_run was requested."),
        "summary": J.str("Human-readable name of the edit."),
        "diff": J.arr(.object(["type": .string("array")]), "Field-level before/after changes."),
        "before": .object(["type": .string("object")]),
        "after": .object(["type": .string("object")]),
        "warnings": J.arr(J.str("Validation warning."), "Warnings."),
    ], required: ["project_id", "revision", "changed", "diff", "before", "after"])

    static let readback = J.obj([
        "project_id": projectID,
        "revision": J.int("Persisted revision.", min: 0),
        "duration": J.num("Edited output duration in seconds.", min: 0),
        "output_duration": J.num("Recording duration after cuts and ramps, in output seconds.", min: 0),
        "clips": J.arr(.object(["type": .string("object")]), "Ordered main-lane clips."),
        "cuts": J.arr(.object(["type": .string("object")]), "Removed source ranges."),
        "ramps": J.arr(.object(["type": .string("object")]), "Speed ramps."),
        "zoom": J.arr(.object(["type": .string("object")]), "Zoom segments."),
        "texts": J.arr(.object(["type": .string("object")]), "Caption and title text blocks."),
        "audio_lanes": J.arr(.object(["type": .string("object")]), "Imported audio clips, source trims and output placement."),
        "music_path": .object(["type": .array([.string("string"), .string("null")])]),
        "music_gain_db": J.num("Music trim in dB."),
        "timeline": .object(["type": .string("object")]),
    ], required: ["project_id", "revision", "duration", "output_duration", "clips", "cuts", "ramps", "zoom", "texts", "music_path"])

    static let preview = J.obj([
        "image_base64": J.str("Encoded preview pixels."),
        "mime_type": J.str("MIME type of the encoded image."),
        "name": J.str("Suggested file name."),
        "time": J.num("Output time that was rendered.", min: 0),
        "frames": J.int("Number of frames in the sheet.", min: 1),
        "width": J.int("Decoded pixel width.", min: 0),
        "height": J.int("Decoded pixel height.", min: 0),
    ], required: ["image_base64", "mime_type", "time"])

    static let export = J.obj([
        "job_id": J.str("Poll this with job_status when wait is false."),
        "output": J.str("Absolute path of the exported movie."),
        "result": .object(["type": .array([.string("object"), .string("null")])]),
    ], required: ["job_id", "output"])
}

// MARK: - Validation and read-back helpers

private func need<T>(_ value: T?, _ name: String) throws -> T {
    guard let value else { throw ToolError.invalidArguments("This tool needs \(name).") }
    return value
}

private func finite(_ value: Double, _ name: String, _ range: ClosedRange<Double>) throws -> Double {
    guard value.isFinite, range.contains(value) else {
        throw ToolError.invalidArguments("\(name) must be finite and in \(range.lowerBound)…\(range.upperBound).")
    }
    return value
}

private func uuid(_ raw: String?, _ name: String) throws -> UUID {
    let text = try need(raw, name)
    guard let value = UUID(uuidString: text) else {
        throw ToolError.invalidArguments("\(name) must be a UUID.")
    }
    return value
}

private func clock(_ raw: String?, fallback: String) throws -> String {
    let value = raw ?? fallback
    guard value == "source" || value == "output" else {
        throw ToolError.invalidArguments("basis must be \"source\" or \"output\".")
    }
    return value
}

private func zoomFocus(_ input: VideoEditInput) throws -> Focus? {
    guard input.focusMode != nil || input.focusX != nil || input.focusY != nil else { return nil }
    let mode = input.focusMode ?? "follow"
    guard ["follow", "fixed", "element"].contains(mode) else {
        throw ToolError.invalidArguments("focus_mode must be follow, fixed or element.")
    }
    let x = try finite(input.focusX ?? 0.5, "focus_x", 0...1)
    let y = try finite(input.focusY ?? 0.5, "focus_y", 0...1)
    switch mode {
    case "fixed": return .fixed(x: x, y: y)
    case "element": return .element(x: x, y: y, w: 0, h: 0)
    default:
        guard input.focusX == nil, input.focusY == nil else {
            throw ToolError.invalidArguments("Specify focus_mode fixed or element when changing focus coordinates.")
        }
        return .follow
    }
}

private func videoEditFields(_ timeline: Timeline) -> [String: JSONValue] {
    var fields: [String: JSONValue] = [
        "duration": .number(timeline.compositionDuration),
        "output_duration": .number(timeline.timeMap.outputDuration),
        "clips": .array(timeline.clips.map { clip in
            .object(["id": .string(clip.id.uuidString), "name": .string(clip.name),
                     "path": .string(clip.path), "in_point": .number(clip.inPoint),
                     "start": .number(clip.start), "duration": .number(clip.duration)])
        }),
        "cuts": .array(timeline.timeMap.cuts.map {
            .object(["id": .string($0.id.uuidString), "start": .number($0.start), "end": .number($0.end)])
        }),
        "ramps": .array(timeline.timeMap.ramps.map {
            .object(["id": .string($0.id.uuidString), "start": .number($0.start),
                     "end": .number($0.end), "speed": .number($0.speed)])
        }),
        "zoom": .array(timeline.zoom.map { segment in
            let mode: String
            switch segment.focus {
            case .follow: mode = "follow"
            case .fixed: mode = "fixed"
            case .element: mode = "element"
            }
            return .object(["id": .string(segment.id.uuidString), "start": .number(segment.start),
                            "end": .number(segment.end), "scale": .number(segment.scale),
                            "focus_mode": .string(mode), "origin": .string(segment.origin == .auto ? "auto" : "manual")])
        }),
        "texts": .array(timeline.overlays.texts.map {
            .object(["id": .string($0.id.uuidString), "text": .string($0.text),
                     "start": .number($0.start), "end": .number($0.end)])
        }),
        "audio_lanes": .array(timeline.audio.lanes.map { lane in
            .object(["id": .string(lane.id.uuidString), "role": .string(lane.role.rawValue),
                     "path": lane.path.map { .string($0) } ?? .null, "placement": .number(lane.placement),
                     "trim_start": lane.trimStart.map { .number($0) } ?? .null,
                     "trim_duration": lane.trimDuration.map { .number($0) } ?? .null,
                     "gain_db": .number(lane.gainDb), "mute": .bool(lane.mute),
                     "loops": .bool(lane.loops ?? (lane.role == .music))])
        }),
        "music_path": timeline.audio.musicPath.map { JSONValue.string($0) } ?? .null,
        "music_gain_db": .number(timeline.audio.musicGainDb),
    ]
    return fields
}

/// A Sendable cell so a @Sendable edit closure can report the state it saw.
private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBefore: JSONValue = .null
    private var storedAfter: JSONValue = .null
    var before: JSONValue { lock.withLock { storedBefore } }
    var after: JSONValue { lock.withLock { storedAfter } }

    func capture(_ timeline: Timeline, before: Bool) {
        let value = JSONValue.object(videoEditFields(timeline))
        lock.withLock { if before { storedBefore = value } else { storedAfter = value } }
    }
}

/// Every edit — real or dry run — goes through the one engine edit path.
private func videoEdit(
    input: VideoEditInput, ctx: ToolContext, describe: String,
    body: @escaping @Sendable (inout Timeline) throws -> Void
) async throws -> JSONValue {
    let box = SnapshotBox()
    let apply: @Sendable (inout Timeline) throws -> Void = { timeline in
        box.capture(timeline, before: true)
        try body(&timeline)
        box.capture(timeline, before: false)
    }
    let result: [String: JSONValue]
    if ctx.dryRun {
        result = try await ctx.engine.previewEdit(projectID: input.projectID,
                                                  expectRevision: input.revision, apply)
    } else {
        result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: input.revision,
                                           describe: describe, apply)
    }
    var payload = result
    payload["before"] = box.before
    payload["after"] = box.after
    return .object(payload)
}

private func previewImageSize(_ data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return (image.width, image.height)
}

// MARK: - Registration

public extension ToolRegistry {
    /// Registers the typed video-edit verbs. Call from `registerAllTools(in:)`.
    func registerVideoEditTools() {
        registerVideoEditTimelineTools()
        registerVideoEditMediaTools()
        registerAgentAudioTransactions()
        registerVideoEditOutputTools()
    }

    // MARK: Timeline

    private func registerVideoEditTimelineTools() {
        register(ToolDefinition<VideoEditInput>(name: "cut_span",
            description: "Removes a span from the recording. Use basis source for raw recording seconds or output for edited seconds. Returns the cut id and before/after state.",
            capability: .edit, required: ["project_id", "start", "end"], mutating: true,
            schema: VideoEditSchemas.input(["start": VideoEditSchemas.time, "end": VideoEditSchemas.time,
                                            "basis": VideoEditSchemas.basis, "revision": J.int("Expected revision.", min: 0)],
                                           required: ["start", "end"]),
            destructive: true, outputSchema: VideoEditSchemas.editResult, customDryRun: true) { input, ctx in
            try await videoEdit(input: input, ctx: ctx, describe: "cut span") { timeline in
                let basis = try clock(input.basis, fallback: "source")
                let start = try timeline.sourceSeconds(TimeRef.legacy(seconds: need(input.start, "start"), basis: basis))
                let end = try timeline.sourceSeconds(TimeRef.legacy(seconds: need(input.end, "end"), basis: basis))
                let a = timeline.timeMap.output(atSource: start)
                let b = timeline.timeMap.output(atSource: end)
                guard b > a else { throw ToolError.invalidArguments("Cut end must be after start in the edited timeline.") }
                try applyCommand(.cutOutputRange(start: a, end: b), to: &timeline)
            }
        })

        register(ToolDefinition<VideoEditInput>(name: "split_clip",
            description: "Splits the clip under an output time into two contiguous clips. Never changes the underlying media or the programme duration.",
            capability: .edit, required: ["project_id", "at"], mutating: true,
            schema: VideoEditSchemas.input(["at": VideoEditSchemas.outputTime,
                                            "revision": J.int("Expected revision.", min: 0)], required: ["at"]),
            outputSchema: VideoEditSchemas.editResult, customDryRun: true) { input, ctx in
            try await videoEdit(input: input, ctx: ctx, describe: "split clip") { timeline in
                // Splitting an imported clip happens past the recording's own
                // output duration, so validate against the composition, not the
                // recording time map.
                let at = try finite(need(input.at ?? input.start, "at"), "at", 0...timeline.compositionDuration)
                try applyCommand(.splitClip(atOutput: at), to: &timeline)
            }
        })

        register(ToolDefinition<VideoEditInput>(name: "trim_clip",
            description: "Moves one or both edges of a clip in output time. Omitted edges stay put; trimming to the current edges is a no-op.",
            capability: .edit, required: ["project_id", "clip_id"], mutating: true,
            schema: VideoEditSchemas.input(["clip_id": J.str("Clip UUID from get_edit."),
                                            "start": VideoEditSchemas.outputTime, "end": VideoEditSchemas.outputTime,
                                            "revision": J.int("Expected revision.", min: 0)], required: ["clip_id"]),
            idempotent: true, outputSchema: VideoEditSchemas.editResult, customDryRun: true) { input, ctx in
            try await videoEdit(input: input, ctx: ctx, describe: "trim clip") { timeline in
                let id = try uuid(input.clipID, "clip_id")
                guard var clip = timeline.clips.first(where: { $0.id == id }) else {
                    throw ToolError.failed("No clip with id \(id.uuidString).")
                }
                guard input.start != nil || input.end != nil else {
                    throw ToolError.invalidArguments("trim_clip needs start, end or both.")
                }
                let eps = 0.001
                if let start = input.start {
                    let edge = try finite(start, "start", 0...timeline.compositionDuration)
                    guard edge >= clip.start - eps, edge < clip.end - 0.02 else {
                        throw ToolError.invalidArguments("start must sit inside this clip, one frame from its end.")
                    }
                    // The edge reducer advances the source in-point but leaves
                    // the timeline start in place, so place the visible left
                    // edge explicitly. Both are no-ops when already at edge.
                    if abs(edge - clip.start) > eps {
                        guard clip.inPoint + (edge - clip.start) >= 0 else {
                            throw ToolError.invalidArguments("There is no more source before this clip.")
                        }
                        try applyCommand(.trimClipEdge(id: id, isStart: true, toOutput: edge), to: &timeline)
                        try applyCommand(.moveClip(id, start: edge), to: &timeline)
                        clip = try Self.clip(id, in: timeline)
                    }
                }
                if let end = input.end {
                    let edge = try finite(end, "end", 0...timeline.compositionDuration)
                    guard edge > clip.start + 0.02, edge <= clip.end + eps else {
                        throw ToolError.invalidArguments("end must sit inside this clip, one frame from its start.")
                    }
                    if abs(edge - clip.end) > eps {
                        try applyCommand(.trimClipEdge(id: id, isStart: false, toOutput: edge), to: &timeline)
                    }
                }
            }
        })

        register(ToolDefinition<VideoEditInput>(name: "reorder_clips",
            description: "Reorders the main video lane. Pass ordered_ids with every clip id exactly once, or clip_id plus to_index for a single move.",
            capability: .edit, required: ["project_id"], mutating: true,
            schema: VideoEditSchemas.input([
                "ordered_ids": J.arr(J.str("Clip UUID."), "Complete desired order.", minItems: 1),
                "clip_id": J.str("Clip UUID to move."),
                "to_index": J.int("Destination index.", min: 0),
                "revision": J.int("Expected revision.", min: 0),
            ]),
            idempotent: true, outputSchema: VideoEditSchemas.editResult, customDryRun: true) { input, ctx in
            try await videoEdit(input: input, ctx: ctx, describe: "reorder clips") { timeline in
                let ids = try need(input.orderedIDs, "ordered_ids")
                guard ids.count == timeline.clips.count, Set(ids).count == ids.count else {
                    throw ToolError.invalidArguments("ordered_ids must list every clip exactly once.")
                }
                let existing = Set(timeline.clips.map(\.id.uuidString))
                guard Set(ids).isSubset(of: existing) else {
                    throw ToolError.invalidArguments("ordered_ids contains an unknown clip id.")
                }
                let ordered = try ids.map { try uuid($0, "ordered_ids") }
                for (index, id) in ordered.enumerated() {
                    guard let current = timeline.clips.firstIndex(where: { $0.id == id }) else {
                        throw ToolError.failed("Clip disappeared while reordering.")
                    }
                    if current != index {
                        try applyCommand(.reorderClip(id: id, toIndex: index), to: &timeline)
                    }
                }
            }
        })

        register(ToolDefinition<VideoEditInput>(name: "set_speed",
            description: "Sets playback speed over a span. 2.0 plays twice as fast; repeating the same call is a no-op.",
            capability: .edit, required: ["project_id", "start", "end"], mutating: true,
            schema: VideoEditSchemas.input([
                "start": VideoEditSchemas.time, "end": VideoEditSchemas.time,
                "speed": J.num("Speed multiplier.", min: 0.25, max: 16, def: 2),
                "basis": VideoEditSchemas.basis, "revision": J.int("Expected revision.", min: 0),
            ], required: ["start", "end"]),
            idempotent: true, outputSchema: VideoEditSchemas.editResult, customDryRun: true) { input, ctx in
            try await videoEdit(input: input, ctx: ctx, describe: "set speed") { timeline in
                let basis = try clock(input.basis, fallback: "source")
                let start = try timeline.sourceSeconds(TimeRef.legacy(seconds: need(input.start, "start"), basis: basis))
                let end = try timeline.sourceSeconds(TimeRef.legacy(seconds: need(input.end, "end"), basis: basis))
                let speed = try finite(input.speed ?? 2, "speed", 0.25...16)
                guard end > start else { throw ToolError.invalidArguments("end must be after start.") }
                let duplicate = timeline.timeMap.ramps.contains { ramp in
                    abs(ramp.start - start) < 0.01 && abs(ramp.end - end) < 0.01 && abs(ramp.speed - speed) < 0.001
                }
                if !duplicate {
                    try applyCommand(.addSpeedRamp(start: start, end: end, speed: speed), to: &timeline)
                }
            }
        })

        register(ToolDefinition<VideoEditInput>(name: "set_zoom",
            description: "Adds a manual zoom over a span, or edits an existing one by id. Scale 1.1…4; focus is follow, fixed or element.",
            capability: .edit, required: ["project_id"], mutating: true,
            schema: VideoEditSchemas.input([
                "id": J.str("Existing zoom UUID; omit to add a new zoom."),
                "start": VideoEditSchemas.time, "end": VideoEditSchemas.time,
                "scale": J.num("Magnification.", min: 1.1, max: 4, def: 2),
                "basis": VideoEditSchemas.basis,
                "focus_mode": J.str("Focus behavior.", enum: ["follow", "fixed", "element"], def: "follow"),
                "focus_x": J.num("Normalized horizontal focus.", min: 0, max: 1),
                "focus_y": J.num("Normalized vertical focus.", min: 0, max: 1),
                "revision": J.int("Expected revision.", min: 0),
            ]),
            idempotent: true, outputSchema: VideoEditSchemas.editResult, customDryRun: true) { input, ctx in
            try await videoEdit(input: input, ctx: ctx, describe: "set zoom") { timeline in
                if let rawID = input.id {
                    let id = try uuid(rawID, "id")
                    guard let existing = timeline.zoom.first(where: { $0.id == id }) else {
                        throw ToolError.failed("No zoom with id \(id.uuidString).")
                    }
                    if let scale = input.scale {
                        let value = try finite(scale, "scale", 1.1...4)
                        if abs(existing.scale - value) > 0.001 {
                            try applyCommand(.setZoomScale(id, value), to: &timeline)
                        }
                    }
                    if let start = input.start, let end = input.end {
                        let basis = try clock(input.basis, fallback: "source")
                        let s = try timeline.sourceSeconds(TimeRef.legacy(seconds: start, basis: basis))
                        let e = try timeline.sourceSeconds(TimeRef.legacy(seconds: end, basis: basis))
                        guard e > s else { throw ToolError.invalidArguments("end must be after start.") }
                        let current = try Self.zoom(id, in: timeline)
                        if abs(current.start - s) > 0.01 || abs(current.end - e) > 0.01 {
                            try applyCommand(.moveZoom(id, start: s, end: e), to: &timeline)
                        }
                    }
                    if let focus = try zoomFocus(input) {
                        try applyCommand(.setZoomFocus(id, focus), to: &timeline)
                    }
                } else {
                    let basis = try clock(input.basis, fallback: "source")
                    let start = try timeline.sourceSeconds(TimeRef.legacy(seconds: need(input.start, "start"), basis: basis))
                    let end = try timeline.sourceSeconds(TimeRef.legacy(seconds: need(input.end, "end"), basis: basis))
                    let scale = try finite(input.scale ?? 2, "scale", 1.1...4)
                    guard end > start else { throw ToolError.invalidArguments("end must be after start.") }
                    let focus = try zoomFocus(input) ?? .follow
                    let duplicate = timeline.zoom.contains { z in
                        z.origin == .manual && abs(z.start - start) < 0.01 && abs(z.end - end) < 0.01
                            && abs(z.scale - scale) < 0.001
                    }
                    if !duplicate {
                        try applyCommand(.addZoom(ZoomSegment(start: start, end: end, scale: scale,
                                                              focus: focus, origin: .manual)), to: &timeline)
                    }
                }
            }
        })
    }

    // MARK: Music and captions

    private func registerVideoEditMediaTools() {
        register(ToolDefinition<VideoEditInput>(name: "add_music",
            description: "Sets the project's music track from a confined audio file. Repeating the same path and gain is a no-op.",
            capability: .edit, required: ["project_id", "path"], mutating: true,
            schema: VideoEditSchemas.input([
                "path": J.str("Approved MP3, WAV or M4A file."),
                "gain_db": J.num("Music trim in dB.", min: -60, max: 12),
                "revision": J.int("Expected revision.", min: 0),
            ], required: ["path"]),
            idempotent: true, outputSchema: VideoEditSchemas.editResult, customDryRun: true) { input, ctx in
            try await videoEdit(input: input, ctx: ctx, describe: "add music") { timeline in
                let url = try ctx.paths.path(need(input.path, "path"), ext: PathGuard.audioExt)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ToolError.failed("No file at \(url.path).")
                }
                let gain = try input.gainDb.map { try finite($0, "gain_db", -60...12) }
                var audio = timeline.audio
                let gainChanged = gain.map { abs(audio.musicGainDb - $0) > 0.001 } ?? false
                guard audio.musicPath != url.path || gainChanged else { return }
                audio.musicPath = url.path
                if let gain { audio.musicGainDb = gain }
                try applyCommand(.setAudio(audio), to: &timeline)
            }
        })

        register(ToolDefinition<VideoEditInput>(name: "remove_music",
            description: "Clears the music track. Safe to call again when there is no music.",
            capability: .edit, required: ["project_id"], mutating: true,
            schema: VideoEditSchemas.input(["revision": J.int("Expected revision.", min: 0)]),
            destructive: true, idempotent: true, outputSchema: VideoEditSchemas.editResult,
            customDryRun: true) { input, ctx in
            try await videoEdit(input: input, ctx: ctx, describe: "remove music") { timeline in
                var audio = timeline.audio
                guard audio.musicPath != nil else { return }
                audio.musicPath = nil
                try applyCommand(.setAudio(audio), to: &timeline)
            }
        })

        register(ToolDefinition<VideoEditInput>(name: "add_caption",
            description: "Adds a manual caption text block in source seconds and turns captions on. Text is capped at 500 characters.",
            capability: .edit, required: ["project_id", "text"], mutating: true,
            schema: VideoEditSchemas.input([
                "text": J.str("Caption text, at most 500 characters."),
                "start": VideoEditSchemas.time, "end": VideoEditSchemas.time,
                "basis": VideoEditSchemas.basis, "revision": J.int("Expected revision.", min: 0),
            ], required: ["text"]),
            outputSchema: VideoEditSchemas.editResult, customDryRun: true) { input, ctx in
            try await videoEdit(input: input, ctx: ctx, describe: "add caption") { timeline in
                let text = try need(input.text, "text")
                guard !text.isEmpty, text.count <= 500 else {
                    throw ToolError.invalidArguments("text must be 1…500 characters.")
                }
                let basis = try clock(input.basis, fallback: "source")
                let start = try timeline.sourceSeconds(TimeRef.legacy(seconds: input.start ?? 0, basis: basis))
                let end = try timeline.sourceSeconds(TimeRef.legacy(seconds: input.end ?? (start + 2), basis: basis))
                guard end > start else { throw ToolError.invalidArguments("end must be after start.") }
                try applyCommand(.addText(TextBlock(start: start, end: end, text: text)), to: &timeline)
                if !timeline.captions.enabled {
                    try applyCommand(.setCaptionsEnabled(true), to: &timeline)
                }
            }
        })
    }

    // MARK: Read-back and output

    private func registerVideoEditOutputTools() {
        register(ToolDefinition<VideoEditInput>(name: "get_edit",
            description: "Reads the persisted edit back from disk: clips in order, cuts, ramps, zooms, captions, music and revision. Call after each edit to verify it.",
            capability: .read, required: ["project_id"],
            schema: VideoEditSchemas.input([:]),
            outputSchema: VideoEditSchemas.readback) { input, ctx in
            guard let ref = ctx.engine.knownProjects().first(where: { $0.identifier == input.projectID }) else {
                throw ToolError.failed("Unknown project \(input.projectID). Call project_open first.")
            }
            let file = try ProjectBundle(url: ref.url).load()
            var payload = videoEditFields(file.timeline)
            payload["project_id"] = .string(input.projectID)
            payload["revision"] = .int(file.revision ?? 0)
            payload["timeline"] = await ctx.engine.encode(timeline: file.timeline, revision: file.revision ?? 0)
            return .object(payload)
        })

        register(ToolDefinition<VideoEditInput>(name: "render_preview",
            description: "Renders one preview frame, or a contact sheet when frames is greater than one. Use this to look at an edit before exporting.",
            capability: .read, required: ["project_id"],
            schema: VideoEditSchemas.input([
                "time": J.num("Output time to render.", min: 0, def: 0),
                "max_width": J.int("Rendered pixel width.", min: 160, max: 3840, def: 960),
                "frames": J.int("Frames in a contact sheet; 1 renders a single image.", min: 1, max: 12, def: 1),
                "duration": J.num("Span a sheet covers; 0 uses the project duration.", min: 0),
                "png": J.bool("Lossless PNG instead of JPEG.", def: false),
            ]),
            outputSchema: VideoEditSchemas.preview) { input, ctx in
            let time = try finite(input.time ?? 0, "time", 0...86_400)
            let width = try input.maxWidth.map { try finite(Double($0), "max_width", 160...3840) }.map(Int.init) ?? 960
            let count = try input.frames.map { try finite(Double($0), "frames", 1...12) }.map(Int.init) ?? 1
            let png = input.png ?? false
            let mime = png ? "image/png" : "image/jpeg"
            let data: Data
            let name: String
            if count > 1 {
                data = try await ctx.engine.previewSheet(projectID: input.projectID, frames: count,
                                                         duration: input.duration ?? 0, maxWidth: width, png: png)
                name = "sheet-\(count).\(png ? "png" : "jpg")"
            } else {
                let rendered = try await ctx.engine.previewFrame(projectID: input.projectID, time: time,
                                                                 maxWidth: width, png: png)
                data = rendered.0
                name = rendered.1
            }
            var payload: [String: JSONValue] = [
                "image_base64": .string(data.base64EncodedString()),
                "mime_type": .string(mime),
                "name": .string(name),
                "time": .number(time),
            ]
            if count > 1 { payload["frames"] = .int(count) }
            if let size = previewImageSize(data) {
                payload["width"] = .int(size.width)
                payload["height"] = .int(size.height)
            }
            return .object(payload)
        })

        register(ToolDefinition<VideoEditInput>(name: "export_final",
            description: "Exports the edited project to a movie. Set wait to receive the job result inline; an existing output is never overwritten unless overwrite is true.",
            capability: .export, required: ["project_id", "output"], mutating: true, longRunning: true,
            schema: VideoEditSchemas.input([
                "output": J.str("Absolute movie path inside an approved folder."),
                "preset": J.str("Export preset name from export_presets.", def: "1080p30-h264"),
                "include_audio": J.bool("Include the mixed soundtrack.", def: true),
                "export_stems": J.bool("Also write separate audio stems.", def: false),
                "wait": J.bool("Wait for the export and return its result.", def: false),
                "overwrite": J.bool("Replace an existing file at output.", def: false),
            ], required: ["output"]),
            outputSchema: VideoEditSchemas.export) { input, ctx in
            let rawOutput = try need(input.output, "output")
            let resolved = try ctx.paths.writablePath(rawOutput, ext: PathGuard.videoExt)
            let overwrite = input.overwrite ?? false
            let job = try await ctx.engine.startExport(projectID: input.projectID,
                                                       presetName: input.preset ?? "1080p30-h264",
                                                       outputPath: resolved.path,
                                                       includeAudio: input.includeAudio ?? true,
                                                       exportStems: input.exportStems ?? false,
                                                       overwrite: overwrite,
                                                       client: ctx.clientID)
            var payload: [String: JSONValue] = [
                "job_id": .string(job), "output": .string(resolved.path),
            ]
            if input.wait ?? false {
                let completed = try await ctx.waitForJob(job)
                payload["result"] = completed.jsonValue
            }
            return .object(payload)
        })
    }

    // MARK: Small lookups

    private static func clip(_ id: UUID, in timeline: Timeline) throws -> TimelineClip {
        guard let clip = timeline.clips.first(where: { $0.id == id }) else {
            throw ToolError.failed("No clip with id \(id.uuidString).")
        }
        return clip
    }

    private static func zoom(_ id: UUID, in timeline: Timeline) throws -> ZoomSegment {
        guard let zoom = timeline.zoom.first(where: { $0.id == id }) else {
            throw ToolError.failed("No zoom with id \(id.uuidString).")
        }
        return zoom
    }
}
