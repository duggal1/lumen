import Foundation
import LumenCore
import LumenProject
import LumenDirector
import LumenExport
import LumenAudio
import LumenSpeech

// MARK: - Project and timeline tools

public struct ProjectListInput: ToolInput {
    public init() {}
}

public struct ProjectOpenInput: ToolInput {
    public var path: String = ""
    public init() {}
}

public struct TimelineGetInput: ToolInput {
    public var projectID: String = ""
    public init() {}
}

/// One typed timeline operation. Flat and explicit so an agent cannot send
/// an expression it does not understand.
public struct PatchOp: Codable, Sendable {
    public var op: String = ""
    public var id: String = ""
    public var start: Double = 0
    public var end: Double = 0
    public var scale: Double = 2
    public var focusMode: String = "follow"
    public var focusX: Double = 0.5
    public var focusY: Double = 0.5
    public var speed: Double = 2
    public var key: String = ""
    public var value: Double = 0
    public var text: String = ""
    public var flag: Bool = true
    public init() {}
}

public struct TimelinePatchInput: ToolInput {
    public var projectID: String = ""
    /// Expected revision. 0 means "do not check".
    public var revision: Int = 0
    public var ops: [PatchOp] = []
    public init() {}
}

public struct UndoInput: ToolInput {
    public var projectID: String = ""
    public init() {}
}

public struct ZoomAddInput: ToolInput {
    public var projectID: String = ""
    public var start: Double = 0
    public var end: Double = 0
    public var scale: Double = 2
    public var focusMode: String = "follow"
    public var focusX: Double = 0.5
    public var focusY: Double = 0.5
    public init() {}
}

public struct ZoomRemoveInput: ToolInput {
    public var projectID: String = ""
    public var id: String = ""
    public init() {}
}

public struct ZoomReplanInput: ToolInput {
    public var projectID: String = ""
    public init() {}
}

public struct CutRangeInput: ToolInput {
    public var projectID: String = ""
    public var start: Double = 0
    public var end: Double = 0
    public init() {}
}

public struct SpeedRampInput: ToolInput {
    public var projectID: String = ""
    public var start: Double = 0
    public var end: Double = 0
    public var speed: Double = 2
    public init() {}
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
}

public struct BackgroundListInput: ToolInput {
    public init() {}
}

public struct BackgroundSetInput: ToolInput {
    public var projectID: String = ""
    public var background: String = ""
    public var imagePath: String = ""
    public init() {}
}

public struct CaptionsGenerateInput: ToolInput {
    public var projectID: String = ""
    public var locale: String = "en-US"
    public init() {}
}

public struct CaptionsSetInput: ToolInput {
    public var projectID: String = ""
    public var enabled: Bool = true
    public var locale: String = ""
    public init() {}
}

public struct PrivacyScanInput: ToolInput {
    public var projectID: String = ""
    public init() {}
}

public struct PrivacyApplyInput: ToolInput {
    public var projectID: String = ""
    /// mask id -> approved
    public var decisions: [String: Bool] = [:]
    public init() {}
}

