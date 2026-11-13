import Foundation
import LumenCore
import LumenProject
import LumenDirector
import LumenExport
import LumenAudio
import LumenSpeech

// MARK: - Time

/// A time with an explicit basis.
///
/// AGENT: `start` and `end` were bare numbers, so an agent could not tell the
/// source seconds a zoom or cut lives in from the output seconds the preview
/// and QA report speak. Callers now name the basis.
public enum TimeRef: Codable, Sendable, Equatable {
    case source(Double)
    case output(Double)
    case marker(id: String, offsetMs: Double)

    // AGENT: a tagged time reference makes source, edited output, and marker clocks unambiguous.
    public static func legacy(seconds: Double, basis: String) throws -> TimeRef {
        switch basis {
        case "source": return .source(seconds)
        case "output": return .output(seconds)
        default: throw ToolError.invalidArguments("basis must be \"source\" or \"output\", not \(basis).")
        }
    }

    private enum CodingKeys: String, CodingKey { case source, output, marker, offsetMs = "offset_ms" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hasSource = c.contains(.source), hasOutput = c.contains(.output), hasMarker = c.contains(.marker)
        guard [hasSource, hasOutput, hasMarker].filter({ $0 }).count == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .source, in: c,
                debugDescription: "Use exactly one of source, output, or marker.")
        }
        if hasSource { self = .source(try c.decode(Double.self, forKey: .source)) }
        else if hasOutput { self = .output(try c.decode(Double.self, forKey: .output)) }
        else {
            self = .marker(id: try c.decode(String.self, forKey: .marker),
                           offsetMs: try c.decodeIfPresent(Double.self, forKey: .offsetMs) ?? 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .source(let value): try c.encode(value, forKey: .source)
        case .output(let value): try c.encode(value, forKey: .output)
        case .marker(let id, let offset):
            try c.encode(id, forKey: .marker)
            try c.encode(offset, forKey: .offsetMs)
        }
    }
}

extension Timeline {
    /// Converts a caller-supplied time to the source seconds the timeline stores.
    func sourceSeconds(_ ref: TimeRef) throws -> Double {
        // AGENT: reject invalid times before the time map can clamp them silently.
        switch ref {
        case .source(let seconds):
            guard seconds.isFinite, seconds >= 0, seconds <= timeMap.sourceDuration + 0.001 else {
                throw ToolError.invalidArguments("Source time must be within the recording duration.")
            }
            return seconds
        case .output(let seconds):
            guard seconds.isFinite, seconds >= 0, seconds <= timeMap.outputDuration + 0.001 else {
                throw ToolError.invalidArguments("Output time must be within the edited duration.")
            }
            return timeMap.source(atOutput: seconds)
        case .marker:
            throw ToolError.invalidArguments("Marker times must be resolved by the project engine.")
        }
    }
}

// MARK: - Project and timeline tools

public struct ProjectListInput: ToolInput {
    public init() {}
}

public struct ProjectOpenInput: ToolInput {
    public var path: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case path
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
    }
}

public struct TimelineGetInput: ToolInput {
    public var projectID: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    }
}

/// AGENT: agents need to release cached project sessions when they finish a project.
public struct ProjectCloseInput: ToolInput {
    public var projectID: String = ""
    public init() {}
    enum CodingKeys: String, CodingKey { case projectID = "project_id" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    }
}

/// One typed timeline operation. Flat and explicit so an agent cannot send
/// an expression it does not understand.
///
/// AGENT: every field carried a sentinel (start 0, scale 2, flag true), so
/// "omitted" and "set to the default" were indistinguishable and a missing
/// value silently wrote nonsense. Fields are optional and each op names the
/// ones it needs.
public struct PatchOp: Codable, Sendable {
    public var op: String = ""
    public var id: String?
    public var start: Double?
    public var end: Double?
    public var scale: Double?
    public var focusMode: String?
    public var focusX: Double?
    public var focusY: Double?
    public var speed: Double?
    public var key: String?
    public var value: Double?
    public var text: String?
    public var flag: Bool?
    public init() {}

