import Foundation
import LumenCore
import LumenProject

// MARK: - Post-process tool

/// Verifies and summarizes the derived edit after all edits are applied.
///
/// Post-processing in Lumen is the derived pass that turns recorded input into
/// the final timeline (auto-crop, zoom, audio mix) and the QA checks that guard
/// it. This tool re-reads that derived state, runs the QA report and returns
/// the output path metadata an agent needs before `export_final`. It never
/// changes the project: the mutating stages (zoom_replan, captions_generate,
/// privacy_apply, audio_mix_set, style_set) remain separate tools so an agent
/// can see exactly what each one did.
public struct PostProcessInput: ToolInput {
    public var projectID: String = ""
    public var revision: Int?
    public var includeQA: Bool = true
    public init() {}

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case revision
        case includeQA = "include_qa"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.projectID = try c.decodeIfPresent(String.self, forKey: .projectID) ?? ""
        self.revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        self.includeQA = try c.decodeIfPresent(Bool.self, forKey: .includeQA) ?? true
    }
}

public extension ToolRegistry {
    func registerPostProcessTools() {
        register(ToolDefinition<PostProcessInput>(name: "post_process",
            description: "Runs the final derived-state check on a project: reads the persisted edit, recomputes its metadata and runs the QA report. Read-only; call zoom_replan or the audio/caption tools first if you need to change anything. Returns project_id, revision, duration, canvas and QA checks.",
            capability: .edit, required: ["project_id"],
            schema: J.obj([
                "project_id": J.str("Project id returned by project_open, project_list or record_stop."),
                "revision": J.int("Expected revision; a mismatch returns REVISION_CONFLICT.", min: 0),
                "include_qa": J.bool("Run the QA report and include its checks.", def: true),
            ], required: ["project_id"]),
            idempotent: true,
            outputSchema: J.obj([
                "project_id": J.str("Project identifier."),
                "revision": J.int("Persisted revision.", min: 0),
                "duration": J.num("Edited output duration in seconds.", min: 0),
                "canvas": J.str("Output canvas preset."),
                "checks": J.arr(J.obj([
                    "name": J.str("Check identifier."),
                    "ok": J.bool("Whether the check passed."),
                    "detail": J.str("Measured result or next action."),
                ]), "QA checks from the post-process pass."),
                "post_processed": J.bool("Always true when the derived state was read successfully."),
            ], required: ["project_id", "revision", "duration", "post_processed"])) { input, ctx in
                guard ctx.engine.knownProjects().contains(where: { $0.identifier == input.projectID }) else {
                    throw ToolError.failed("Unknown project \(input.projectID). Call project_open first.")
                }
                let timeline = try await ctx.engine.timelineValue(projectID: input.projectID)
                let revision = timeline["revision"]?.intValue ?? 0
                if let expected = input.revision, expected != revision {
                    throw ToolError.revisionConflict(expected: expected, actual: revision)
                }
                var payload: [String: JSONValue] = [
                    "project_id": .string(input.projectID),
                    "revision": .int(revision),
                    "duration": timeline["duration"] ?? .number(0),
                    "post_processed": .bool(true),
                ]
                if let style = timeline["style"], let canvas = style["canvas"] {
                    payload["canvas"] = canvas
                }
                if input.includeQA {
                    let qa = try await ctx.engine.qaReport(projectID: input.projectID)
                    payload["checks"] = qa["checks"] ?? .array([])
                }
                ctx.progress?(1, "post-process complete")
                return .object(payload)
            })
    }
}
