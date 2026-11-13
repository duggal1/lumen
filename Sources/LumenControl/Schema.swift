import Foundation

/// JSON Schema constructors shared by the explicit tool catalog.
///
/// AGENT: reflection hid nested input shapes and advertised arrays as objects, so every tool now publishes a declared schema.
public enum J {
    public static func obj(_ properties: [String: JSONValue], required: [String] = [], _ description: String? = nil) -> JSONValue {
        var value: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ]
        if let description { value["description"] = .string(description) }
        return .object(value)
    }

    public static func str(_ description: String, `enum` cases: [String]? = nil, def: String? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let cases { value["enum"] = .array(cases.map(JSONValue.string)) }
        if let def { value["default"] = .string(def) }
        return .object(value)
    }

    public static func num(_ description: String, min: Double? = nil, max: Double? = nil, def: Double? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("number"), "description": .string(description)]
        if let min { value["minimum"] = .number(min) }
        if let max { value["maximum"] = .number(max) }
        if let def { value["default"] = .number(def) }
        return .object(value)
    }

    public static func int(_ description: String, min: Int? = nil, max: Int? = nil, def: Int? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("integer"), "description": .string(description)]
        if let min { value["minimum"] = .int(min) }
        if let max { value["maximum"] = .int(max) }
        if let def { value["default"] = .int(def) }
        return .object(value)
    }

    public static func bool(_ description: String, def: Bool? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("boolean"), "description": .string(description)]
        if let def { value["default"] = .bool(def) }
        return .object(value)
    }

    public static func arr(_ item: JSONValue, _ description: String, minItems: Int? = nil) -> JSONValue {
        var value: [String: JSONValue] = ["type": .string("array"), "items": item, "description": .string(description)]
        if let minItems { value["minItems"] = .int(minItems) }
        return .object(value)
    }

    public static func oneOf(_ cases: [JSONValue]) -> JSONValue {
        .object(["oneOf": .array(cases)])
    }

    static func injectingDryRun(_ schema: JSONValue) -> JSONValue {
        guard case .object(var root) = schema,
              case .object(var properties)? = root["properties"] else { return schema }
        properties["dry_run"] = bool("Validate the call without changing anything.", def: false)
        root["properties"] = .object(properties)
        return .object(root)
    }
}
