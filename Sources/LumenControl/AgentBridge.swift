import Foundation
import os

/// A normalized, typed result of one `tools/call`.
///
/// MCP, the CLI and the UI all consume this value, so an agent and a human
/// interpret tool output the same way: text content, optional MCP image blocks
/// and an optional structured payload.
public struct ToolCallResult: Sendable {
    public let tool: String
    public let isError: Bool
    public let text: String
    public let structured: JSONValue?
    public let images: [ToolOutput.Image]
    /// The complete JSON-RPC result object, for callers that need fields the
    /// normalizer does not surface.
    public let raw: JSONValue

    public init(tool: String, isError: Bool, text: String, structured: JSONValue?,
                images: [ToolOutput.Image] = [], raw: JSONValue) {
        self.tool = tool
        self.isError = isError
        self.text = text
        self.structured = structured
        self.images = images
        self.raw = raw
    }

    /// Reads a field from `structuredContent`, falling back to the first text
    /// content block parsed as JSON. Keeps CLI output identical to MCP output.
    public func value(_ key: String) -> JSONValue? {
        if let structured, let found = structured[key] { return found }
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return parsed[key]
    }
}

/// Typed failures raised by the agent bridge.
///
/// A tool that reports `isError: true` is a *tool* failure and is represented
/// by ``BridgeError/toolFailure(code:hint:deepLink:)``; transport and protocol
/// failures are separate cases so callers can decide what to retry.
public enum BridgeError: Error, Sendable, CustomStringConvertible, Equatable {
    case transport(String)
    case protocolError(String)
    case rpc(code: Int, message: String)
    case toolFailure(code: String, hint: String, deepLink: String?)
    case schema(String)

    public var description: String {
        switch self {
        case .transport(let detail): return "transport: \(detail)"
        case .protocolError(let detail): return "protocol: \(detail)"
        case .rpc(let code, let message): return "jsonrpc(\(code)): \(message)"
        case .toolFailure(let code, let hint, _): return "\(code): \(hint)"
        case .schema(let detail): return "schema: \(detail)"
        }
    }
}

/// One JSON-RPC line in, one line out. Both the daemon socket and the
/// in-process server conform, which is what lets the CLI and tests share the
/// exact code path MCP uses.
public protocol ToolTransport: Sendable {
    func send(_ line: String) async throws -> String
}

/// Runs tool calls against an `MCPServer` without a socket. Used by the CLI
/// when it is embedded in the app process and by every round-trip test.
public final class InProcessToolTransport: ToolTransport, @unchecked Sendable {
    private let server: MCPServer
    private let client: String

    public init(server: MCPServer, client: String = "cli") {
        self.server = server
        self.client = client
    }

    public func send(_ line: String) async throws -> String {
        guard let reply = await server.handle(line, client: client) else {
            throw BridgeError.protocolError("The server returned no reply for a request.")
        }
        return reply
    }
}

/// Talks to the signed Lumen daemon over its unix socket. Capture permissions
/// stay attributed to the daemon, never to the calling CLI process.
public final class SocketToolTransport: ToolTransport, @unchecked Sendable {
    private let socketPath: URL

    public init(socketPath: URL) { self.socketPath = socketPath }

    public func send(_ line: String) async throws -> String {
        let client = UnixSocketClient(socketPath: socketPath)
        try client.connect()
        defer { client.disconnect() }
        return try client.call(line)
    }
}

/// Summary of a tool as advertised by `tools/list`.
public struct ToolListing: Sendable, Equatable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue?
    public let annotations: JSONValue?

    public init(name: String, title: String, description: String, inputSchema: JSONValue,
                outputSchema: JSONValue?, annotations: JSONValue?) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
    }
}

/// The single tool-calling core shared by the MCP proxy and the CLI pipeline
/// commands. Every call is a JSON-RPC `tools/call`; no command reimplements a
/// tool body, so permissions, path confinement, schema validation, audit and
/// idempotency behave identically for agents and humans.
public final class AgentBridge: @unchecked Sendable {
    private let transport: ToolTransport
    private let client: String
    private let ids = OSAllocatedUnfairLock(initialState: 0)

    public init(transport: ToolTransport, client: String = "cli") {
        self.transport = transport
        self.client = client
    }

    /// Convenience: a bridge to the daemon at `socketPath`.
    public convenience init(socketPath: URL, client: String = "cli") {
        self.init(transport: SocketToolTransport(socketPath: socketPath), client: client)
    }

