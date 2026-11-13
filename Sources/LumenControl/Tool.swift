import Foundation
import os

/// What a tool is allowed to do. Grants are per client and approved by a human.
public enum Capability: String, Sendable, CaseIterable {
    case read, record, actuate, edit, export, network
}

/// Agent-facing description of one tool.
public struct ToolSpec: Sendable {
    public let name: String                 // verb_noun, snake_case
    public let description: String          // when to use, when NOT to, what it returns
    public let capability: Capability
    public let inputSchema: JSONValue       // derived from the Codable input type
    public let required: [String]
    public let mutating: Bool
    public let longRunning: Bool
}

/// Every tool input gives every property a default, so the schema can be
/// derived by reflection and the arguments can be decoded from a partial JSON
/// object.
public protocol ToolInput: Codable, Sendable {
    init()
}

/// A typed tool.
public struct ToolDefinition<Input: ToolInput>: Sendable {
    public let name: String
    public let description: String
    public let capability: Capability
    public let required: [String]
    public let mutating: Bool
    public let longRunning: Bool
    let run: @Sendable (Input, ToolContext) async throws -> JSONValue

    public init(name: String, description: String, capability: Capability, required: [String] = [],
                mutating: Bool = false, longRunning: Bool = false,
                run: @escaping @Sendable (Input, ToolContext) async throws -> JSONValue) {
        self.name = name
        self.description = description
        self.capability = capability
        self.required = required
        self.mutating = mutating
        self.longRunning = longRunning
        self.run = run
    }

    /// The erased form the registry stores.
    func erase() -> ErasedTool {
        let sample = Input()
        let schema = SchemaGenerator.schema(for: sample, required: required)
        return ErasedTool(spec: ToolSpec(name: name, description: description, capability: capability,
                                          inputSchema: schema, required: required,
                                          mutating: mutating, longRunning: longRunning),
                          invoke: { args, ctx in
                              let input = try JSONDecoder().decode(Input.self, from: Data(args.jsonText.utf8))
                              return try await self.run(input, ctx)
                          })
    }
}

/// Type-erased tool.
public struct ErasedTool: Sendable {
    public let spec: ToolSpec
    let invoke: @Sendable (JSONValue, ToolContext) async throws -> JSONValue
}

/// One registry feeds MCP, the CLI and (later) the UI.
public final class ToolRegistry: @unchecked Sendable {
    private let tools = OSAllocatedUnfairLock<[String: ErasedTool]>(initialState: [:])

    public init() {}

    public func register<Input: ToolInput>(_ definition: ToolDefinition<Input>) {
        let erased = definition.erase()
        tools.withLock { $0[erased.spec.name] = erased }
    }

    public func spec(_ name: String) -> ToolSpec? {
        tools.withLock { $0[name]?.spec }
    }

    public func allSpecs() -> [ToolSpec] {
        tools.withLock { $0.values.map(\.spec).sorted { $0.name < $1.name } }
    }

    public func call(_ name: String, arguments: JSONValue, context: ToolContext) async throws -> JSONValue {
        let tool = tools.withLock { $0[name] }
        guard let tool else { throw ToolError.unknownTool(name) }
        return try await tool.invoke(arguments, context)
    }
}

// MARK: - Errors

/// Everything a tool body needs. One context per call.
public struct ToolContext: Sendable {
    public let engine: Engine
    public let policy: Policy
    public let jobs: JobManager
    public let audit: AuditLog
    /// Which client called. Capability grants are per client.
    public let clientID: String
    /// `dry_run` was requested: the tool must describe what it would do and
    /// change nothing.
    public let dryRun: Bool
    /// AGENT: one guard for every path argument, so no tool can forget confinement.
    public let paths: PathGuard

    public init(engine: Engine, policy: Policy, jobs: JobManager, audit: AuditLog,
                clientID: String, dryRun: Bool) {
        self.engine = engine
        self.policy = policy
        self.jobs = jobs
        self.audit = audit
        self.clientID = clientID
        self.dryRun = dryRun
        self.paths = PathGuard(policy: policy, client: clientID)
    }
}

/// Machine-readable failures. Every error tells the agent what to do next.
public struct ToolError: Error, Sendable {
    public let code: String
    public let hint: String
    public let deepLink: String?

    public init(code: String, hint: String, deepLink: String? = nil) {
        self.code = code; self.hint = hint; self.deepLink = deepLink
    }

    public var json: JSONValue {
        var payload: [String: JSONValue] = [
            "code": .string(code),
            "hint": .string(hint),
        ]
        if let deepLink { payload["deep_link"] = .string(deepLink) }
        return .object(["error": .object(payload)])
    }

    public static func unknownTool(_ name: String) -> ToolError {
        ToolError(code: "UNKNOWN_TOOL", hint: "No tool named \(name). Call tools/list for the catalog.")
    }
    public static func invalidArguments(_ detail: String) -> ToolError {
        ToolError(code: "INVALID_ARGUMENTS", hint: detail)
    }
    public static func revisionConflict(expected: Int, actual: Int) -> ToolError {
        ToolError(code: "REVISION_CONFLICT",
                  hint: "The project changed since revision \(expected) (now \(actual)). Read timeline_get again and re-apply the edit.")
    }
    public static func notRecording() -> ToolError {
        ToolError(code: "NOT_RECORDING", hint: "No recording is running. Call record_start first.")
    }
    public static func permission(_ what: String, pane: String) -> ToolError {
        ToolError(code: "PERMISSION_" + what.uppercased(),
                  hint: "Lumen needs \(what) access. A human must grant it in System Settings > Privacy & Security, then retry.",
                  deepLink: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + pane)
    }
    public static func capabilityDenied(_ capability: Capability) -> ToolError {
        ToolError(code: "CAPABILITY_DENIED",
                  hint: "This client is not allowed to use the \(capability.rawValue) capability. Ask the human to grant it in Lumen > Settings > Agents.")
    }
    public static func pathNotAllowed(_ path: String) -> ToolError {
        ToolError(code: "PATH_NOT_ALLOWED",
                  hint: "\(path) is outside the folders this client may read or write. Grant the folder first.")
    }
    public static func failed(_ message: String) -> ToolError {
        ToolError(code: "FAILED", hint: message)
    }
}
