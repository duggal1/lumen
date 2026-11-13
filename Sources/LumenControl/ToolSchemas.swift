import Foundation

/// Hand-written schemas for the tools whose input is a nested tree.
///
/// AGENT: reflection can only see `[Action]` as "array of object", so an agent
/// had no way to learn the shape of a script, an action or a patch op. These
/// three tools publish the real shape.
public enum ToolSchemas {
    /// AGENT: MCP clients can validate the stable result shapes they consume most often.
    static func outputSchema(for name: String) -> JSONValue? {
        switch name {
        case "lumen_status":
            return J.obj([
                "phase": J.str("Current recording phase."),
                "paused": J.bool("Whether the current recording is paused."),
                "recording": J.bool("Whether a recording is active."),
                "permissions": J.obj([
                    "screen_recording": J.bool("Screen Recording permission."),
                    "accessibility": J.bool("Accessibility permission."),
                    "input_monitoring": J.bool("Input Monitoring permission."),
                    "microphone": J.bool("Microphone permission."),
                    "camera": J.bool("Camera permission."),
                ], required: ["screen_recording", "accessibility", "input_monitoring", "microphone", "camera"]),
                "permission_links": J.obj([
                    "screen_recording": J.str("System Settings pane for Screen Recording."),
                    "accessibility": J.str("System Settings pane for Accessibility."),
                    "input_monitoring": J.str("System Settings pane for Input Monitoring."),
                ], required: ["screen_recording", "accessibility", "input_monitoring"]),
                "library": J.str("Recording library path."),
                "projects": J.int("Number of projects in the library.", min: 0),
                "active_project": .object(["type": .array([.string("string"), .string("null")])]),
                "version": J.str("Lumen version."),
            ], required: ["phase", "paused", "recording", "permissions", "permission_links", "library",
                          "projects", "active_project", "version"])
        case "job_status":
            return J.obj([
                "job_id": J.str("Stable job identifier."),
                "kind": J.str("Job type."),
                "state": J.str("Current state.", enum: ["queued", "running", "done", "failed", "cancelled"]),
                "progress": J.num("Progress fraction.", min: 0, max: 1),
                "message": .object(["type": .array([.string("string"), .string("null")])]),
                "result": .object(["type": .array([.string("object"), .string("array"), .string("string"), .string("number"), .string("boolean"), .string("null")])]),
                "error": .object(["type": .array([.string("string"), .string("null")])]),
            ], required: ["job_id", "kind", "state", "progress", "message", "result", "error"])
        case "qa_report":
            return J.obj([
                "project_id": J.str("Project identifier."),
                "checks": J.arr(J.obj([
                    "name": J.str("Check identifier."),
                    "ok": J.bool("Whether the check passed."),
                    "detail": J.str("Measured result or next action."),
                ], required: ["name", "ok", "detail"]), "Quality checks."),
                "zoom_accuracy": .object(["type": .string("object")]),
            ], required: ["project_id", "checks", "zoom_accuracy"])
        case "timeline_get":
            return J.obj([
                "revision": J.int("Current project revision.", min: 0),
                "duration": J.num("Edited output duration in seconds.", min: 0),
                "time_basis": .object(["type": .string("object")]),
                "zoom": J.arr(.object(["type": .string("object")]), "Zoom segments."),
                "cuts": J.arr(.object(["type": .string("object")]), "Removed source ranges."),
                "ramps": J.arr(.object(["type": .string("object")]), "Playback speed ramps."),
                "style": .object(["type": .string("object")]),
                "cursor": .object(["type": .string("object")]),
                "audio": .object(["type": .string("object")]),
                "captions": .object(["type": .string("object")]),
                "privacy": .object(["type": .string("object")]),
            ], required: ["revision", "duration", "time_basis", "zoom", "cuts", "ramps", "style", "cursor", "audio", "captions", "privacy"])
        default:
            return nil
        }
    }

