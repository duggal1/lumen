import Foundation
import Testing
import LumenCore
@testable import LumenControl

// M1: protocol-level acceptance tests for the MCP/JSON-RPC core.
// These are written against the intended contract and run BEFORE the fix.

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private struct MCPCoreFixture {
    let directory: URL
    let server: MCPServer
    let registry: ToolRegistry
}

private func makeFixture() throws -> MCPCoreFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumen-m1-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let jobs = JobManager()
    let policy = Policy(fileURL: directory.appendingPathComponent("policy.json"))
    let audit = AuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
    let engine = Engine(runtime: CoreRuntimeStub(), jobs: jobs, policy: policy)
    let registry = ToolRegistry()
    registry.registerStatusTools()
    let server = MCPServer(registry: registry, engine: engine, policy: policy, jobs: jobs, audit: audit)
    return MCPCoreFixture(directory: directory, server: server, registry: registry)
}

private final class CoreRuntimeStub: LumenRuntime, @unchecked Sendable {
    func runtimeStatus() async -> RuntimeStatus {
        RuntimeStatus(phase: "idle", paused: false, recording: false,
                      permissions: RuntimePermissions(), libraryPath: "/tmp/Lumen",
                      projects: 2, activeProjectPath: nil, version: "0.1.0")
    }
    func startRecording(_ target: RecordingTarget, options: RecordingOptions) async throws {}
    func stopRecording() async throws -> URL { URL(fileURLWithPath: "/tmp/x.lumen") }
    func pauseRecording() async throws {}
    func resumeRecording() async throws {}
    func addMarker(_ marker: CaptureMarker) async throws {}
    func activeRecordingBundle() async -> URL? { nil }
    func recordingLibrary() async -> [URL] { [] }
}

private struct NoInput: ToolInput { init() {} }

private func line(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object)
    return String(decoding: data, as: UTF8.self)
}

private func envelope(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

// MARK: - JSON-RPC error taxonomy

@Test func mcpInvalidMethodIsInvalidRequestNotParseError() async throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let out = try #require(await f.server.handle(try line([
        "jsonrpc": "2.0", "id": 1, "method": 42,
    ])))
    let json = try envelope(out)
    #expect((json["error"] as? [String: Any])?["code"] as? Int == -32600,
            "a well-formed JSON object with a bad method is an Invalid Request, got \(out)")
}

@Test func mcpMissingOrWrongJSONRPCVersionIsInvalidRequest() async throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    for request in [
        ["id": 1, "method": "ping"],
        ["jsonrpc": "1.0", "id": 2, "method": "ping"],
    ] {
        let out = try #require(await f.server.handle(try line(request)))
        let json = try envelope(out)
        #expect((json["error"] as? [String: Any])?["code"] as? Int == -32600,
                "request must declare jsonrpc 2.0, got \(out)")
    }
}

@Test func mcpMalformedNotificationGetsNoReply() async throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    // No `id` means notification: it must never produce a reply, even when malformed.
    let out = await f.server.handle(try line(["method": 42]))
    #expect(out == nil, "notifications must stay silent, got \(out ?? "reply")")
}

@Test func mcpNonScalarIDIsInvalidRequest() async throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let out = try #require(await f.server.handle(try line([
        "jsonrpc": "2.0", "id": ["not": "scalar"], "method": "ping",
    ])))
    let json = try envelope(out)
    #expect((json["error"] as? [String: Any])?["code"] as? Int == -32600,
            "an object id is not a legal JSON-RPC id, got \(out)")
}

@Test func mcpNonObjectJSONAndGarbageUseParseError() async throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }

    for text in ["123", "[]", "true"] {
        let fragment = try #require(await f.server.handle(text))
        let fjson = try envelope(fragment)
        #expect((fjson["error"] as? [String: Any])?["code"] as? Int == -32700,
                "non-object JSON keeps the parse-error code, got \(fragment)")
    }

    let garbage = try #require(await f.server.handle("{not json"))
    let gjson = try envelope(garbage)
    #expect((gjson["error"] as? [String: Any])?["code"] as? Int == -32700)
    #expect(gjson["id"] is NSNull, "parse errors carry a null id")
}

@Test func mcpWrongTypedDryRunNeverAuthorizesAMutation() async throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let counter = Counter()
    f.registry.register(ToolDefinition<NoInput>(name: "m1_mutating",
        description: "Mutates a counter.", capability: .read, mutating: true) { _, _ in
        counter.increment()
        return .object(["done": .bool(true)])
    })
    let out = try #require(await f.server.handle(try line([
        "jsonrpc": "2.0", "id": 6, "method": "tools/call",
        "params": ["name": "m1_mutating", "arguments": ["dry_run": "true"]],
    ])))
    #expect(counter.current == 0, "a present-but-invalid dry_run must not run the tool")
    let json = try envelope(out)
    #expect((json["error"] as? [String: Any])?["code"] as? Int == -32602,
            "invalid dry_run type is invalid params, got \(out)")
}

// MARK: - Argument validation

@Test func mcpNonObjectArgumentsAreRejected() async throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let out = try #require(await f.server.handle(try line([
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": ["name": "lumen_status", "arguments": 7],
    ])))
    let json = try envelope(out)
    #expect((json["error"] as? [String: Any])?["code"] as? Int == -32602,
            "a non-object arguments value is invalid params, got \(out)")
}