    enum CodingKeys: String, CodingKey {
    case op
    case id
    case start
    case end
    case scale
    case focusMode = "focus_mode"
    case focusX = "focus_x"
    case focusY = "focus_y"
    case speed
    case key
    case value
    case text
    case flag
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.op = try c.decodeIfPresent(String.self, forKey: .op) ?? ""
    self.id = try c.decodeIfPresent(String.self, forKey: .id)
    self.start = try c.decodeIfPresent(Double.self, forKey: .start)
    self.end = try c.decodeIfPresent(Double.self, forKey: .end)
    self.scale = try c.decodeIfPresent(Double.self, forKey: .scale)
    self.focusMode = try c.decodeIfPresent(String.self, forKey: .focusMode)
    self.focusX = try c.decodeIfPresent(Double.self, forKey: .focusX)
    self.focusY = try c.decodeIfPresent(Double.self, forKey: .focusY)
    self.speed = try c.decodeIfPresent(Double.self, forKey: .speed)
    self.key = try c.decodeIfPresent(String.self, forKey: .key)
    self.value = try c.decodeIfPresent(Double.self, forKey: .value)
    self.text = try c.decodeIfPresent(String.self, forKey: .text)
    self.flag = try c.decodeIfPresent(Bool.self, forKey: .flag)
    }
}

public struct TimelinePatchInput: ToolInput {
    public var projectID: String = ""
    // AGENT: omission means no compare-and-swap; revision zero is not a valid project revision.
    public var revision: Int?
    public var ops: [PatchOp] = []
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case revision
    case ops
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.revision = try c.decodeIfPresent(Int.self, forKey: .revision)
    self.ops = try c.decodeIfPresent([PatchOp].self, forKey: .ops) ?? []
    }
}

public struct UndoInput: ToolInput {
    public var projectID: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    }
}

public struct ZoomAddInput: ToolInput {
    public var projectID: String = ""
    public var start: Double = 0
    public var end: Double = 0
    public var scale: Double = 2
    public var focusMode: String = "follow"
    public var focusX: Double = 0.5
    public var focusY: Double = 0.5
    /// "source" (the recording) or "output" (after cuts and ramps).
    public var basis: String = "source"
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case start
    case end
    case scale
    case focusMode = "focus_mode"
    case focusX = "focus_x"
    case focusY = "focus_y"
    case basis
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
    self.end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
    self.basis = try c.decodeIfPresent(String.self, forKey: .basis) ?? "source"
    self.scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 2
    self.focusMode = try c.decodeIfPresent(String.self, forKey: .focusMode) ?? "follow"
    self.focusX = try c.decodeIfPresent(Double.self, forKey: .focusX) ?? 0.5
    self.focusY = try c.decodeIfPresent(Double.self, forKey: .focusY) ?? 0.5
    }
}

public struct ZoomRemoveInput: ToolInput {
    public var projectID: String = ""
    public var id: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case id
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
    }
}

public struct ZoomReplanInput: ToolInput {
    public var projectID: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    }
}

public struct CutRangeInput: ToolInput {
    public var projectID: String = ""
    public var start: Double = 0
    public var end: Double = 0
    /// "source" (the recording) or "output" (after cuts and ramps).
    public var basis: String = "source"
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case start
    case end
    case basis
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
    self.end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
    self.basis = try c.decodeIfPresent(String.self, forKey: .basis) ?? "source"
    }
}

public struct SpeedRampInput: ToolInput {
    public var projectID: String = ""
    public var start: Double = 0
    public var end: Double = 0
    public var speed: Double = 2
    /// "source" (the recording) or "output" (after cuts and ramps).
    public var basis: String = "source"
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case start
    case end
    case speed
    case basis
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
    self.end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
    self.basis = try c.decodeIfPresent(String.self, forKey: .basis) ?? "source"
    self.speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 2
    }
}

public struct StyleSetInput: ToolInput {
    public var projectID: String = ""
    // AGENT: optional fields replace numeric sentinels so valid zero values can be applied.
    public var padding: Double?
    public var cornerRadius: Double?
    public var shadow: Double?
    public var aspect: Double?
    public var wallpaperBlur: Double?
    public var background: String?
    public var backgroundImagePath: String?
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case padding
    case cornerRadius = "corner_radius"
    case shadow
    case aspect
    case wallpaperBlur = "wallpaper_blur"
    case background
    case backgroundImagePath = "background_image_path"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.padding = try c.decodeIfPresent(Double.self, forKey: .padding)
    self.cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius)
    self.shadow = try c.decodeIfPresent(Double.self, forKey: .shadow)
    self.aspect = try c.decodeIfPresent(Double.self, forKey: .aspect)
    self.wallpaperBlur = try c.decodeIfPresent(Double.self, forKey: .wallpaperBlur)
    self.background = try c.decodeIfPresent(String.self, forKey: .background)
    self.backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath)
    }
}

