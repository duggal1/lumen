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
public struct TimeRef: Codable, Sendable, Equatable {
    public var seconds: Double
    /// "source" (the recording) or "output" (after cuts and ramps).
    public var basis: String
    public init(seconds: Double, basis: String = "source") {
        self.seconds = seconds
        self.basis = basis
    }
}

extension Timeline {
    /// Converts a caller-supplied time to the source seconds the timeline stores.
    func sourceSeconds(_ ref: TimeRef) throws -> Double {
        // AGENT: reject invalid times before the time map can clamp them silently.
        guard ref.seconds.isFinite, ref.seconds >= 0 else { throw ToolError.invalidArguments("Time must be finite and non-negative.") }
        switch ref.basis {
        case "source":
            guard ref.seconds <= timeMap.sourceDuration + 0.001 else { throw ToolError.invalidArguments("Source time exceeds the recording duration.") }
            return ref.seconds
        case "output":
            guard ref.seconds <= timeMap.outputDuration + 0.001 else { throw ToolError.invalidArguments("Output time exceeds the edited duration.") }
            return timeMap.source(atOutput: ref.seconds)
        default:
            throw ToolError.invalidArguments("basis must be \"source\" or \"output\", not \(ref.basis).")
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
    /// Expected revision. 0 means "do not check".
    public var revision: Int = 0
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
    self.revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
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
    public var padding: Double = -1
    public var cornerRadius: Double = -1
    public var shadow: Double = -1
    public var aspect: Double = 0
    public var wallpaperBlur: Double = -1
    public var background: String = ""
    public var backgroundImagePath: String = ""
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
    self.padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? -1
    self.cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? -1
    self.shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? -1
    self.aspect = try c.decodeIfPresent(Double.self, forKey: .aspect) ?? 0
    self.wallpaperBlur = try c.decodeIfPresent(Double.self, forKey: .wallpaperBlur) ?? -1
    self.background = try c.decodeIfPresent(String.self, forKey: .background) ?? ""
    self.backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath) ?? ""
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

        register(ToolDefinition<TimelinePatchInput>(name: "timeline_patch",
            description: "Applies typed operations to a timeline. Supported ops: zoom_add, zoom_set, zoom_remove, cut_add, cut_remove, ramp_set, ramp_remove, style_set, audio_lane_add, audio_lane_remove, music_set, captions_set, privacy_set. Pass the revision you read to be sure nobody else changed the project.",
            capability: .edit, required: ["project_id", "ops"], mutating: true,
            schema: ToolSchemas.timelinePatch) { input, ctx in
                let expect = input.revision > 0 ? input.revision : nil
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
            capability: .edit, required: ["project_id"], mutating: true) { input, ctx in
                let result = try await ctx.engine.undo(projectID: input.projectID)
                return .object(result)
            })

        register(ToolDefinition<ZoomAddInput>(name: "zoom_add",
            description: "Adds a manual zoom. start and end are source seconds unless basis is \"output\". Manual zooms survive an auto replan.",
            capability: .edit, required: ["project_id", "start", "end"], mutating: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "manual zoom") { timeline in
                    // AGENT: zoom times are stored in source seconds; honour the caller's basis.
                    let start = try timeline.sourceSeconds(TimeRef(seconds: input.start, basis: input.basis))
                    let end = try timeline.sourceSeconds(TimeRef(seconds: input.end, basis: input.basis))
                    // AGENT: reject invalid ranges and route zoom edits through the editor reducer.
                    guard end > start, input.scale.isFinite, (1.1...4).contains(input.scale) else { throw ToolError.invalidArguments("Need start < end and zoom scale 1.1…4.") }
                    try applyCommand(.addZoom(ZoomSegment(start: start, end: end, scale: input.scale,
                                                          focus: self.focus(from: input.focusMode, x: input.focusX, y: input.focusY),
                                                          origin: .manual)), to: &timeline)
                }
                return .object(result)
            })

