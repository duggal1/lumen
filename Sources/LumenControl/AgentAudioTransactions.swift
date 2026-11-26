import Foundation
@preconcurrency import AVFoundation
import LumenProject

/// Stable v2 command wire. Every mutating request carries a revision, each add
/// and split carries a client-generated UUID, and the batch is one undo step.
struct AgentAudioTransaction: ToolInput {
    var projectID = ""
    var revision = -1
    var ops: [Operation] = []
    struct Operation: Codable, Sendable {
        var op: String
        var id: UUID
        var newID: UUID?
        var path: String?
        var role: String?
        var placement: Double?
        var trimStart: Double?
        var trimDuration: Double?
        var gainDb: Double?
        var mute: Bool?
        var loops: Bool?
        var at: Double?
        enum CodingKeys: String, CodingKey {
            case op, id, path, role, placement, mute, loops, at
            case newID = "new_id", trimStart = "trim_start", trimDuration = "trim_duration", gainDb = "gain_db"
        }
    }
    enum CodingKeys: String, CodingKey { case projectID = "project_id", revision, ops }
}

extension ToolRegistry {
    func registerAgentAudioTransactions() {
        let id = J.str("Stable audio clip UUID. Generate once and reuse on retry.")
        let time = J.num("Seconds.", min: 0)
        let schema = J.obj([
            "project_id": J.str("Project ID from project_open or record_stop."),
            "revision": J.int("Required expected persisted project revision.", min: 0),
            "ops": J.arr(J.obj([
                "op": J.str("Operation.", enum: ["add", "update", "split", "remove"]),
                "id": id, "new_id": id, "path": J.str("Approved local audio file for add."),
                "role": J.str("Imported audio role.", enum: ["music", "voiceover", "sfx"]),
                "placement": time, "trim_start": time, "trim_duration": J.num("Finite asset excerpt duration.", min: 0.01),
                "gain_db": J.num("Gain.", min: -60, max: 12), "mute": J.bool("Mute"),
                "loops": J.bool("Repeat music to project end; defaults false."), "at": time
            ], required: ["op", "id"]), "Atomic ordered operations, maximum 64.", minItems: 1)
        ], required: ["project_id", "revision", "ops"])
        register(ToolDefinition<AgentAudioTransaction>(name: "audio_edit_v2",
            description: "Atomically add, update, split or remove imported audio clips. Probes real media on add, returns persisted revision and diff. Use get_edit to read lane IDs. Dry-run validates without writing.",
            capability: .edit, required: ["project_id", "revision", "ops"], mutating: true,
            schema: schema, destructive: true, customDryRun: true) { input, ctx in
            guard input.revision >= 0, (1...64).contains(input.ops.count) else {
                throw ToolError.invalidArguments("revision and 1...64 operations required")
            }
            // Prepare file-backed operations before acquiring the edit draft.
            var commands: [Command] = []
            for op in input.ops {
                try Task.checkCancellation()
                switch op.op {
                case "add":
                    guard let path = op.path, let roleName = op.role,
                          let role = AudioLane.Role(rawValue: roleName), [.music, .voiceover, .sfx].contains(role) else {
                        throw ToolError.invalidArguments("add requires an approved path and imported audio role")
                    }
                    let url = try ctx.paths.path(path, ext: PathGuard.audioExt)
                    let asset = AVURLAsset(url: url)
                    guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                        throw ToolError.invalidArguments("asset has no audio track")
                    }
                    let duration = try await asset.load(.duration).seconds
                    let start = op.trimStart ?? 0, length = op.trimDuration ?? duration - start
                    guard duration.isFinite, start.isFinite, length.isFinite, start >= 0,
                          length >= 0.01, start + length <= duration + 0.0001 else {
                        throw ToolError.invalidArguments("trim is outside the audio asset")
                    }
                    var lane = AudioLane(id: op.id, role: role, path: url.path, placement: op.placement ?? 0,
                                         gainDb: op.gainDb ?? (role == .music ? -18 : 0), mute: op.mute ?? false)
                    lane.trimStart = start; lane.trimDuration = length; lane.loops = op.loops ?? false
                    commands.append(.addAudioLane(lane))
                case "update":
                    // Asset extent is immutable in this first transaction slice:
                    // trim may shrink the current source range, not expand it.
                    commands.append(.updateAudioLane(op.id, AudioClipPatch(placement: op.placement,
                        trimStart: op.trimStart, trimDuration: op.trimDuration, gainDb: op.gainDb, mute: op.mute, loops: op.loops)))
                case "split":
                    guard let at = op.at, let newID = op.newID else { throw ToolError.invalidArguments("split needs at and new_id") }
                    commands.append(.splitAudioLane(op.id, atOutput: at, newID: newID))
                case "remove": commands.append(.deleteAudioLane(op.id))
                default: throw ToolError.invalidArguments("unknown audio operation")
                }
            }
            let batch = commands
            let apply: @Sendable (inout Timeline) throws -> Void = { draft in
                for command in batch {
                    if case .deleteAudioLane(let id) = command,
                       !draft.audio.lanes.contains(where: { $0.id == id }) {
                        throw ToolError.failed("No audio clip with id \(id.uuidString).")
                    }
                    if case .updateAudioLane(let id, let patch) = command,
                       let old = draft.audio.lanes.first(where: { $0.id == id }),
                       patch.trimStart != nil || patch.trimDuration != nil {
                        guard let oldLength = old.trimDuration else { throw ToolError.invalidArguments("finite source range required") }
                        let oldStart = old.trimStart ?? 0
                        let start = patch.trimStart ?? oldStart
                        let length = patch.trimDuration ?? oldLength
                        guard start >= oldStart, start + length <= oldStart + oldLength + 0.0001 else {
                            throw ToolError.invalidArguments("trim can only shrink the current excerpt")
                        }
                    }
                    try applyCommand(command, to: &draft)
                }
            }
            let result: [String: JSONValue]
            if ctx.dryRun {
                result = try await ctx.engine.previewEdit(projectID: input.projectID, expectRevision: input.revision, apply)
            } else {
                result = try await ctx.engine.edit(projectID: input.projectID, expectRevision: input.revision,
                    describe: "Audio transaction (\(batch.count) operations)", apply)
            }
            return .object(result)
        })
    }
}
