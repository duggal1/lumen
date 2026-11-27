import Foundation

/// Actual server-discoverable resources, not merely prompt files in the repo.
/// Keep recipes bound to registered tool names; planned capabilities are explicit.
enum AgentEditingSkills {
    struct Skill: Sendable {
        let uri: String
        let title: String
        let markdown: String
    }
    static let all: [Skill] = [
        .init(uri: "lumen://skills/record-edit-export", title: "Record, edit and export", markdown: """
        # Record, edit and export (v2)
        Inspect tools/list for current schemas. Call lumen_status; obtain recording and accessibility grants only where needed. Use record_start and record_stop, then project_open if needed. Read get_edit for persisted revision and IDs. Use audio_edit_v2 for imported audio; use cut_span, split_clip, trim_clip, set_zoom, background_list and background_set for the existing editing surface. Inspect render_preview and qa_report. Call export_final and poll job_status. Do not claim delivery before the export job succeeds with verification evidence. Inspect representative frames and audio for creative quality; technical QA does not prove taste. On a recoverable demo failure, open its retained project instead of repeating capture. On revision conflict, re-read get_edit and re-evaluate the requested edit.
        """),
        .init(uri: "lumen://skills/audio-edit", title: "Edit audio clips", markdown: """
        # Audio editing (v2)
        Use get_edit to read revision and audio_lanes. Call audio_edit_v2 with project_id, revision, and ops. Add requires id (client-generated UUID), role (music, voiceover, sfx), approved path, optional placement, trim_start, trim_duration, gain_db and mute. Music loops defaults false. Update uses id and changed fields; trim can shrink the current excerpt. Split requires id, at (output seconds), new_id; looping beds must first become finite. Remove uses id. Dry_run validates the same batch without persistence. A successful batch creates one revision/undo step; get_edit verifies IDs and ranges. On conflict, do not blindly retry; re-read. Durable idempotent receipts are not yet implemented.
        """),
        .init(uri: "lumen://skills/react-video", title: "React video integration (current boundary)", markdown: """
        # React video
        Native React execution is not implemented. Use an explicitly approved external local Remotion project to render deterministic frames to a real movie. Validate duration, frame rate, dimensions and alpha requirements, then use clip_import for a supported local video. The current clip model does not guarantee ripple insertion into the recording; inspect get_edit and render_preview before export. Never execute untrusted React code or install dependencies without authorization.
        """)
    ]
}
