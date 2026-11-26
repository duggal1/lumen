import Foundation

/// A minimal JSON tree. Tool schemas, tool arguments and tool results all
/// travel as `JSONValue`, so the control layer never needs a serialization
/// dependency.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func int(_ v: Int) -> JSONValue { .number(Double(v)) }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Access

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var intValue: Int? { if case .number(let n) = self { return Int(exactly: n) }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { self == .null }

    /// Builds a value from a decoded JSON object (Any).
    public init(any value: Any) {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else { self = .number(number.doubleValue) }
            return
        }
        if let text = value as? String { self = .string(text); return }
        if let dictionary = value as? [String: Any] {
            self = .object(dictionary.mapValues { JSONValue(any: $0) }); return
        }
        if let list = value as? [Any] {
            self = .array(list.map { JSONValue(any: $0) }); return
        }
        self = .null
    }

    /// A Foundation value that JSONSerialization can write. `JSONValue` is a
    /// Swift enum, so it has to be converted before it goes into a
    /// JSONSerialization dictionary.
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.foundationValue)
        case .object(let o): return o.mapValues(\.foundationValue)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Best-effort text for a value: strings pass through, numbers and bools
    /// stringify, everything else is compact JSON.
    public var textValue: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return Int(exactly: n).map { String($0) } ?? String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        default: return (try? stringValue2) ?? ""
        }
    }

    private var stringValue2: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses JSON text.
    public static func parse(_ text: String) throws -> JSONValue {
        let data = Data(text.utf8)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Compact JSON text.
    public var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    /// Builds an object, skipping nil values.
    static func obj(_ pairs: [String: JSONValue?]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (k, v) in pairs { if let v { out[k] = v } }
        return out
    }
}
