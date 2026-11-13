import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LumenCore
import LumenProject
import LumenExport
import LumenAudio

// MARK: - Audio tools

public struct AudioImportInput: ToolInput {
    public var projectID: String = ""
    public var path: String = ""
    /// music | voiceover | sfx
    public var role: String = "voiceover"
    /// Anchor the clip to a marker id.
    public var atMarker: String = ""
    /// Or to an absolute output time.
    public var atOutput: Double = -1
    public var offsetMs: Double = 0
    public var gainDb: Double = 0
    public var loop: Bool = false
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case path
    case role
    case atMarker = "at_marker"
    case atOutput = "at_output"
    case offsetMs = "offset_ms"
    case gainDb = "gain_db"
    case loop
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
    self.role = try c.decodeIfPresent(String.self, forKey: .role) ?? "voiceover"
    self.atMarker = try c.decodeIfPresent(String.self, forKey: .atMarker) ?? ""
    self.atOutput = try c.decodeIfPresent(Double.self, forKey: .atOutput) ?? -1
    self.offsetMs = try c.decodeIfPresent(Double.self, forKey: .offsetMs) ?? 0
    self.gainDb = try c.decodeIfPresent(Double.self, forKey: .gainDb) ?? 0
    self.loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false
    }
}

public struct AudioMixSetInput: ToolInput {
    public var projectID: String = ""
    public var targetLUFS: Double = 0
    public var musicGainDb: Double = -1000
    public var micGainDb: Double = -1000
    public var outputGainDb: Double = -1000
    public var duckDepthDb: Double = -1000
    public var normalize: Bool = false
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case targetLUFS = "target_lufs"
    case musicGainDb = "music_gain_db"
    case micGainDb = "mic_gain_db"
    case outputGainDb = "output_gain_db"
    case duckDepthDb = "duck_depth_db"
    case normalize
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.targetLUFS = try c.decodeIfPresent(Double.self, forKey: .targetLUFS) ?? 0
    self.musicGainDb = try c.decodeIfPresent(Double.self, forKey: .musicGainDb) ?? -1000
    self.micGainDb = try c.decodeIfPresent(Double.self, forKey: .micGainDb) ?? -1000
    self.outputGainDb = try c.decodeIfPresent(Double.self, forKey: .outputGainDb) ?? -1000
    self.duckDepthDb = try c.decodeIfPresent(Double.self, forKey: .duckDepthDb) ?? -1000
    self.normalize = try c.decodeIfPresent(Bool.self, forKey: .normalize) ?? false
    }
}

public struct VoiceoverGenerateInput: ToolInput {
    public var projectID: String = ""
    public var text: String = ""
    public var voice: String = ""
    public var model: String = ""
    public var atMarker: String = ""
    public var atOutput: Double = -1
    public var offsetMs: Double = 0
    public var gainDb: Double = 0
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case text
    case voice
    case model
    case atMarker = "at_marker"
    case atOutput = "at_output"
    case offsetMs = "offset_ms"
    case gainDb = "gain_db"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    self.voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
    self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
    self.atMarker = try c.decodeIfPresent(String.self, forKey: .atMarker) ?? ""
    self.atOutput = try c.decodeIfPresent(Double.self, forKey: .atOutput) ?? -1
    self.offsetMs = try c.decodeIfPresent(Double.self, forKey: .offsetMs) ?? 0
    self.gainDb = try c.decodeIfPresent(Double.self, forKey: .gainDb) ?? 0
    }
}

// MARK: - Verify tools

public struct PreviewFrameInput: ToolInput {
    public var projectID: String = ""
    public var time: Double = 0
    public var maxWidth: Int = 960
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case time
    case maxWidth = "max_width"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.time = try c.decodeIfPresent(Double.self, forKey: .time) ?? 0
    self.maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth) ?? 960
    }
}

public struct PreviewSheetInput: ToolInput {
    public var projectID: String = ""
    public var frames: Int = 6
    public var duration: Double = 0
    public var maxWidth: Int = 480
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case frames
    case duration
    case maxWidth = "max_width"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.frames = try c.decodeIfPresent(Int.self, forKey: .frames) ?? 6
    self.duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
    self.maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth) ?? 480
    }
}