public extension ToolRegistry {
    func registerProjectTools() {
        register(ToolDefinition<ProjectListInput>(name: "project_list",
            description: "Lists the recordings in the Lumen library with their ids and paths.",
            capability: .read) { _, ctx in
                let library = await ctx.engine.runtime.recordingLibrary()
                let rows = library.map { url -> JSONValue in
                    .object(["project_id": .string(url.deletingPathExtension().lastPathComponent),
                             "path": .string(url.path)])
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
            capability: .edit, required: ["project_id"]) { input, ctx in
                let expect = input.revision > 0 ? input.revision : nil
                if ctx.dryRun {
                    return .object(["dry_run": .bool(true), "ops": .int(input.ops.count),
                                    "project_id": .string(input.projectID)])
                }
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: expect,
                                                      describe: "\(input.ops.count) timeline operations") { timeline in
                    for op in input.ops { try self.apply(op, to: &timeline) }
                }
                return .object(result)
            })

        register(ToolDefinition<UndoInput>(name: "undo",
            description: "Undoes the last agent edit on a project.",
            capability: .edit, required: ["project_id"]) { input, ctx in
                let result = try await ctx.engine.undo(projectID: input.projectID)
                return .object(result)
            })

        register(ToolDefinition<ZoomAddInput>(name: "zoom_add",
            description: "Adds a manual zoom. Manual zooms survive an auto replan.",
            capability: .edit, required: ["project_id", "start", "end"]) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "manual zoom") { timeline in
                    timeline.zoom.append(ZoomSegment(start: input.start, end: input.end, scale: input.scale,
                                                    focus: self.focus(from: input.focusMode, x: input.focusX, y: input.focusY),
                                                    origin: .manual))
                }
                return .object(result)
            })

        register(ToolDefinition<ZoomRemoveInput>(name: "zoom_remove",
            description: "Removes a zoom by its id.",
            capability: .edit, required: ["project_id", "id"]) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "remove zoom") { timeline in
                    timeline.zoom.removeAll { $0.id.uuidString == input.id }
                }
                return .object(result)
            })

        register(ToolDefinition<ZoomReplanInput>(name: "zoom_replan",
            description: "Re-runs the automatic zoom planner over the recorded input. Manual zooms are kept.",
            capability: .edit, required: ["project_id"]) { input, ctx in
                let result = try await ctx.engine.replanZoom(projectID: input.projectID)
                return .object(result)
            })

        register(ToolDefinition<CutRangeInput>(name: "cut_range",
            description: "Cuts a span out of the recording, in source seconds.",
            capability: .edit, required: ["project_id", "start", "end"]) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "cut") { timeline in
                    timeline.timeMap.cuts.append(CutRange(start: input.start, end: input.end, origin: .manual))
                }
                return .object(result)
            })

        register(ToolDefinition<SpeedRampInput>(name: "speed_ramp_set",
            description: "Sets a speed ramp over a source range. 2.0 plays twice as fast.",
            capability: .edit, required: ["project_id", "start", "end"]) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "speed ramp") { timeline in
                    timeline.timeMap.ramps.append(SpeedRamp(start: input.start, end: input.end,
                                                            speed: input.speed, origin: .manual))
                }
                return .object(result)
            })

        register(ToolDefinition<StyleSetInput>(name: "style_set",
            description: "Sets the canvas style: padding, corner radius, shadow, aspect ratio, wallpaper blur and background.",
            capability: .edit, required: ["project_id"]) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "style") { timeline in
                    if input.padding >= 0 { timeline.style.padding = input.padding }
                    if input.cornerRadius >= 0 { timeline.style.cornerRadius = input.cornerRadius }
                    if input.shadow >= 0 { timeline.style.shadow = input.shadow }
                    if input.aspect > 0 { timeline.style.customAspect = input.aspect }
                    if input.wallpaperBlur >= 0 { timeline.style.wallpaperBlur = input.wallpaperBlur }
                    if !input.background.isEmpty, let kind = BackgroundKind(rawValue: input.background) {
                        timeline.style.background = kind
                    }
                    if !input.backgroundImagePath.isEmpty {
                        timeline.style.setPhotoBackground(input.backgroundImagePath)
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
            capability: .edit, required: ["project_id"]) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "background") { timeline in
                    if !input.imagePath.isEmpty {
                        timeline.style.setPhotoBackground(input.imagePath)
                    } else if let kind = BackgroundKind(rawValue: input.background) {
                        timeline.style.background = kind
                    }
                }
                return .object(result)
            })

        register(ToolDefinition<CaptionsGenerateInput>(name: "captions_generate",
            description: "Transcribes the recorded microphone and turns captions on. Needs the local speech model; returns a job id.",
            capability: .edit, required: ["project_id"], longRunning: true) { input, ctx in
                let job = try await ctx.engine.startTranscription(projectID: input.projectID, locale: input.locale)
                return .object(["job_id": .string(job)])
            })

        register(ToolDefinition<CaptionsSetInput>(name: "captions_set",
            description: "Turns captions on or off and sets their locale.",
            capability: .edit, required: ["project_id"]) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "captions") { timeline in
                    timeline.captions.enabled = input.enabled
                    if !input.locale.isEmpty { timeline.captions.locale = input.locale }
                }
                return .object(result)
            })

        register(ToolDefinition<PrivacyScanInput>(name: "privacy_scan",
            description: "Runs the privacy scan over a recording and applies automatic masks. Returns a job id; poll it with job_status.",
            capability: .edit, required: ["project_id"], longRunning: true) { input, ctx in
                let job = try await ctx.engine.startPrivacyScan(projectID: input.projectID)
                return .object(["job_id": .string(job)])
            })

        register(ToolDefinition<PrivacyApplyInput>(name: "privacy_apply",
            description: "Approves or rejects automatic masks by id. Approving a mask keeps it; rejecting removes it.",
            capability: .edit, required: ["project_id"]) { input, ctx in
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
    func apply(_ op: PatchOp, to timeline: inout Timeline) throws {
        switch op.op {
        case "zoom_add":
            timeline.zoom.append(ZoomSegment(start: op.start, end: op.end, scale: op.scale,
                                            focus: focus(from: op.focusMode, x: op.focusX, y: op.focusY),
                                            origin: .manual))
        case "zoom_set":
            guard let index = timeline.zoom.firstIndex(where: { $0.id.uuidString == op.id }) else {
                throw ToolError.failed("No zoom with id \(op.id).")
            }
            if op.end > op.start { timeline.zoom[index].start = op.start; timeline.zoom[index].end = op.end }
            if op.scale > 0 { timeline.zoom[index].scale = op.scale }
            timeline.zoom[index].focus = focus(from: op.focusMode, x: op.focusX, y: op.focusY)
        case "zoom_remove":
            timeline.zoom.removeAll { $0.id.uuidString == op.id }
        case "cut_add":
            timeline.timeMap.cuts.append(CutRange(start: op.start, end: op.end, origin: .manual))
        case "cut_remove":
            timeline.timeMap.cuts.removeAll { $0.id.uuidString == op.id }
        case "ramp_set":
            timeline.timeMap.ramps.append(SpeedRamp(start: op.start, end: op.end, speed: op.speed, origin: .manual))
        case "ramp_remove":
            timeline.timeMap.ramps.removeAll { $0.id.uuidString == op.id }
        case "style_set":
            if op.key == "padding" { timeline.style.padding = op.value }
            else if op.key == "corner_radius" { timeline.style.cornerRadius = op.value }
            else if op.key == "shadow" { timeline.style.shadow = op.value }
            else if op.key == "aspect" { timeline.style.customAspect = op.value }
            else if op.key == "wallpaper_blur" { timeline.style.wallpaperBlur = op.value }
            else if op.key == "background", let kind = BackgroundKind(rawValue: op.text) { timeline.style.background = kind }
            else if op.key == "background_image" { timeline.style.setPhotoBackground(op.text) }
        case "audio_lane_add":
            timeline.audio.lanes.append(AudioLane(role: AudioLane.Role(rawValue: op.text) ?? .voiceover,
                                                  path: op.key.isEmpty ? nil : op.key,
                                                  placement: op.start, gainDb: op.value))
        case "audio_lane_remove":
            timeline.audio.lanes.removeAll { $0.id.uuidString == op.id }
        case "music_set":
            timeline.audio.musicPath = op.text.isEmpty ? nil : op.text
            if op.value != 0 { timeline.audio.musicGainDb = op.value }
        case "captions_set":
            timeline.captions.enabled = op.flag
            if !op.text.isEmpty { timeline.captions.locale = op.text }
        case "privacy_set":
            if op.key == "enabled" { timeline.overlays.privacy.enabled = op.flag }
            else if op.key == "auto_detect" { timeline.overlays.privacy.autoDetect = op.flag }
            else if op.key == "mode", let mode = MaskMode(rawValue: op.text) { timeline.overlays.privacy.mode = mode }
            else if op.key == "padding" { timeline.overlays.privacy.padding = op.value }
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
}
