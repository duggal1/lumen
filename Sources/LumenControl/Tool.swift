import Foundation
import os

/// What a tool is allowed to do. Grants are per client and approved by a human.
public enum Capability: String, Sendable, CaseIterable {
    case read, record, actuate, edit, export, network
}

/// A protocol result can carry text data and separate binary image content.
/// AGENT: screenshots were duplicated as base64 text and structured JSON, so MCP clients could not render them as images.
public struct ToolOutput: Sendable {
    public struct Image: Sendable {
        public let data: Data
        public let mime: String

        public init(data: Data, mime: String) {
            self.data = data
            self.mime = mime
        }
    }

    public let json: JSONValue
    public let images: [Image]

    public init(json: JSONValue, images: [Image] = []) {
        self.json = json
        self.images = images
    }

    /// Migrates existing renderer results into MCP image blocks before serialization.
    static func extractingPreview(from value: JSONValue, tool: String) -> ToolOutput {
        guard tool == "preview_frame" || tool == "preview_sheet",
              case .object(var fields) = value,
              case .string(let encoded)? = fields.removeValue(forKey: "image_base64"),
              case .string(let mime)? = fields.removeValue(forKey: "mime_type"),
              let data = Data(base64Encoded: encoded) else {
            return ToolOutput(json: value)
        }
        // AGENT: expose encoded size as ordinary metadata while keeping pixels in a binary image block.
        fields["bytes"] = .int(data.count)
        return ToolOutput(json: .object(fields), images: [Image(data: data, mime: mime)])
    }
}

/// Agent-facing description of one tool.
public struct ToolSpec: Sendable {
    public let name: String                 // verb_noun, snake_case
    /// AGENT: clients need a human-readable label for every listed tool.
    public let title: String
    public let description: String          // when to use, when NOT to, what it returns
    public let capability: Capability
    public let inputSchema: JSONValue       // derived from the Codable input type
    public let required: [String]
    public let mutating: Bool
    public let longRunning: Bool
    /// AGENT: MCP annotations must distinguish reversible edits from destructive actions.
    public let destructive: Bool
    public let idempotent: Bool
    /// AGENT: timeline dry runs need validation against a copied draft, not a generic no-op envelope.
    public let customDryRun: Bool
    /// AGENT: stable small outputs can be described separately from their input schemas.
    public let outputSchema: JSONValue?
}

/// Every tool input gives every property a default so partial JSON can decode.
/// AGENT: tool schemas are declared explicitly, because runtime reflection hid the shape clients need.
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
    /// AGENT: nested inputs cannot be described by reflection, so a tool with a
    /// script or a batch of ops publishes a hand-written schema instead.
    public let schema: JSONValue?
    public let title: String?
    public let destructive: Bool
    public let idempotent: Bool?
    public let customDryRun: Bool
    public let outputSchema: JSONValue?
    let run: @Sendable (Input, ToolContext) async throws -> JSONValue

    public init(name: String, description: String, capability: Capability, required: [String] = [],
                mutating: Bool = false, longRunning: Bool = false, schema: JSONValue? = nil,
                title: String? = nil, destructive: Bool = false, idempotent: Bool? = nil,
                outputSchema: JSONValue? = nil, customDryRun: Bool = false,
                run: @escaping @Sendable (Input, ToolContext) async throws -> JSONValue) {
        self.name = name
        self.description = description
        self.capability = capability
        self.required = required
        self.mutating = mutating
        self.longRunning = longRunning
        self.schema = schema
        self.title = title
        self.destructive = destructive
        self.idempotent = idempotent
        self.outputSchema = outputSchema
        self.customDryRun = customDryRun
        self.run = run
    }

    /// The erased form the registry stores.
    func erase() -> ErasedTool {
        var inputSchema = schema ?? ToolSchemas.schema(for: name, required: required)
        if mutating { inputSchema = J.injectingDryRun(inputSchema) }
        return ErasedTool(spec: ToolSpec(name: name, title: title ?? name.replacingOccurrences(of: "_", with: " "),
                                          description: description, capability: capability,
                                          inputSchema: inputSchema, required: required,
                                          mutating: mutating, longRunning: longRunning,
                                          destructive: destructive, idempotent: idempotent ?? !mutating,
                                          customDryRun: customDryRun,
                                          outputSchema: outputSchema ?? ToolSchemas.outputSchema(for: name)),
                          invoke: { args, ctx in
                              // AGENT: decoding failures must identify the invalid input instead of leaking a Swift debug dump.
                              let input: Input
                              do { input = try JSONDecoder().decode(Input.self, from: Data(args.jsonText.utf8)) }
                              catch let error as DecodingError {
                                  let context: DecodingError.Context
                                  switch error {
                                  case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c): context = c
                                  @unknown default: throw ToolError.invalidArguments("Invalid tool arguments.")
                                  }
                                  let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                                  throw ToolError.invalidArguments("\(path.isEmpty ? "arguments" : path): \(context.debugDescription)")
                              }
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
        // AGENT: required fields must be present before defaults can conceal missing input.
        guard case .object(let fields) = arguments else { throw ToolError.invalidArguments("Arguments must be an object.") }
        for key in tool.spec.required where fields[key] == nil || fields[key] == .null {
            throw ToolError.invalidArguments("Missing required argument: \(key).")
        }
        // AGENT: dry_run was honoured by two tools out of twenty, so enforce it centrally.
        if context.dryRun && tool.spec.mutating && !tool.spec.customDryRun {
            return .object([
                "dry_run": .bool(true),
                "tool": .string(name),
                "would_run_with": arguments,
                "note": .string("Nothing was changed."),
            ])
        }
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
    /// AGENT: long-running tools need an MCP progress route while their request stays open.
    public let progress: (@Sendable (Double, String?) -> Void)?

    public init(engine: Engine, policy: Policy, jobs: JobManager, audit: AuditLog,
                clientID: String, dryRun: Bool,
                progress: (@Sendable (Double, String?) -> Void)? = nil) {
        self.engine = engine
        self.policy = policy
        self.jobs = jobs
        self.audit = audit
        self.clientID = clientID
        self.dryRun = dryRun
        self.paths = PathGuard(policy: policy, client: clientID)
        self.progress = progress
    }

    /// Waits for a job and routes progress to the current MCP request.
    // AGENT: progress callbacks belong to the request that explicitly asked to wait.
    public func waitForJob(_ id: String) async throws -> JobManager.Job {
        try await jobs.waitForCompletion(id, progress: progress)
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
