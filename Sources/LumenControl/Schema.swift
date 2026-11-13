import Foundation
import LumenCore
import LumenProject
import LumenActuator

/// JSON Schema generation for tool inputs.
///
/// The schema is DERIVED from the Codable input type, never hand-written: the
/// registry builds a default instance of the input type and reflects over it.
/// Every tool input type gives every property a default value, so the
/// reflection sees the real property names and the real types.
public enum SchemaGenerator {
    /// Builds a JSON Schema object for a default instance of `sample`.
    public static func schema(for sample: Any, required: [String] = []) -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for child in Mirror(reflecting: sample).children {
            guard let name = child.label else { continue }
            properties[Self.snakeCase(name)] = schema(forValue: child.value)
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }

    /// AGENT: a mutating tool's schema must declare dry_run, or strict clients
    /// reject the argument because additionalProperties is false.
    public static func injectingDryRun(_ schema: JSONValue) -> JSONValue {
        guard case .object(var root) = schema,
              case .object(var properties)? = root["properties"] else { return schema }
        properties["dry_run"] = .object([
            "type": .string("boolean"),
            "default": .bool(false),
            "description": .string("Validate and describe the call without changing anything."),
        ])
        root["properties"] = .object(properties)
        return .object(root)
    }

    /// Tool arguments use snake_case, the way an agent writes them.
    public static func snakeCase(_ name: String) -> String {
        var out = ""
        for (index, character) in name.enumerated() {
            if character.isUppercase {
                if index > 0 && !name[name.index(before: name.index(name.startIndex, offsetBy: index))].isUppercase {
                    out.append("_")
                }
                out.append(Character(character.lowercased()))
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// Maps a runtime value to a JSON Schema fragment.
    public static func schema(forValue value: Any) -> JSONValue {
        let type = type(of: value)
        let name = String(describing: type)
        if let optional = OptionalTypeInfo(name) {
            // AGENT: Swift type names are not JSON Schema types; describe the wrapped schema and null separately.
            return .object([
                "anyOf": .array([schema(forTypeName: optional.wrapped), .object(["type": .string("null")])]),
            ])
        }
        if let element = ArrayTypeInfo(name) {
            return .object([
                "type": .string("array"),
                "items": schema(forTypeName: element.element),
            ])
        }
        if let valueType = DictionaryTypeInfo(name) {
            return .object([
                "type": .string("object"),
                "additionalProperties": schema(forTypeName: valueType.value),
            ])
        }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .enum {
            let cases = enumCases(of: name)
            var out: [String: JSONValue] = ["type": .string("string")]
            if !cases.isEmpty { out["enum"] = .array(cases.map { .string($0) }) }
            return .object(out)
        }
        if mirror.displayStyle == .struct || mirror.displayStyle == .class {
            var properties: [String: JSONValue] = [:]
            for child in mirror.children {
                guard let key = child.label else { continue }
                properties[Self.snakeCase(key)] = schema(forValue: child.value)
            }
            return .object([
                "type": .string("object"),
                "properties": .object(properties),
                "additionalProperties": .bool(false),
            ])
        }
        return schema(forTypeName: name)
    }

    /// A schema for a type we only know by name (array elements, dictionary
    /// values, generic parameters).
    public static func schema(forTypeName name: String) -> JSONValue {
        switch name {
        case "String", "Substring": return .object(["type": .string("string")])
        case "Bool": return .object(["type": .string("boolean")])
        case "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return .object(["type": .string("integer")])
        case "Double", "Float", "CGFloat": return .object(["type": .string("number")])
        case "URL": return .object(["type": .string("string"), "format": .string("uri")])
        case "Date": return .object(["type": .string("string"), "format": .string("date-time")])
        default: break
        }
        if let optional = OptionalTypeInfo(name) { return schema(forTypeName: optional.wrapped) }
        if let element = ArrayTypeInfo(name) {
            return .object(["type": .string("array"), "items": schema(forTypeName: element.element)])
        }
        if let valueType = DictionaryTypeInfo(name) {
            return .object(["type": .string("object"), "additionalProperties": schema(forTypeName: valueType.value)])
        }
        return .object(["type": .string("object")])
    }

    /// Enum case names, read from the real `CaseIterable` type.
    ///
    /// AGENT: a hand-kept table of case lists drifted from the enums (it still
    /// advertised backgrounds that no longer exist), so the lists now come
    /// from `allCases` and cannot lie.
    private static func enumCases(of rawName: String) -> [String] {
        let name = rawName.split(separator: ".").last.map(String.init) ?? rawName
        switch name {
        case "RecordingTargetKind": return RecordingTargetKind.allCases.map(\.rawValue)
        case "Capability": return Capability.allCases.map(\.rawValue)
        case "InputMode": return InputMode.allCases.map(\.rawValue)
        case "BackgroundKind": return BackgroundKind.allCases.map(\.rawValue)
        case "MaskMode": return MaskMode.allCases.map(\.rawValue)
        default: return []
        }
    }
}

// MARK: - Type-name parsing

struct OptionalTypeInfo {
    let wrapped: String
    init?(_ name: String) {
        guard name.hasPrefix("Optional<"), name.hasSuffix(">") else { return nil }
        wrapped = String(name.dropFirst("Optional<".count).dropLast())
    }
}

struct ArrayTypeInfo {
    let element: String
    init?(_ name: String) {
        // AGENT: reflection prints both Array<Element> and [Element] depending on the runtime.
        if name.hasPrefix("Array<"), name.hasSuffix(">") { element = String(name.dropFirst(6).dropLast()) }
        else if name.hasPrefix("["), name.hasSuffix("]") { element = String(name.dropFirst().dropLast()) }
        else { return nil }
    }
}

struct DictionaryTypeInfo {
    let value: String
    init?(_ name: String) {
        guard name.hasPrefix("Dictionary<"), name.hasSuffix(">") else { return nil }
        let inner = name.dropFirst("Dictionary<".count).dropLast()
        let parts = inner.split(separator: ",")
        guard parts.count == 2 else { return nil }
        value = String(parts[1]).trimmingCharacters(in: .whitespaces)
    }
}