        register(ToolDefinition<ZoomRemoveInput>(name: "zoom_remove",
            description: "Removes a zoom by its id.",
            capability: .edit, required: ["project_id", "id"], mutating: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "remove zoom") { timeline in
                    // AGENT: deleting an auto zoom must survive the next replan.
                    for zoom in timeline.zoom where zoom.id.uuidString == input.id && zoom.origin == .auto {
                        timeline.suppressedAuto.append(zoom.id.uuidString)
                    }
                    timeline.zoom.removeAll { $0.id.uuidString == input.id }
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
            capability: .edit, required: ["project_id", "start", "end"], mutating: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "cut") { timeline in
                    let start = try timeline.sourceSeconds(TimeRef(seconds: input.start, basis: input.basis))
                    let end = try timeline.sourceSeconds(TimeRef(seconds: input.end, basis: input.basis))
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
                    let start = try timeline.sourceSeconds(TimeRef(seconds: input.start, basis: input.basis))
                    let end = try timeline.sourceSeconds(TimeRef(seconds: input.end, basis: input.basis))
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
                    if input.padding >= 0 { timeline.style.padding = input.padding }
                    if input.cornerRadius >= 0 { timeline.style.cornerRadius = input.cornerRadius }
                    if input.shadow >= 0 { timeline.style.shadow = input.shadow }
                    if input.aspect > 0 { timeline.style.customAspect = input.aspect }
                    if input.wallpaperBlur >= 0 { timeline.style.wallpaperBlur = input.wallpaperBlur }
                    if !input.background.isEmpty {
                        timeline.style.background = try self.backgroundKind(input.background)
                    }
                    if !input.backgroundImagePath.isEmpty {
                        // AGENT: an unconfined image path let an agent read any file the user owns.
                        let url = try ctx.paths.path(input.backgroundImagePath, ext: PathGuard.imageExt)
                        timeline.style.setPhotoBackground(url.path)
                    }
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
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "background") { timeline in
                    if !input.imagePath.isEmpty {
                        // AGENT: confine the image to the client's approved folders.
                        let url = try ctx.paths.path(input.imagePath, ext: PathGuard.imageExt)
                        timeline.style.setPhotoBackground(url.path)
                    } else if !input.background.isEmpty {
                        timeline.style.background = try self.backgroundKind(input.background)
                    }
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
                    timeline.captions.enabled = input.enabled
                    if !input.locale.isEmpty { timeline.captions.locale = input.locale }
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
                    for (id, approved) in input.decisions {
                        timeline.overlays.privacy.decisions[id] = approved
                    }
                }
                return .object(result)
            })
    }

    /// Applies one typed operation to a timeline.
    func apply(_ op: PatchOp, to timeline: inout Timeline, paths: PathGuard) throws {
        func need<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else {
                throw ToolError.invalidArguments("\(op.op) needs \(name). See the timeline_patch schema.")
            }
            return value
        }
        switch op.op {
        case "zoom_add":
            let start = try need(op.start, "start"), end = try need(op.end, "end")
            timeline.zoom.append(ZoomSegment(start: start, end: end, scale: op.scale ?? 2,
                                            focus: focus(from: op.focusMode ?? "follow",
                                                         x: op.focusX ?? 0.5, y: op.focusY ?? 0.5),
                                            origin: .manual))
        case "zoom_set":
            let id = try need(op.id, "id")
            guard let index = timeline.zoom.firstIndex(where: { $0.id.uuidString == id }) else {
                throw ToolError.failed("No zoom with id \(id).")
            }
            if let start = op.start, let end = op.end, end > start {
                timeline.zoom[index].start = start
                timeline.zoom[index].end = end
            } else if (op.start == nil) != (op.end == nil) {
                throw ToolError.invalidArguments("zoom_set needs both start and end, or neither.")
            }
            if let scale = op.scale, scale > 0 { timeline.zoom[index].scale = scale }
            if op.focusMode != nil || op.focusX != nil || op.focusY != nil {
                timeline.zoom[index].focus = focus(from: op.focusMode ?? "follow",
                                                   x: op.focusX ?? 0.5, y: op.focusY ?? 0.5)
            }
            // AGENT: edited automatic zooms must survive the next planner pass.
            timeline.zoom[index].origin = .manual
        case "zoom_remove":
            let id = try need(op.id, "id")
            // AGENT: deleting an auto zoom must survive the next replan.
            for zoom in timeline.zoom where zoom.id.uuidString == id && zoom.origin == .auto {
                timeline.suppressedAuto.append(zoom.id.uuidString)
            }
            timeline.zoom.removeAll { $0.id.uuidString == id }
        case "cut_add":
            let start = try need(op.start, "start"), end = try need(op.end, "end")
            guard end > start else {
                throw ToolError.invalidArguments("cut_add needs end after start, in source seconds.")
            }
            timeline.timeMap.cuts.append(CutRange(start: start, end: end, origin: .manual))
        case "cut_remove":
            let id = try need(op.id, "id")
            timeline.timeMap.cuts.removeAll { $0.id.uuidString == id }
        case "ramp_set":
            let start = try need(op.start, "start"), end = try need(op.end, "end")
            // AGENT: validate speed before rebuilding the time map.
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  (op.speed ?? 2).isFinite, (0.25...16).contains(op.speed ?? 2) else {
                throw ToolError.invalidArguments("ramp_set needs end after start, in source seconds.")
            }
            timeline.timeMap.ramps.append(SpeedRamp(start: start, end: end,
                                                    speed: op.speed ?? 2, origin: .manual))
        case "ramp_remove":
            let id = try need(op.id, "id")
            // AGENT: remember deleted automatic ramps before the planner regenerates them.
            for ramp in timeline.timeMap.ramps where ramp.id.uuidString == id && ramp.origin == .auto {
                if !timeline.suppressedAuto.contains(id) { timeline.suppressedAuto.append(id) }
            }
            timeline.timeMap.ramps.removeAll { $0.id.uuidString == id }
        case "style_set":
            let key = try need(op.key, "key")
            switch key {
            case "padding": timeline.style.padding = try need(op.value, "value")
            case "corner_radius": timeline.style.cornerRadius = try need(op.value, "value")
            case "shadow": timeline.style.shadow = try need(op.value, "value")
            case "aspect": timeline.style.customAspect = try need(op.value, "value")
            case "wallpaper_blur": timeline.style.wallpaperBlur = try need(op.value, "value")
            case "background": timeline.style.background = try backgroundKind(try need(op.text, "text"))
            case "background_image":
                // AGENT: unconfined, this read any image on disk and shipped it in the export.
                let path = try need(op.text, "text")
                timeline.style.setPhotoBackground(try paths.path(path, ext: PathGuard.imageExt).path)
            default:
                throw ToolError.invalidArguments(
                    "Unknown style key \(key). Use padding, corner_radius, shadow, aspect, wallpaper_blur, background or background_image.")
            }
        case "audio_lane_add":
            // AGENT: an unconfined audio path leaked any local file into the project.
            let lanePath = try op.key.map { try paths.path($0, ext: PathGuard.audioExt).path }
            timeline.audio.lanes.append(AudioLane(role: AudioLane.Role(rawValue: op.text ?? "") ?? .voiceover,
                                                  path: lanePath,
                                                  placement: op.start ?? 0, gainDb: op.value ?? 0))
        case "audio_lane_remove":
            let id = try need(op.id, "id")
            timeline.audio.lanes.removeAll { $0.id.uuidString == id }
        case "music_set":
            // AGENT: confine music to the approved folders and audio extensions.
            let text = try need(op.text, "text")
            timeline.audio.musicPath = text.isEmpty ? nil : try paths.path(text, ext: PathGuard.audioExt).path
            if let value = op.value { timeline.audio.musicGainDb = value }
        case "captions_set":
            timeline.captions.enabled = try need(op.flag, "flag")
            if let locale = op.text, !locale.isEmpty { timeline.captions.locale = locale }
        case "privacy_set":
            let key = try need(op.key, "key")
            switch key {
            case "enabled": timeline.overlays.privacy.enabled = try need(op.flag, "flag")
            case "auto_detect": timeline.overlays.privacy.autoDetect = try need(op.flag, "flag")
            case "mode":
                let text = try need(op.text, "text")
                guard let mode = MaskMode(rawValue: text) else {
                    throw ToolError.invalidArguments(
                        "Unknown privacy mode \(text). Valid values: \(MaskMode.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                timeline.overlays.privacy.mode = mode
            case "padding": timeline.overlays.privacy.padding = try need(op.value, "value")
            default:
                throw ToolError.invalidArguments(
                    "Unknown privacy key \(key). Use enabled, auto_detect, mode or padding.")
            }
        default:
            throw ToolError.invalidArguments("Unknown timeline op \(op.op).")
        }
    }

    private func focus(from mode: String, x: Double, y: Double) -> Focus {
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