    /// The complete declared schema for a flat tool input.
    ///
    /// AGENT: callers were relying on runtime reflection, which lost field constraints and nested element shapes.
    static func schema(for name: String, required: [String]) -> JSONValue {
        let project = J.str("Project id returned by project_list, project_open or record_stop.")
        let path = J.str("Path inside a folder approved for this client.")
        let time = J.num("Time in seconds.", min: 0)
        let props: [String: JSONValue]
        switch name {
        case "lumen_status", "list_apps", "list_displays", "project_list", "background_list",
             "record_pause", "record_resume", "record_stop":
            props = [:]
        case "list_windows":
            props = ["bundle_id": J.str("Filter by owning application bundle id."),
                     "include_offscreen": J.bool("Include windows outside the main layer.", def: false)]
        case "record_start":
            props = [
                "target": J.str("Capture source.", enum: ["display", "window", "region"], def: "display"),
                "display_id": J.int("Display id from list_displays.", min: 0, def: 0),
                "bundle_id": J.str("Required for window capture."),
                "window_id": J.int("Window id from list_windows.", min: 0, def: 0),
                "region_x": J.num("Normalized left edge of the display region.", min: 0, max: 1, def: 0),
                "region_y": J.num("Normalized top edge of the display region.", min: 0, max: 1, def: 0),
                "region_width": J.num("Normalized region width.", min: 0.000001, max: 1, def: 1),
                "region_height": J.num("Normalized region height.", min: 0.000001, max: 1, def: 1),
                "fps": J.int("Capture frame rate.", min: 15, max: 120, def: 60),
                "microphone": J.bool("Capture the microphone.", def: true),
                "system_audio": J.bool("Capture system audio.", def: false),
                "webcam": J.bool("Capture a connected camera.", def: false),
                "privacy_auto_mask": J.bool("Enable automatic privacy masking.", def: true),
            ]
        case "record_marker":
            props = ["id": J.str("Unique marker id for this recording."), "label": J.str("Optional marker label.")]
        case "ui_snapshot":
            props = ["bundle_id": J.str("Allowed application bundle id."),
                     "max_depth": J.int("Maximum accessibility tree depth.", min: 1, max: 12, def: 6)]
        case "ui_act":
            return uiAct
        case "ui_wait_for":
            props = ["bundle_id": J.str("Allowed application bundle id."),
                     "role": J.str("Accessibility role."), "title": J.str("Visible title."),
                     "identifier": J.str("Accessibility identifier."),
                     "timeout_s": J.num("Maximum wait time.", min: 0, max: 60, def: 8)]
        case "run_script":
            return runScript
        case "project_open":
            props = ["path": J.str("Path to a Lumen project inside an approved folder.")]
        case "timeline_get", "undo", "zoom_replan", "qa_report", "captions_generate", "captions_set",
             "privacy_scan", "privacy_apply":
            if name == "captions_generate" {
                props = ["project_id": project, "locale": J.str("Speech and caption locale.", def: "en-US")]
            } else if name == "captions_set" {
                props = ["project_id": project, "enabled": J.bool("Show captions.", def: true),
                         "locale": J.str("Caption locale.")]
            } else if name == "privacy_apply" {
                props = ["project_id": project,
                         "decisions": .object(["type": .string("object"),
                                                "additionalProperties": J.bool("Whether each mask is approved.")])]
            } else {
                props = ["project_id": project]
            }
        case "timeline_patch":
            return timelinePatch
        case "zoom_add":
            props = ["project_id": project, "start": time, "end": time,
                     "scale": J.num("Magnification.", min: 1.1, max: 4, def: 2),
                     "focus_mode": J.str("Focus behavior.", enum: ["follow", "fixed", "element"], def: "follow"),
                     "focus_x": J.num("Normalized horizontal focus.", min: 0, max: 1, def: 0.5),
                     "focus_y": J.num("Normalized vertical focus.", min: 0, max: 1, def: 0.5),
                     "basis": J.str("Time basis.", enum: ["source", "output"], def: "source")]
        case "zoom_remove":
            props = ["project_id": project, "id": J.str("Zoom id.")]
        case "cut_range":
            props = ["project_id": project, "start": time, "end": time,
                     "basis": J.str("Time basis.", enum: ["source", "output"], def: "source")]
        case "speed_ramp_set":
            props = ["project_id": project, "start": time, "end": time,
                     "speed": J.num("Playback speed multiplier.", min: 0.25, max: 16, def: 2),
                     "basis": J.str("Time basis.", enum: ["source", "output"], def: "source")]
        case "style_set":
            props = ["project_id": project,
                     "padding": J.num("Canvas padding fraction.", min: 0, max: 0.2),
                     "corner_radius": J.num("Canvas corner radius in points.", min: 0, max: 80),
                     "shadow": J.num("Shadow strength.", min: 0, max: 1),
                     "aspect": J.num("Output aspect ratio.", min: 0.2, max: 5),
                     "wallpaper_blur": J.num("Wallpaper blur amount.", min: 0, max: 100),
                     "background": J.str("Background kind.", enum: ["dither", "canvas", "wallpaper", "solid", "gradient", "mesh", "image"]),
                     "background_image_path": path]
        case "background_set":
            props = ["project_id": project,
                     "background": J.str("Background kind.", enum: ["dither", "canvas", "wallpaper", "solid", "gradient", "mesh", "image"]),
                     "image_path": path]
        case "audio_import":
            props = ["project_id": project, "path": path,
                     "role": J.str("Audio lane role.", enum: ["music", "voiceover", "sfx"], def: "voiceover"),
                     "at_marker": J.str("Marker id to anchor this lane."),
                     "at_output": J.num("Absolute output time.", min: 0),
                     "offset_ms": J.num("Offset from marker in milliseconds.", def: 0),
                     "gain_db": J.num("Optional lane gain in decibels."),
                     "loop": J.bool("Loop the lane.", def: false)]
        case "audio_mix_set":
            props = ["project_id": project,
                     "target_lufs": J.num("Normalized loudness target.", min: -24, max: -10),
                     "music_gain_db": J.num("Music gain in decibels.", min: -60, max: 12),
                     "mic_gain_db": J.num("Microphone gain in decibels.", min: -60, max: 12),
                     "output_gain_db": J.num("Output gain in decibels.", min: -60, max: 12),
                     "duck_depth_db": J.num("Music duck depth in decibels.", min: 0, max: 36),
                     "normalize": J.bool("Enable or disable output loudness normalization.")]
        case "voiceover_generate":
            props = ["project_id": project, "text": J.str("Narration text."),
                     "voice": J.str("Configured voice id."), "model": J.str("Speech model id."),
                     "at_marker": J.str("Marker id to anchor narration."),
                     "at_output": J.num("Absolute output time.", min: 0),
                     "offset_ms": J.num("Offset from marker in milliseconds.", def: 0),
                     "gain_db": J.num("Narration gain in decibels.", def: 0)]
        case "preview_frame":
            props = ["project_id": project, "time": time,
                     "max_width": J.int("Maximum image width.", min: 160, max: 1920, def: 960),
                     "png": J.bool("Return lossless PNG instead of JPEG.", def: false)]
        case "preview_sheet":
            props = ["project_id": project,
                     "frames": J.int("Number of frames in the contact sheet.", min: 1, max: 12, def: 6),
                     "duration": J.num("Source span to sample.", min: 0, def: 0),
                     "max_width": J.int("Maximum frame width.", min: 160, max: 960, def: 480),
                     "png": J.bool("Return lossless PNG instead of JPEG.", def: false)]
        case "export_start":
            props = ["project_id": project,
                     "preset": J.str("Export preset name.", def: "1080p30-h264"),
                     "output": J.str("Output path inside an approved folder."),
                     "include_audio": J.bool("Include the audio mix.", def: true),
                     "export_stems": J.bool("Write separate audio stems.", def: false)]
        case "job_status", "export_cancel":
            props = ["job_id": J.str("Job id returned by a long-running tool.")]
        default:
            props = [:]
        }
        return J.obj(props, required: required)
    }

