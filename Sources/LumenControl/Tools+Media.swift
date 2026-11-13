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
    // AGENT: optional placement fields replace the -1 sentinel so output time zero remains a valid value.
    public var atMarker: String?
    /// Or to an absolute output time.
    public var atOutput: Double?
    public var offsetMs: Double = 0
    // AGENT: zero is a valid gain, so omission cannot use it as an unset sentinel.
    public var gainDb: Double?
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
    self.atMarker = try c.decodeIfPresent(String.self, forKey: .atMarker)
    self.atOutput = try c.decodeIfPresent(Double.self, forKey: .atOutput)
    self.offsetMs = try c.decodeIfPresent(Double.self, forKey: .offsetMs) ?? 0
    self.gainDb = try c.decodeIfPresent(Double.self, forKey: .gainDb)
    self.loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false
    }
}

public struct AudioMixSetInput: ToolInput {
    public var projectID: String = ""
    // AGENT: omitted mix fields must leave the mix untouched, and normalize must support an explicit false.
    public var targetLUFS: Double?
    public var musicGainDb: Double?
    public var micGainDb: Double?
    public var outputGainDb: Double?
    public var duckDepthDb: Double?
    public var normalize: Bool?
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
    self.targetLUFS = try c.decodeIfPresent(Double.self, forKey: .targetLUFS)
    self.musicGainDb = try c.decodeIfPresent(Double.self, forKey: .musicGainDb)
    self.micGainDb = try c.decodeIfPresent(Double.self, forKey: .micGainDb)
    self.outputGainDb = try c.decodeIfPresent(Double.self, forKey: .outputGainDb)
    self.duckDepthDb = try c.decodeIfPresent(Double.self, forKey: .duckDepthDb)
    self.normalize = try c.decodeIfPresent(Bool.self, forKey: .normalize)
    }
}

public struct VoiceoverGenerateInput: ToolInput {
    public var projectID: String = ""
    public var text: String = ""
    public var voice: String = ""
    public var model: String = ""
    // AGENT: optional placement fields replace the -1 sentinel so output time zero remains valid.
    public var atMarker: String?
    public var atOutput: Double?
    public var offsetMs: Double = 0
    // AGENT: zero is a valid gain, so omission cannot use it as an unset sentinel.
    public var gainDb: Double?
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
    self.atMarker = try c.decodeIfPresent(String.self, forKey: .atMarker)
    self.atOutput = try c.decodeIfPresent(Double.self, forKey: .atOutput)
    self.offsetMs = try c.decodeIfPresent(Double.self, forKey: .offsetMs) ?? 0
    self.gainDb = try c.decodeIfPresent(Double.self, forKey: .gainDb)
    }
}

// MARK: - Verify tools

public struct PreviewFrameInput: ToolInput {
    public var projectID: String = ""
    public var time: Double = 0
    public var maxWidth: Int = 960
    // AGENT: compact JPEG is the default; callers can request lossless PNG.
    public var png = false
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case time
    case maxWidth = "max_width"
    case png
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.time = try c.decodeIfPresent(Double.self, forKey: .time) ?? 0
    self.maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth) ?? 960
    self.png = try c.decodeIfPresent(Bool.self, forKey: .png) ?? false
    }
}

public struct PreviewSheetInput: ToolInput {
    public var projectID: String = ""
    public var frames: Int = 6
    public var duration: Double = 0
    public var maxWidth: Int = 480
    // AGENT: let callers request a lossless sheet when necessary.
    public var png = false
    public init() {}

    enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case frames
    case duration
    case maxWidth = "max_width"
    case png
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
    self.frames = try c.decodeIfPresent(Int.self, forKey: .frames) ?? 6
    self.duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
    self.maxWidth = try c.decodeIfPresent(Int.self, forKey: .maxWidth) ?? 480
    self.png = try c.decodeIfPresent(Bool.self, forKey: .png) ?? false
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
    // AGENT: bounded long polling prevents clients from hammering the daemon for progress.
    public var waitMs: Int = 0
    public init() {}