public struct BackgroundListInput: ToolInput {
    public init() {}
}

public struct BackgroundSetInput: ToolInput {
    public var projectID: String = ""
    public var background: String = ""
    public var imagePath: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case background
    case imagePath = "image_path"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.background = try c.decodeIfPresent(String.self, forKey: .background) ?? ""
    self.imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath) ?? ""
    }
}

public struct CaptionsGenerateInput: ToolInput {
    public var projectID: String = ""
    public var locale: String = "en-US"
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case locale
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "en-US"
    }
}

public struct CaptionsSetInput: ToolInput {
    public var projectID: String = ""
    public var enabled: Bool = true
    public var locale: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case enabled
    case locale
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    self.locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? ""
    }
}

public struct PrivacyScanInput: ToolInput {
    public var projectID: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    }
}

public struct PrivacyApplyInput: ToolInput {
    public var projectID: String = ""
    /// mask id -> approved
    public var decisions: [String: Bool] = [:]
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case decisions
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.decisions = try c.decodeIfPresent([String: Bool].self, forKey: .decisions) ?? [:]
    }
}

public extension ToolRegistry {
    func registerProjectTools() {
        register(ToolDefinition<ProjectListInput>(name: "project_list",
            description: "Lists the recordings in the Lumen library with their ids and paths.",
            capability: .read) { _, ctx in
                let library = await ctx.engine.runtime.recordingLibrary()
                let rows = library.map { url -> JSONValue in
                    let bundle = ProjectBundle(url: url)
                    let complete = FileManager.default.fileExists(atPath: bundle.projectURL.path)
                    // AGENT: list IDs must match the canonical IDs returned by project_open.
                    return .object(["project_id": .string(Engine.projectID(url)),
                                    "path": .string(url.path),
                                    "complete": .bool(complete),
                                    "unfinished": .bool(!complete && bundle.isUnfinished)])
                }
                return .object(["projects": .array(rows)])
            })

        register(ToolDefinition<ProjectOpenInput>(name: "project_open",
            description: "Opens a recording for editing. Returns the project id and its current revision.",
            capability: .read, required: ["path"]) { input, ctx in
                let url = try ctx.policy.resolvePath(input.path, for: ctx.clientID)
                let ref = try await ctx.engine.openProject(at: url.path)
                return .object(["project_id": .string(ref.identifier), "path": .string(ref.url.path)])
            })

        register(ToolDefinition<TimelineGetInput>(name: "timeline_get",
            description: "Reads the editable timeline of a project: zooms, cuts, ramps, style, cursor, audio, captions and privacy, plus the current revision.",
            capability: .read, required: ["project_id"]) { input, ctx in
                try await ctx.engine.timelineValue(projectID: input.projectID)
            })

        register(ToolDefinition<ProjectCloseInput>(name: "project_close",
            description: "Closes an open project session and releases its decoded media resources.",
            capability: .read, required: ["project_id"], mutating: true) { input, ctx in
                let closed = await ctx.engine.closeProject(projectID: input.projectID)
                return .object(["project_id": .string(input.projectID), "closed": .bool(closed)])
            })

        register(ToolDefinition<TimelinePatchInput>(name: "timeline_patch",
            description: "Applies typed operations to a timeline. Supported ops: zoom_add, zoom_set, zoom_remove, cut_add, cut_remove, ramp_set, ramp_remove, style_set, audio_lane_add, audio_lane_remove, music_set, captions_set, privacy_set. Pass the revision you read to be sure nobody else changed the project.",
            capability: .edit, required: ["project_id", "ops"], mutating: true,
            schema: ToolSchemas.timelinePatch, destructive: true) { input, ctx in
                let expect = input.revision
                if ctx.dryRun {
                    return .object(["dry_run": .bool(true), "ops": .int(input.ops.count),
                                    "project_id": .string(input.projectID)])
                }
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: expect,
                                                      describe: "\(input.ops.count) timeline operations") { timeline in
                    for op in input.ops { try self.apply(op, to: &timeline, paths: ctx.paths) }
                }
                return .object(result)
            })