    /// How an element is addressed inside another app.
    static var target: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "role": .object(["type": .string("string"), "description": .string("AX role, e.g. AXButton")]),
                "title": .object(["type": .string("string")]),
                "identifier": .object(["type": .string("string")]),
                "index": .object(["type": .string("integer"), "default": .int(0),
                                  "description": .string("Which match to take when several match.")]),
            ]),
            "additionalProperties": .bool(false),
        ])
    }

    /// One action inside a step or a `ui_act` batch. Discriminated by `op`.
    static var action: JSONValue {
        func number(_ description: String? = nil, default value: Double? = nil) -> JSONValue {
            var out: [String: JSONValue] = ["type": .string("number")]
            if let description { out["description"] = .string(description) }
            if let value { out["default"] = .number(value) }
            return .object(out)
        }
        func integer(_ value: Int? = nil, _ description: String? = nil) -> JSONValue {
            var out: [String: JSONValue] = ["type": .string("integer")]
            if let description { out["description"] = .string(description) }
            if let value { out["default"] = .int(value) }
            return .object(out)
        }
        func string(_ description: String? = nil) -> JSONValue {
            var out: [String: JSONValue] = ["type": .string("string")]
            if let description { out["description"] = .string(description) }
            return .object(out)
        }
        let fraction = "Fraction of the target, 0...1."
        return .object([
            "type": .string("object"),
            "properties": .object([
                "op": .object([
                    "type": .string("string"),
                    "enum": .array(["launch", "wait_for", "click", "drag", "type", "paste", "key",
                                    "sleep", "move", "scroll", "screenshot"].map { .string($0) }),
                ]),
                // Addressing and geometry.
                "target": target,
                "x": number(fraction),
                "y": number(fraction),
                "move_ms": integer(600, "Travel time for the pointer."),
                "button": .object(["type": .string("string"), "enum": .array([.string("left"), .string("right")])]),
                "count": integer(1, "1 for a click, 2 for a double click."),
                // Drag endpoints.
                "from": target,
                "from_x": number(fraction),
                "from_y": number(fraction),
                "to": target,
                "to_x": number(fraction),
                "to_y": number(fraction),
                // Text.
                "text": string("Text to type or paste."),
                "cps": number("Characters per second for `type`.", default: 9),
                "key": string("Key name: return, tab, space, delete, escape, left, right, up, down."),
                "modifiers": .object(["type": .string("array"),
                                      "items": .object(["type": .string("string")]),
                                      "description": .string("cmd, ctrl, opt, shift.")]),
                // Timing and motion.
                "seconds": number("How long to sleep.", default: 1),
                "dy": number("Wheel lines; negative scrolls down.", default: -3),
                "path": string("Screenshot path. Must be inside the allowed output folder."),
                // Wait and launch.
                "role": string(),
                "title": string(),
                "identifier": string(),
                "timeout_s": number("How long to wait for the element.", default: 8),
                "bundle_id": string(),
                "wait_s": number("How long to let the app launch.", default: 2),
            ]),
            "required": .array([.string("op")]),
            "additionalProperties": .bool(true),
        ])
    }

    /// `run_script`: a whole demo script.
    static var runScript: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "script": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "version": .object(["type": .string("integer"), "default": .int(1)]),
                        "app": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "bundle_id": .object(["type": .array([.string("string"), .string("null")])]),
                                "name": .object(["type": .array([.string("string"), .string("null")])]),
                            ]),
                        ]),
                        "steps": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "id": .object(["type": .string("string"),
                                                   "description": .string("Marker id, e.g. open-settings.")]),
                                    "say": .object(["type": .array([.string("string"), .string("null")]),
                                                    "description": .string("Narration for this step.")]),
                                    "do": .object(["type": .string("array"), "items": action]),
                                    "pad_after_s": .object(["type": .string("number"), "default": .number(0)]),
                                ]),
                                "required": .array([.string("do")]),
                            ]),
                        ]),
                    ]),
                    "required": .array([.string("steps")]),
                ]),
                "mode": .object(["type": .string("string"),
                                 "enum": .array([.string("physical"), .string("virtual")]),
                                 "default": .string("physical")]),
                "bundle_id": .object(["type": .string("string")]),
            ]),
            // AGENT: a declared, approved target is required for every script.
            "required": .array([.string("bundle_id"), .string("script")]),
            "additionalProperties": .bool(false),
        ])
    }

    /// `ui_act`: a flat batch of actions.
    static var uiAct: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "bundle_id": .object(["type": .string("string")]),
                "actions": .object(["type": .string("array"), "items": action]),
            ]),
            "required": .array([.string("bundle_id"), .string("actions")]),
            "additionalProperties": .bool(false),
        ])
    }

    /// `timeline_patch`: typed operations.
    static var timelinePatch: JSONValue {
        let op = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "op": .object([
                    "type": .string("string"),
                    "enum": .array(["zoom_add", "zoom_set", "zoom_remove", "cut_add", "cut_remove",
                                    "ramp_set", "ramp_remove", "style_set", "audio_lane_add",
                                    "audio_lane_remove", "music_set", "captions_set", "privacy_set"]
                                    .map { .string($0) }),
                ]),
                "id": .object(["type": .string("string")]),
                "start": .object(["type": .string("number"), "description": .string("Source seconds.")]),
                "end": .object(["type": .string("number"), "description": .string("Source seconds.")]),
                "scale": .object(["type": .string("number"), "default": .number(2)]),
                "focus_mode": .object(["type": .string("string"),
                                       "enum": .array([.string("follow"), .string("fixed"), .string("element")])]),
                "focus_x": .object(["type": .string("number"), "default": .number(0.5)]),
                "focus_y": .object(["type": .string("number"), "default": .number(0.5)]),
                "speed": .object(["type": .string("number"), "default": .number(2)]),
                "key": .object(["type": .string("string")]),
                "value": .object(["type": .string("number")]),
                "text": .object(["type": .string("string")]),
                "flag": .object(["type": .string("boolean"), "default": .bool(true)]),
            ]),
            "required": .array([.string("op")]),
            "additionalProperties": .bool(true),
        ])
        return .object([
            "type": .string("object"),
            "properties": .object([
                "project_id": .object(["type": .string("string")]),
                "revision": J.int("The revision you read; omit to skip the compare-and-swap check.", min: 1),
                "ops": .object(["type": .string("array"), "items": op]),
            ]),
            "required": .array([.string("project_id"), .string("ops")]),
            "additionalProperties": .bool(false),
        ])
    }
}