    /// Convenience: a bridge to an in-process MCP server.
    public convenience init(server: MCPServer, client: String = "cli") {
        self.init(transport: InProcessToolTransport(server: server, client: client), client: client)
    }

    private func nextID() -> Int {
        ids.withLock { state in
            state += 1
            return state
        }
    }

    /// Lists the tools advertised by the server. Used by the CLI `--help`
    /// surface and by schema-validation tests.
    public func listTools() async throws -> [ToolListing] {
        let reply = try await request("tools/list", params: [:])
        guard let result = reply["result"],
              let tools = result["tools"]?.arrayValue else {
            throw BridgeError.protocolError("tools/list returned no tools array.")
        }
        return tools.compactMap { item in
            guard let name = item["name"]?.stringValue,
                  let title = item["title"]?.stringValue,
                  let description = item["description"]?.stringValue,
                  let schema = item["inputSchema"] else { return nil }
            return ToolListing(name: name, title: title, description: description,
                               inputSchema: schema, outputSchema: item["outputSchema"],
                               annotations: item["annotations"])
        }
    }

    /// Calls one tool with a JSON object of arguments.
    ///
    /// - Parameters:
    ///   - name: The tool verb, e.g. `record_start`.
    ///   - arguments: Arguments serialized as JSON. Every tool input has
    ///     defaults, so an empty object is valid for zero-argument tools.
    ///   - dryRun: Validate without mutating. Enforced centrally by the server.
    ///   - progressToken: When present, the server emits
    ///     `notifications/progress` on the same connection.
    public func call(_ name: String, arguments: [String: JSONValue] = [:],
                     dryRun: Bool = false, progressToken: String? = nil) async throws -> ToolCallResult {
        guard !name.isEmpty else { throw BridgeError.schema("Tool name must not be empty.") }
        var params: [String: JSONValue] = [
            "name": .string(name),
            "arguments": .object(arguments),
        ]
        if dryRun { params["arguments"] = .object(arguments.merging(["dry_run": .bool(true)]) { _, new in new }) }
        if let progressToken {
            params["_meta"] = .object(["progressToken": .string(progressToken)])
        }
        let reply = try await request("tools/call", params: params)
        if let error = reply["error"] {
            throw BridgeError.rpc(code: error["code"]?.intValue ?? -1,
                                  message: error["message"]?.stringValue ?? "Unknown JSON-RPC error")
        }
        guard let result = reply["result"] else {
            throw BridgeError.protocolError("tools/call returned neither result nor error.")
        }
        let isError = result["isError"]?.boolValue ?? false
        let content = result["content"]?.arrayValue ?? []
        var text = ""
        var images: [ToolOutput.Image] = []
        for block in content {
            switch block["type"]?.stringValue {
            case "text":
                if text.isEmpty { text = block["text"]?.stringValue ?? "" }
            case "image":
                if let encoded = block["data"]?.stringValue,
                   let data = Data(base64Encoded: encoded) {
                    images.append(ToolOutput.Image(data: data, mime: block["mimeType"]?.stringValue ?? "application/octet-stream"))
                }
            default:
                break
            }
        }
        // A failed call carries a typed error in structuredContent/text.
        if isError {
            var code = "FAILED", hint = text, link: String? = nil
            if let structured = result["structuredContent"] ?? parseJSONText(text) {
                code = structured["error"]?["code"]?.stringValue ?? code
                hint = structured["error"]?["hint"]?.stringValue ?? hint
                link = structured["error"]?["deep_link"]?.stringValue
            }
            throw BridgeError.toolFailure(code: code, hint: hint, deepLink: link)
        }
        let structured = result["structuredContent"] ?? parseJSONText(text)
        return ToolCallResult(tool: name, isError: false, text: text, structured: structured,
                              images: images, raw: result)
    }

    /// Calls a tool and returns `structuredContent` or the parsed text object.
    public func callObject(_ name: String, arguments: [String: JSONValue] = [:],
                           dryRun: Bool = false) async throws -> [String: JSONValue] {
        let result = try await call(name, arguments: arguments, dryRun: dryRun)
        guard let object = result.structured?.objectValue else {
            throw BridgeError.protocolError("Tool \(name) did not return an object.")
        }
        return object
    }

    private func request(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        let request: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .int(nextID()),
            "method": .string(method),
            "params": .object(params),
        ])
        let replyText = try await transport.send(request.jsonText)
        guard let reply = try? JSONValue.parse(replyText) else {
            throw BridgeError.protocolError("The server sent a non-JSON reply: \(replyText.prefix(80))")
        }
        return reply
    }
}

private func parseJSONText(_ text: String) -> JSONValue? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
}