        register(ToolDefinition<UndoInput>(name: "undo",
            description: "Undoes the last agent edit on a project.",
            capability: .edit, required: ["project_id"], mutating: true, destructive: true) { input, ctx in
                let result = try await ctx.engine.undo(projectID: input.projectID)
                return .object(result)
            })

        register(ToolDefinition<ZoomAddInput>(name: "zoom_add",
            description: "Adds a manual zoom. start and end are source seconds unless basis is \"output\". Manual zooms survive an auto replan.",
            capability: .edit, required: ["project_id", "start", "end"], mutating: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "manual zoom") { timeline in
                    // AGENT: zoom times are stored in source seconds; honour the caller's basis.
                    let start = try timeline.sourceSeconds(try TimeRef.legacy(seconds: input.start, basis: input.basis))
                    let end = try timeline.sourceSeconds(try TimeRef.legacy(seconds: input.end, basis: input.basis))
                    // AGENT: reject invalid ranges and route zoom edits through the editor reducer.
                    guard end > start, input.scale.isFinite, (1.1...4).contains(input.scale) else { throw ToolError.invalidArguments("Need start < end and zoom scale 1.1…4.") }
                    try applyCommand(.addZoom(ZoomSegment(start: start, end: end, scale: input.scale,
                                                          focus: try self.focus(from: input.focusMode, x: input.focusX, y: input.focusY),
                                                          origin: .manual)), to: &timeline)
                }
                return .object(result)
            })

        register(ToolDefinition<ZoomRemoveInput>(name: "zoom_remove",
            description: "Removes a zoom by its id.",
            capability: .edit, required: ["project_id", "id"], mutating: true, destructive: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "remove zoom") { timeline in
                    guard let id = UUID(uuidString: input.id),
                          let zoom = timeline.zoom.first(where: { $0.id == id }) else {
                        throw ToolError.invalidArguments("id must be an existing zoom UUID.")
                    }
                    // AGENT: suppress planner-owned zooms before deleting through the reducer.
                    if zoom.origin == .auto, !timeline.suppressedAuto.contains(id.uuidString) {
                        timeline.suppressedAuto.append(id.uuidString)
                    }
                    try applyCommand(.deleteZoom(id), to: &timeline)
                }
                return .object(result)
            })

        register(ToolDefinition<ZoomReplanInput>(name: "zoom_replan",
            description: "Re-runs the automatic zoom planner over the recorded input. Manual zooms are kept.",
            capability: .edit, required: ["project_id"], mutating: true) { input, ctx in
                let result = try await ctx.engine.replanZoom(projectID: input.projectID)
                return .object(result)
            })

        register(ToolDefinition<CutRangeInput>(name: "cut_range",
            description: "Cuts a span out of the recording. start and end are in source seconds unless basis is \"output\".",
            capability: .edit, required: ["project_id", "start", "end"], mutating: true, destructive: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "cut") { timeline in
                    let start = try timeline.sourceSeconds(try TimeRef.legacy(seconds: input.start, basis: input.basis))
                    let end = try timeline.sourceSeconds(try TimeRef.legacy(seconds: input.end, basis: input.basis))
                    // AGENT: the editor's output-range cut handles clips and overlaps consistently.
                    let a = timeline.timeMap.output(atSource: start), b = timeline.timeMap.output(atSource: end)
                    guard b > a else { throw ToolError.invalidArguments("Cut end must be after start in the edited timeline.") }
                    try applyCommand(.cutOutputRange(start: a, end: b), to: &timeline)
                }
                return .object(result)
            })

        register(ToolDefinition<SpeedRampInput>(name: "speed_ramp_set",
            description: "Sets a speed ramp. start and end are source seconds unless basis is \"output\". 2.0 plays twice as fast.",
            capability: .edit, required: ["project_id", "start", "end"], mutating: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "speed ramp") { timeline in
                    let start = try timeline.sourceSeconds(try TimeRef.legacy(seconds: input.start, basis: input.basis))
                    let end = try timeline.sourceSeconds(try TimeRef.legacy(seconds: input.end, basis: input.basis))
                    // AGENT: zero or negative ramp speed breaks time-map construction.
                    guard end > start, input.speed.isFinite, (0.25...16).contains(input.speed) else { throw ToolError.invalidArguments("Need start < end and speed 0.25…16.") }
                    try applyCommand(.addSpeedRamp(start: start, end: end, speed: input.speed), to: &timeline)
                }
                return .object(result)
            })

        register(ToolDefinition<StyleSetInput>(name: "style_set",
            description: "Sets the canvas style: padding, corner radius, shadow, aspect ratio, wallpaper blur and background.",
            capability: .edit, required: ["project_id"], mutating: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "style") { timeline in
                    var style = timeline.style
                    func checked(_ value: Double, _ name: String, _ bounds: ClosedRange<Double>) throws -> Double {
                        guard value.isFinite, bounds.contains(value) else {
                            throw ToolError.invalidArguments("\(name) must be in \(bounds.lowerBound)…\(bounds.upperBound).")
                        }
                        return value
                    }
                    if let padding = input.padding { style.padding = try checked(padding, "padding", 0 ... 0.2) }
                    if let radius = input.cornerRadius { style.cornerRadius = try checked(radius, "corner_radius", 0 ... 80) }
                    if let shadow = input.shadow { style.shadow = try checked(shadow, "shadow", 0 ... 1) }
                    if let aspect = input.aspect {
                        guard aspect.isFinite, aspect > 0.2, aspect < 5 else {
                            throw ToolError.invalidArguments("aspect must be greater than 0.2 and less than 5.")
                        }
                        style.customAspect = aspect
                    }
                    if let blur = input.wallpaperBlur { style.wallpaperBlur = try checked(blur, "wallpaper_blur", 0 ... 60) }
                    if let background = input.background, !background.isEmpty {
                        style.background = try self.backgroundKind(background)
                    }
                    if let imagePath = input.backgroundImagePath, !imagePath.isEmpty {
                        // AGENT: an unconfined image path let an agent read any file the user owns.
                        let url = try ctx.paths.path(imagePath, ext: PathGuard.imageExt)
                        style.setPhotoBackground(url.path)
                    }
                    try applyCommand(.setStyle(style), to: &timeline)
                }
                return .object(result)
            })

        register(ToolDefinition<BackgroundListInput>(name: "background_list",
            description: "Lists the available backgrounds: the generated kinds and the bundled gradients.",
            capability: .read) { _, _ in
                let kinds: [JSONValue] = BackgroundKind.offered.map { .string($0.rawValue) }
                let gradients: [JSONValue] = GradientPresets.all.map { .string($0.0) }
                return .object(["backgrounds": .array(kinds), "gradients": .array(gradients)])
            })

        register(ToolDefinition<BackgroundSetInput>(name: "background_set",
            description: "Sets the background of a project: a generated kind or a local image.",
            capability: .edit, required: ["project_id"], mutating: true) { input, ctx in
                // AGENT: reject an empty background update instead of reporting a successful no-op.
                guard !input.background.isEmpty || !input.imagePath.isEmpty else {
                    throw ToolError.invalidArguments("Provide a background kind or image_path.")
                }
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "background") { timeline in
                    var style = timeline.style
                    if !input.imagePath.isEmpty {
                        // AGENT: confine the image to the client's approved folders.
                        let url = try ctx.paths.path(input.imagePath, ext: PathGuard.imageExt)
                        style.setPhotoBackground(url.path)
                    } else if !input.background.isEmpty {
                        style.background = try self.backgroundKind(input.background)
                    }
                    try applyCommand(.setStyle(style), to: &timeline)
                }
                return .object(result)
            })

        register(ToolDefinition<CaptionsGenerateInput>(name: "captions_generate",
            description: "Transcribes the recorded microphone and turns captions on. Needs the local speech model; returns a job id.",
            capability: .edit, required: ["project_id"], mutating: true, longRunning: true) { input, ctx in
                let job = try await ctx.engine.startTranscription(projectID: input.projectID, locale: input.locale)
                return .object(["job_id": .string(job)])
            })

        register(ToolDefinition<CaptionsSetInput>(name: "captions_set",
            description: "Turns captions on or off and sets their locale.",
            capability: .edit, required: ["project_id"], mutating: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "captions") { timeline in
                    var captions = timeline.captions
                    captions.enabled = input.enabled
                    if !input.locale.isEmpty { captions.locale = input.locale }
                    try applyCommand(.setCaptions(captions), to: &timeline)
                }
                return .object(result)
            })

        register(ToolDefinition<PrivacyScanInput>(name: "privacy_scan",
            description: "Runs the privacy scan over a recording and applies automatic masks. Returns a job id; poll it with job_status.",
            capability: .edit, required: ["project_id"], mutating: true, longRunning: true) { input, ctx in
                let job = try await ctx.engine.startPrivacyScan(projectID: input.projectID)
                return .object(["job_id": .string(job)])
            })

        register(ToolDefinition<PrivacyApplyInput>(name: "privacy_apply",
            description: "Approves or rejects automatic masks by id. Approving a mask keeps it; rejecting removes it.",
            capability: .edit, required: ["project_id"], mutating: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "privacy decisions") { timeline in
                    var approvedIDs: [UUID] = []
                    var rejectedIDs: [UUID] = []
                    for (id, isApproved) in input.decisions {
                        guard let uuid = UUID(uuidString: id), timeline.overlays.masks.contains(where: { $0.id == uuid }) else {
                            throw ToolError.invalidArguments("Every decision key must be an existing mask UUID.")
                        }
                        if isApproved { approvedIDs.append(uuid) } else { rejectedIDs.append(uuid) }
                    }
                    if !approvedIDs.isEmpty { try applyCommand(.approveMasks(approvedIDs), to: &timeline) }
                    if !rejectedIDs.isEmpty { try applyCommand(.rejectMasks(rejectedIDs), to: &timeline) }
                }
                return .object(result)
            })
    }

    /// Applies a timeline operation through the editor's command reducer.
    ///
    /// AGENT: direct field edits skipped the same validation and magnetic-lane rules the editor applies.
    func apply(_ op: PatchOp, to timeline: inout Timeline, paths: PathGuard) throws {
        func need<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else {
                throw ToolError.invalidArguments("\(op.op) needs \(name). See the timeline_patch schema.")
            }
            return value
        }
        func range(_ value: Double, _ name: String, _ bounds: ClosedRange<Double>) throws -> Double {
            guard value.isFinite, bounds.contains(value) else {
                throw ToolError.invalidArguments("\(name) must be in \(bounds.lowerBound)…\(bounds.upperBound).")
            }
            return value
        }
        func uuid(_ raw: String, _ name: String) throws -> UUID {
            guard let value = UUID(uuidString: raw) else {
                throw ToolError.invalidArguments("\(name) must be a UUID.")
            }
            return value
        }
        switch op.op {
        case "zoom_add":
            let start = try need(op.start, "start"), end = try need(op.end, "end")
            guard start.isFinite, end.isFinite, start >= 0, end > start, end <= timeline.timeMap.sourceDuration + 0.001 else {
                throw ToolError.invalidArguments("zoom_add requires a valid source-time span.")
            }
            let scale = try range(op.scale ?? 2, "scale", 1.1...4)
            try applyCommand(.addZoom(ZoomSegment(start: start, end: end, scale: scale,
                                                  focus: try focus(from: op.focusMode ?? "follow",
                                                                   x: op.focusX ?? 0.5, y: op.focusY ?? 0.5),
                                                  origin: .manual)), to: &timeline)
        case "zoom_set":
            let id = try uuid(try need(op.id, "id"), "id")
            guard let zoom = timeline.zoom.first(where: { $0.id == id }) else {
                throw ToolError.failed("No zoom with id \(id.uuidString).")
            }
            if let start = op.start, let end = op.end {
                guard start.isFinite, end.isFinite, start >= 0, end > start,
                      end <= timeline.timeMap.sourceDuration + 0.001 else {
                    throw ToolError.invalidArguments("zoom_set requires a valid source-time span.")
                }
                try applyCommand(.moveZoom(id, start: start, end: end), to: &timeline)
            } else if (op.start == nil) != (op.end == nil) {
                throw ToolError.invalidArguments("zoom_set needs both start and end, or neither.")
            }
            if let scale = op.scale {
                try applyCommand(.setZoomScale(id, try range(scale, "scale", 1.1...4)), to: &timeline)
            }
            if let x = op.focusX { _ = try range(x, "focus_x", 0...1) }
            if let y = op.focusY { _ = try range(y, "focus_y", 0...1) }
            if let mode = op.focusMode {
                let updated = try focus(from: mode, x: op.focusX ?? 0.5, y: op.focusY ?? 0.5)
                try applyCommand(.setZoomFocus(id, updated), to: &timeline)
            } else if op.focusX != nil || op.focusY != nil {
                let updated: Focus
                switch zoom.focus {
                case .fixed(let x, let y): updated = .fixed(x: op.focusX ?? x, y: op.focusY ?? y)
                case .element(let x, let y, let w, let h):
                    updated = .element(x: op.focusX ?? x, y: op.focusY ?? y, w: w, h: h)
                case .follow:
                    throw ToolError.invalidArguments("Specify focus_mode when changing coordinates on a follow zoom.")
                }
                try applyCommand(.setZoomFocus(id, updated), to: &timeline)
            }
        case "zoom_remove":
            let id = try uuid(try need(op.id, "id"), "id")
            guard let zoom = timeline.zoom.first(where: { $0.id == id }) else {
                throw ToolError.failed("No zoom with id \(id.uuidString).")
            }
            if zoom.origin == .auto, !timeline.suppressedAuto.contains(id.uuidString) {
                timeline.suppressedAuto.append(id.uuidString)
            }
            try applyCommand(.deleteZoom(id), to: &timeline)
        case "cut_add":
            let start = try need(op.start, "start"), end = try need(op.end, "end")
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  end <= timeline.timeMap.sourceDuration + 0.001 else {
                throw ToolError.invalidArguments("cut_add needs end after start, in source seconds.")
            }
            let outputStart = timeline.timeMap.output(atSource: start)
            let outputEnd = timeline.timeMap.output(atSource: end)
            guard outputEnd > outputStart else { throw ToolError.invalidArguments("Cut is outside the edited timeline.") }
            try applyCommand(.cutOutputRange(start: outputStart, end: outputEnd), to: &timeline)
        case "cut_remove":
            let id = try uuid(try need(op.id, "id"), "id")
            guard timeline.timeMap.cuts.contains(where: { $0.id == id }) else {
                throw ToolError.failed("No cut with id \(id.uuidString).")
            }
            try applyCommand(.deleteCut(id), to: &timeline)
        case "ramp_set":
            let start = try need(op.start, "start"), end = try need(op.end, "end")
            let speed = try range(op.speed ?? 2, "speed", 0.25...16)
            guard start >= 0, end > start, end <= timeline.timeMap.sourceDuration + 0.001 else {
                throw ToolError.invalidArguments("ramp_set needs a valid source-time span.")
            }
            try applyCommand(.addSpeedRamp(start: start, end: end, speed: speed), to: &timeline)
        case "ramp_remove":
            let id = try uuid(try need(op.id, "id"), "id")
            guard let ramp = timeline.timeMap.ramps.first(where: { $0.id == id }) else {
                throw ToolError.failed("No speed ramp with id \(id.uuidString).")
            }
            if ramp.origin == .auto, !timeline.suppressedAuto.contains(id.uuidString) {
                timeline.suppressedAuto.append(id.uuidString)
            }
            try applyCommand(.deleteSpeedRamp(id), to: &timeline)
        case "style_set":
            let key = try need(op.key, "key")
            var style = timeline.style
            switch key {
            case "padding": style.padding = try range(need(op.value, "value"), "padding", 0...0.2)
            case "corner_radius": style.cornerRadius = try range(need(op.value, "value"), "corner_radius", 0...80)
            case "shadow": style.shadow = try range(need(op.value, "value"), "shadow", 0...1)
            case "aspect":
                let aspect = try need(op.value, "value")
                guard aspect.isFinite, aspect > 0.2, aspect < 5 else {
                    throw ToolError.invalidArguments("aspect must be greater than 0.2 and less than 5.")
                }
                style.customAspect = aspect
            case "wallpaper_blur": style.wallpaperBlur = try range(need(op.value, "value"), "wallpaper_blur", 0...60)
            case "background": style.background = try backgroundKind(try need(op.text, "text"))
            case "background_image":
                let path = try need(op.text, "text")
                style.setPhotoBackground(try paths.path(path, ext: PathGuard.imageExt).path)
            default:
                throw ToolError.invalidArguments("Unknown style key \(key). Use padding, corner_radius, shadow, aspect, wallpaper_blur, background or background_image.")
            }
            try applyCommand(.setStyle(style), to: &timeline)
        case "audio_lane_add":
            let roleName = op.text ?? "voiceover"
            guard let role = AudioLane.Role(rawValue: roleName) else {
                throw ToolError.invalidArguments("role must be one of mic, system, voiceover, music, sfx.")
            }
            let lanePath = try op.key.map { try paths.path($0, ext: PathGuard.audioExt).path }
            let placement = try range(op.start ?? 0, "placement", 0...max(timeline.timeMap.outputDuration, 0))
            let gain = try range(op.value ?? 0, "gain_db", -60...12)
            var audio = timeline.audio
            audio.lanes.append(AudioLane(role: role, path: lanePath, placement: placement, gainDb: gain))
            try applyCommand(.setAudio(audio), to: &timeline)
        case "audio_lane_remove":
            let id = try uuid(try need(op.id, "id"), "id")
            var audio = timeline.audio
            guard audio.lanes.contains(where: { $0.id == id }) else {
                throw ToolError.failed("No audio lane with id \(id.uuidString).")
            }
            audio.lanes.removeAll { $0.id == id }
            try applyCommand(.setAudio(audio), to: &timeline)
        case "music_set":
            let rawPath = try need(op.text, "text")
            var audio = timeline.audio
            audio.musicPath = rawPath.isEmpty ? nil : try paths.path(rawPath, ext: PathGuard.audioExt).path
            if let gain = op.value { audio.musicGainDb = try range(gain, "music_gain_db", -60...12) }
            try applyCommand(.setAudio(audio), to: &timeline)
        case "captions_set":
            var captions = timeline.captions
            captions.enabled = try need(op.flag, "flag")
            if let locale = op.text, !locale.isEmpty { captions.locale = locale }
            try applyCommand(.setCaptions(captions), to: &timeline)
        case "privacy_set":
            let key = try need(op.key, "key")
            var privacy = timeline.overlays.privacy
            switch key {
            case "enabled": privacy.enabled = try need(op.flag, "flag")
            case "auto_detect": privacy.autoDetect = try need(op.flag, "flag")
            case "mode":
                let rawMode = try need(op.text, "text")
                guard let mode = MaskMode(rawValue: rawMode) else {
                    throw ToolError.invalidArguments("Unknown privacy mode \(rawMode). Valid values: \(MaskMode.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                privacy.mode = mode
            case "padding": privacy.padding = try range(need(op.value, "value"), "privacy padding", 0...80)
            default: throw ToolError.invalidArguments("Unknown privacy key \(key). Use enabled, auto_detect, mode or padding.")
            }
            try applyCommand(.setPrivacy(privacy), to: &timeline)
        default:
            throw ToolError.invalidArguments("Unknown timeline op \(op.op). Valid ops: zoom_add, zoom_set, zoom_remove, cut_add, cut_remove, ramp_set, ramp_remove, style_set, audio_lane_add, audio_lane_remove, music_set, captions_set, privacy_set.")
        }
    }

    private func focus(from mode: String, x: Double, y: Double) throws -> Focus {
        guard ["follow", "fixed", "element"].contains(mode) else {
            throw ToolError.invalidArguments("focus_mode must be follow, fixed, or element.")
        }
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw ToolError.invalidArguments("focus_x and focus_y must be finite fractions from 0 to 1.")
        }
        switch mode {
        case "fixed": return .fixed(x: x, y: y)
        case "element": return .element(x: x, y: y, w: 0, h: 0)
        default: return .follow
        }
    }

    /// AGENT: an unknown background name used to be ignored silently; now it is
    /// a structured error that lists the valid values.
    func backgroundKind(_ name: String) throws -> BackgroundKind {
        guard let kind = BackgroundKind(rawValue: name) else {
            throw ToolError.invalidArguments(
                "Unknown background “\(name)”. Valid values: \(BackgroundKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return kind
    }
}