public struct QAReportInput: ToolInput {
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

// MARK: - Export tools

public struct ExportStartInput: ToolInput {
    public var projectID: String = ""
    public var preset: String = "1080p30-h264"
    public var output: String = ""
    public var includeAudio: Bool = true
    public var exportStems: Bool = false
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case preset
    case output
    case includeAudio = "include_audio"
    case exportStems = "export_stems"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? "1080p30-h264"
    self.output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
    self.includeAudio = try c.decodeIfPresent(Bool.self, forKey: .includeAudio) ?? true
    self.exportStems = try c.decodeIfPresent(Bool.self, forKey: .exportStems) ?? false
    }
}

public struct JobStatusInput: ToolInput {
    public var jobID: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case jobID = "job_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.jobID = try c.decodeIfPresent(String.self, forKey: .jobID) ?? ""
    }
}

public struct ExportCancelInput: ToolInput {
    public var jobID: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case jobID = "job_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.jobID = try c.decodeIfPresent(String.self, forKey: .jobID) ?? ""
    }
}

public extension ToolRegistry {
    func registerMediaTools() {
        register(ToolDefinition<AudioImportInput>(name: "audio_import",
            description: "Adds an MP3, WAV or M4A to a project: music, voice-over or a sound effect. Anchor it to a marker or to an output time.",
            capability: .edit, required: ["project_id", "path"], mutating: true) { input, ctx in
                // AGENT: audio paths are confined and must be audio files.
                let url = try ctx.paths.path(input.path, ext: PathGuard.audioExt)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ToolError.failed("No file at \(url.path).")
                }
                let role = input.role
                let placement = try await self.resolvePlacement(projectID: input.projectID, ctx: ctx,
                                                          atMarker: input.atMarker, atOutput: input.atOutput,
                                                          offsetMs: input.offsetMs)
                if ctx.dryRun {
                    return .object(["dry_run": .bool(true), "path": .string(url.path),
                                    "role": .string(role), "placement": .number(placement)])
                }
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "import \(role)") { timeline in
                    if role == "music" {
                        timeline.audio.musicPath = url.path
                        if input.gainDb != 0 { timeline.audio.musicGainDb = input.gainDb }
                    } else {
                        timeline.audio.lanes.append(AudioLane(role: role == "sfx" ? .sfx : .voiceover,
                                                              path: url.path, placement: placement,
                                                              gainDb: input.gainDb))
                    }
                }
                return .object(result)
            })

        register(ToolDefinition<AudioMixSetInput>(name: "audio_mix_set",
            description: "Sets the mix: target loudness, music gain, microphone gain, output gain and how deep music ducks under speech.",
            capability: .edit, required: ["project_id"], mutating: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "mix settings") { timeline in
                    if input.targetLUFS != 0 { timeline.audio.targetLUFSOverride = input.targetLUFS }
                    if input.musicGainDb > -999 { timeline.audio.musicGainDb = input.musicGainDb }
                    if input.micGainDb > -999 { timeline.audio.micGainDb = input.micGainDb }
                    if input.outputGainDb > -999 { timeline.audio.outputGainDb = input.outputGainDb }
                    if input.duckDepthDb > -999 { timeline.audio.duckDepthDb = input.duckDepthDb }
                    if input.normalize { timeline.audio.normalize = true }
                }
                return .object(result)
            })

        register(ToolDefinition<VoiceoverGenerateInput>(name: "voiceover_generate",
            description: "Generates narration with the configured voice provider and lays it on the timeline. This makes a network call and says so in the result. Needs the network capability.",
            capability: .network, required: ["project_id", "text"], mutating: true) { input, ctx in
                let placement = try await self.resolvePlacement(projectID: input.projectID, ctx: ctx,
                                                          atMarker: input.atMarker, atOutput: input.atOutput,
                                                          offsetMs: input.offsetMs)
                let provider = DefaultVoiceProvider(cacheDirectory: ctx.engine.cacheDirectory(projectID: input.projectID))
                let generated = try await provider.generate(text: input.text, voice: input.voice, model: input.model)
                let url = ctx.engine.cacheDirectory(projectID: input.projectID)
                    .appendingPathComponent("voiceover-" + UUID().uuidString + ".mp3")
                try generated.data.write(to: url)
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "voice-over") { timeline in
                    timeline.audio.lanes.append(AudioLane(role: .voiceover, path: url.path,
                                                          placement: placement, gainDb: input.gainDb))
                }
                var payload = result
                payload["network"] = .string(generated.disclosure)
                payload["audio_path"] = .string(url.path)
                return .object(payload)
            })

        register(ToolDefinition<PreviewFrameInput>(name: "preview_frame",
            description: "Renders one frame of the project and returns it as a PNG so you can SEE what you are editing.",
            capability: .read, required: ["project_id"]) { input, ctx in
                let (png, name) = try await ctx.engine.previewFrame(projectID: input.projectID,
                                                                    time: input.time,
                                                                    maxWidth: input.maxWidth)
                return .object(["image_base64": .string(png.base64EncodedString()),
                                "mime_type": .string("image/png"),
                                "name": .string(name),
                                "time": .number(input.time)])
            })

        register(ToolDefinition<PreviewSheetInput>(name: "preview_sheet",
            description: "Renders N frames across the project as one contact sheet PNG.",
            capability: .read, required: ["project_id"]) { input, ctx in
                let sheet = try await ctx.engine.previewSheet(projectID: input.projectID, frames: input.frames,
                                                              duration: input.duration, maxWidth: input.maxWidth)
                return .object(["image_base64": .string(sheet.base64EncodedString()),
                                "mime_type": .string("image/png"),
                                "frames": .int(input.frames)])
            })

        register(ToolDefinition<QAReportInput>(name: "qa_report",
            description: "Checks the project and returns pass/fail per check: zoom arrival and centring, unmasked sensitive text, loudness, silence, dropped frames. Loop on this before exporting.",
            capability: .read, required: ["project_id"]) { input, ctx in
                try await ctx.engine.qaReport(projectID: input.projectID)
            })

        register(ToolDefinition<ExportStartInput>(name: "export_start",
            description: "Exports the project to a file. Returns a job id; poll with job_status. Refuses to export while a privacy scan is unresolved.",
            capability: .export, required: ["project_id"], mutating: true) { input, ctx in
                let output = input.output.isEmpty
                    ? (ctx.engine.knownProjects().first { $0.identifier == input.projectID }?.url
                        .deletingLastPathComponent().appendingPathComponent(input.projectID + ".mp4").path ?? "")
                    : input.output
                guard !output.isEmpty else { throw ToolError.invalidArguments("Give an output path.") }
                // AGENT: the file does not exist yet, so confine its parent instead of the path.
                let resolved = try ctx.paths.writablePath(output, ext: PathGuard.videoExt)
                let job = try await ctx.engine.startExport(projectID: input.projectID, presetName: input.preset,
                                                          outputPath: resolved.path,
                                                          includeAudio: input.includeAudio,
                                                          exportStems: input.exportStems)
                return .object(["job_id": .string(job), "output": .string(resolved.path)])
            })

        register(ToolDefinition<JobStatusInput>(name: "job_status",
            description: "Reports the progress and result of a job started by export_start, privacy_scan or captions_generate.",
            capability: .read, required: ["job_id"]) { input, ctx in
                guard let job = ctx.jobs.job(input.jobID) else {
                    throw ToolError.failed("No job with id \(input.jobID).")
                }
                return .object([
                    "job_id": .string(job.id),
                    "kind": .string(job.kind),
                    "state": .string(job.state.rawValue),
                    "progress": .number(job.progress),
                    "message": job.message.map { .string($0) } ?? .null,
                    "result": job.result ?? .null,
                    "error": job.error.map { .string($0) } ?? .null,
                ])
            })

        register(ToolDefinition<ExportCancelInput>(name: "export_cancel",
            description: "Cancels a running job.",
            capability: .export, required: ["job_id"], mutating: true) { input, ctx in
                let cancelled = ctx.jobs.cancel(input.jobID)
                return .object(["job_id": .string(input.jobID), "cancelled": .bool(cancelled)])
            })
    }

    /// Marker- or time-based placement, in output seconds.
    private func resolvePlacement(projectID: String, ctx: ToolContext, atMarker: String, atOutput: Double,
                                  offsetMs: Double) async throws -> Double {
        if !atMarker.isEmpty {
            let markers = try await ctx.engine.markersValue(projectID: projectID)
            let rows = markers["markers"]?.arrayValue ?? []
            for row in rows {
                if row["id"]?.stringValue == atMarker {
                    let source = row["source_start"]?.doubleValue ?? 0
                    return source + offsetMs / 1000
                }
            }
            throw ToolError.failed("No marker named \(atMarker). Call timeline_get markers first.")
        }
        if atOutput >= 0 { return atOutput + offsetMs / 1000 }
        return offsetMs / 1000
    }
}
