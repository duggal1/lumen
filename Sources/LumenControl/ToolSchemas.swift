import Foundation

/// Hand-written schemas for the tools whose input is a nested tree.
///
/// AGENT: reflection can only see `[Action]` as "array of object", so an agent
/// had no way to learn the shape of a script, an action or a patch op. These
/// three tools publish the real shape.
public enum ToolSchemas {
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
            "required": .array([.string("script")]),
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
                "revision": .object(["type": .string("integer"),
                                     "description": .string("The revision you read; omit or 0 to skip the check.")]),
                "ops": .object(["type": .string("array"), "items": op]),
            ]),
            "required": .array([.string("project_id"), .string("ops")]),
            "additionalProperties": .bool(false),
        ])
    }
}