// MARK: - Safe serialization

@Test func mcpSanitizeNeutralizesNonFiniteNumbers() {
    let value: [String: Any] = [
        "nan": Double.nan,
        "pos": Double.infinity,
        "neg": -Double.infinity,
        "nested": ["ok": 1.5, "list": [Double.nan, 2.0]],
    ]
    let clean = MCPServer.sanitize(value) as! [String: Any]
    func assertFinite(_ v: Any) {
        if let d = v as? Double { #expect(d.isFinite); return }
        if let a = v as? [Any] { a.forEach(assertFinite); return }
        if let o = v as? [String: Any] { o.values.forEach(assertFinite); return }
        if v is NSNull { return }
    }
    assertFinite(clean)
    #expect(clean["nan"] is NSNull)
    #expect((clean["nested"] as? [String: Any])?["list"] as? [Any] != nil)
}

@Test func mcpNonFiniteToolResultKeepsAWellFormedEnvelope() async throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    f.registry.register(ToolDefinition<NoInput>(name: "nan_tool",
        description: "Returns non-finite numbers.", capability: .read) { _, _ in
        .object(["value": .number(Double.nan),
                 "list": .array([.number(Double.infinity), .number(2.0)])])
    })
    let out = try #require(await f.server.handle(try line([
        "jsonrpc": "2.0", "id": 11, "method": "tools/call",
        "params": ["name": "nan_tool", "arguments": [:]],
    ])))
    let json = try envelope(out)
    #expect(json["id"] as? Int == 11)
    #expect(json["result"] != nil, "the reply must survive a NaN in tool output: \(out)")
    #expect(json["error"] == nil)
}

// MARK: - Error hygiene

@Test func mcpUnexpectedErrorDoesNotLeakImplementationDetails() async throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let secret = "SECRET_M1_9f3a21"
    f.registry.register(ToolDefinition<NoInput>(name: "leaky_tool",
        description: "Throws an internal error.", capability: .read) { _, _ in
        throw NSError(domain: secret, code: 7, userInfo: [NSLocalizedDescriptionKey: secret])
    })
    let out = try #require(await f.server.handle(try line([
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": ["name": "leaky_tool", "arguments": [:]],
    ])))
    #expect(!out.contains(secret), "tool errors must not echo internal error text: \(out)")
    let json = try envelope(out)
    #expect((json["result"] as? [String: Any])?["isError"] as? Bool == true)
}

// MARK: - Notifications and progress (contract that must keep working)

@Test func mcpInitializedNoticeStaysSilentAndProgressTokenIsHonored() async throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let notice = await f.server.handle(try line(["jsonrpc": "2.0", "method": "notifications/initialized"]))
    #expect(notice == nil)

    f.registry.register(ToolDefinition<NoInput>(name: "slow_tool",
        description: "Reports progress.", capability: .read) { _, ctx in
        ctx.progress?(0.5, "halfway")
        return .object(["done": .bool(true)])
    })
    // @unchecked Sendable: guarded by an NSLock; the MCP notify closure is @Sendable.
    final class SentBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ s: String) { lock.lock(); values.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }
    let sent = SentBox()
    let out = try #require(await f.server.handle(try line([
        "jsonrpc": "2.0", "id": 5, "method": "tools/call",
        "params": ["name": "slow_tool", "arguments": [:],
                   "_meta": ["progressToken": "tok-5"]],
    ]), notify: { sent.append($0) }))
    #expect((try envelope(out))["result"] != nil)
    let progress = try #require(sent.all.first)
    let pj = try envelope(progress)
    #expect(pj["method"] as? String == "notifications/progress")
    #expect(((pj["params"] as? [String: Any])?["progressToken"] as? String) == "tok-5")
}

// MARK: - Bounded reads

@Test func mcpIdleClientIsReleased() throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let dir = URL(fileURLWithPath: "/tmp/lumen-m1-idle-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sock = dir.appendingPathComponent("agent.sock")
    let server = UnixSocketServer(socketPath: sock, server: f.server, idleTimeout: 0.3)
    try server.start(); defer { server.stop() }

    let client = UnixSocketClient(socketPath: sock)
    defer { client.disconnect() }
    try client.connect(timeout: 3)
    do {
        _ = try client.receive(timeout: 3)
        Issue.record("an idle client must be disconnected")
    } catch let e as ToolError {
        #expect(e.hint.contains("closed"), "expected an idle disconnect, got \(e.hint)")
    }
}

@Test func mcpOversizedLineClosesTheConnection() throws {
    let f = try makeFixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
    let dir = URL(fileURLWithPath: "/tmp/lumen-m1-sock-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = UnixSocketServer(socketPath: dir.appendingPathComponent("agent.sock"), server: f.server)
    try server.start(); defer { server.stop() }

    let client = UnixSocketClient(socketPath: dir.appendingPathComponent("agent.sock"))
    defer { client.disconnect() }
    try client.connect(timeout: 3)
    // The daemon may close the socket mid-write once the cap is hit; that is the
    // expected behaviour, so the send itself is best-effort here.
    try? client.send(String(repeating: "x", count: 5 * 1024 * 1024))

    do {
        _ = try client.receive(timeout: 2)
        Issue.record("an oversized line must close the connection")
    } catch let e as ToolError {
        #expect(e.hint.contains("closed"), "expected the daemon to close the connection, got \(e.hint)")
    }
}