    enum CodingKeys: String, CodingKey {
    case jobID = "job_id"
    case waitMs = "wait_ms"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.jobID = try c.decodeIfPresent(String.self, forKey: .jobID) ?? ""
    self.waitMs = try c.decodeIfPresent(Int.self, forKey: .waitMs) ?? 0
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

/// AGENT: preset discovery avoids making agents infer valid export names from errors.
public struct ExportPresetsInput: ToolInput {
    public init() {}
}

public extension ToolRegistry {
    func registerMediaTools() {
        register(ToolDefinition<ExportPresetsInput>(name: "export_presets",
            description: "Lists supported export preset names and the default preset.",
            capability: .read) { _, _ in
                return .object(["presets": .array(ExportPresets.all.map { .string($0.name) }),
                                "default": .string("1080p30-h264")])
            })

        register(ToolDefinition<AudioImportInput>(name: "audio_import",
            description: "Adds an MP3, WAV or M4A to a project: music, voice-over or a sound effect. Anchor it to a marker or to an output time.",
            capability: .edit, required: ["project_id", "path"], mutating: true) { input, ctx in
                // AGENT: audio paths are confined and must be audio files.
                let url = try ctx.paths.path(input.path, ext: PathGuard.audioExt)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ToolError.failed("No file at \(url.path).")
                }
                let role = input.role
                guard ["music", "voiceover", "sfx"].contains(role) else {
                    throw ToolError.invalidArguments("role must be music, voiceover, or sfx.")
                }
                let placement = try await self.resolvePlacement(projectID: input.projectID, ctx: ctx,
                                                          atMarker: input.atMarker, atOutput: input.atOutput,
                                                          offsetMs: input.offsetMs)
                if ctx.dryRun {
                    return .object(["dry_run": .bool(true), "path": .string(url.path),
                                    "role": .string(role), "placement": .number(placement)])
                }
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "import \(role)") { timeline in
                    var audio = timeline.audio
                    if role == "music" {
                        audio.musicPath = url.path
                        if let gainDb = input.gainDb { audio.musicGainDb = try Self.validated(gainDb, name: "gain_db", range: -60 ... 12) }
                    } else {
                        let laneRole: AudioLane.Role = role == "sfx" ? .sfx : .voiceover
                        let gain = try Self.validated(input.gainDb ?? 0, name: "gain_db", range: -60 ... 12)
                        audio.lanes.append(AudioLane(role: laneRole, path: url.path, placement: placement, gainDb: gain))
                    }
                    try applyCommand(.setAudio(audio), to: &timeline)
                }
                return .object(result)
            })

        register(ToolDefinition<AudioMixSetInput>(name: "audio_mix_set",
            description: "Sets the mix: target loudness, music gain, microphone gain, output gain and how deep music ducks under speech.",
            capability: .edit, required: ["project_id"], mutating: true) { input, ctx in
                let result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: nil,
                                                      describe: "mix settings") { timeline in
                    var audio = timeline.audio
                    if let value = input.targetLUFS { audio.targetLUFSOverride = try Self.validated(value, name: "target_lufs", range: -24 ... -10) }
                    if let value = input.musicGainDb { audio.musicGainDb = try Self.validated(value, name: "music_gain_db", range: -60 ... 12) }
                    if let value = input.micGainDb { audio.micGainDb = try Self.validated(value, name: "mic_gain_db", range: -60 ... 12) }
                    if let value = input.outputGainDb { audio.outputGainDb = try Self.validated(value, name: "output_gain_db", range: -60 ... 12) }
                    if let value = input.duckDepthDb { audio.duckDepthDb = try Self.validated(value, name: "duck_depth_db", range: 0 ... 36) }
                    if let normalize = input.normalize { audio.normalize = normalize }
                    try applyCommand(.setAudio(audio), to: &timeline)
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
                    var audio = timeline.audio
                    let gain = try Self.validated(input.gainDb ?? 0, name: "gain_db", range: -60 ... 12)
                    audio.lanes.append(AudioLane(role: .voiceover, path: url.path,
                                                 placement: placement, gainDb: gain))
                    try applyCommand(.setAudio(audio), to: &timeline)
                }
                var payload = result
                payload["network"] = .string(generated.disclosure)
                payload["audio_path"] = .string(url.path)
                return .object(payload)
            })

        register(ToolDefinition<PreviewFrameInput>(name: "preview_frame",
            description: "Renders one frame as an image. JPEG is the default; set png for lossless output.",
            capability: .read, required: ["project_id"]) { input, ctx in
                let (image, name) = try await ctx.engine.previewFrame(projectID: input.projectID,
                                                                    time: input.time,
                                                                    maxWidth: input.maxWidth, png: input.png)
                var output: [String: JSONValue] = ["image_base64": .string(image.base64EncodedString()),
                                                   "mime_type": .string(input.png ? "image/png" : "image/jpeg"),
                                                   "name": .string(name),
                                                   "time": .number(input.time)]
                // AGENT: frame metadata tells the agent what it received without embedding pixels in JSON.
                if let size = Self.pixelSize(image) {
                    output["width"] = .int(size.width)
                    output["height"] = .int(size.height)
                }
                return .object(output)
            })

        register(ToolDefinition<PreviewSheetInput>(name: "preview_sheet",
            description: "Renders frames across the project as a JPEG contact sheet; set png for lossless output.",
            capability: .read, required: ["project_id"]) { input, ctx in
                let sheet = try await ctx.engine.previewSheet(projectID: input.projectID, frames: input.frames,
                                                              duration: input.duration, maxWidth: input.maxWidth, png: input.png)
                // AGENT: the protocol layer needs the MIME type to return the sheet as an image block.
                var output: [String: JSONValue] = ["image_base64": .string(sheet.base64EncodedString()),
                                                   "mime_type": .string(input.png ? "image/png" : "image/jpeg"),
                                                   "frames": .int(input.frames)]
                if let size = Self.pixelSize(sheet) {
                    output["width"] = .int(size.width)
                    output["height"] = .int(size.height)
                }
                return .object(output)
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
                guard (0...25_000).contains(input.waitMs) else {
                    throw ToolError.invalidArguments("wait_ms must be between 0 and 25000.")
                }
                guard let initial = ctx.jobs.job(input.jobID) else {
                    throw ToolError.failed("No job with id \(input.jobID).")
                }
                var job = initial
                if input.waitMs > 0 && (job.state == .queued || job.state == .running) {
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: .milliseconds(Int64(input.waitMs)))
                    while clock.now < deadline {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(200))
                        guard let latest = ctx.jobs.job(input.jobID) else { break }
                        job = latest
                        if job.updated > initial.updated || (job.state != .queued && job.state != .running) { break }
                    }
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
            capability: .export, required: ["job_id"], mutating: true, destructive: true) { input, ctx in
                let cancelled = ctx.jobs.cancel(input.jobID)
                return .object(["job_id": .string(input.jobID), "cancelled": .bool(cancelled)])
            })
    }

    // AGENT: read actual encoded dimensions instead of assuming the requested render width was honored.
    private static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    /// Marker- or time-based placement, in output seconds.
    private func resolvePlacement(projectID: String, ctx: ToolContext, atMarker: String?, atOutput: Double?,
                                  offsetMs: Double) async throws -> Double {
        guard offsetMs.isFinite else { throw ToolError.invalidArguments("offset_ms must be finite.") }
        if let atMarker, !atMarker.isEmpty, let atOutput {
            throw ToolError.invalidArguments("Choose either at_marker or at_output, not both.")
        }
        if let atMarker, !atMarker.isEmpty {
            let markers = try await ctx.engine.markersValue(projectID: projectID)
            let rows = markers["markers"]?.arrayValue ?? []
            for row in rows {
                if row["id"]?.stringValue == atMarker {
                    let source = row["source_start"]?.doubleValue ?? 0
                    // AGENT: audio placement is output time, so cuts and speed ramps must be applied.
                    return try await ctx.engine.outputTime(projectID: projectID, sourceSeconds: source + offsetMs / 1000)
                }
            }
            throw ToolError.failed("No marker named \(atMarker). Call timeline_get markers first.")
        }
        if let atOutput {
            guard atOutput.isFinite, atOutput >= 0 else { throw ToolError.invalidArguments("at_output must be finite and non-negative.") }
            let placement = atOutput + offsetMs / 1000
            guard placement.isFinite, placement >= 0 else { throw ToolError.invalidArguments("The resulting audio placement must be finite and non-negative.") }
            return placement
        }
        let placement = offsetMs / 1000
        guard placement >= 0 else { throw ToolError.invalidArguments("An unanchored audio placement cannot be negative.") }
        return placement
    }

    private static func validated(_ value: Double, name: String, range: ClosedRange<Double>) throws -> Double {
        guard value.isFinite, range.contains(value) else {
            throw ToolError.invalidArguments("\(name) must be in \(range.lowerBound)…\(range.upperBound).")
        }
        return value
    }
}
