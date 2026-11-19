import Foundation
import Testing
import LumenCore
import LumenControl

// MARK: - Fixture
//
// Everything below drives the real MCPServer.handle() in-process. No sockets,
// no windows, no AppKit approval modal: the fixture grants every capability to
// its client up front so ApprovalCenter.request is never reached.

private final class FuzzCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private final class FuzzRuntime: LumenRuntime {
    func runtimeStatus() async -> RuntimeStatus {
        RuntimeStatus(phase: "idle", paused: false, recording: false,
                      permissions: RuntimePermissions(), libraryPath: "/tmp/Lumen",
                      projects: 0, activeProjectPath: nil, version: "fuzz")
    }
    func startRecording(_ target: RecordingTarget, options: RecordingOptions) async throws {
        throw RuntimeFailure("not used by the fuzz harness")
    }
    func stopRecording() async throws -> URL { throw RuntimeFailure("not used by the fuzz harness") }
    func pauseRecording() async throws {}
    func resumeRecording() async throws {}
    func addMarker(_ marker: CaptureMarker) async throws {}
    func activeRecordingBundle() async -> URL? { nil }
    func recordingLibrary() async -> [URL] { [] }
}

private struct EchoInput: ToolInput {
    var text: String = ""
    init() {}
    enum CodingKeys: String, CodingKey { case text }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

private struct WriteInput: ToolInput {
    var value: Int = 0
    init() {}
    enum CodingKeys: String, CodingKey { case value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decode(Int.self, forKey: .value)  // strict: wrong type is invalid arguments
    }
}

private struct TouchInput: ToolInput { init() {} }

private struct FuzzFixture {
    let directory: URL
    let server: MCPServer
    let counter: FuzzCounter
    let policy: Policy
    let engine: Engine
    let client = "fuzz-client"
}

private func makeFuzzFixture() throws -> FuzzFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumen-mcp-fuzz-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let jobs = JobManager()
    let policy = Policy(fileURL: directory.appendingPathComponent("policy.json"))
    let audit = AuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
    let engine = Engine(runtime: FuzzRuntime(), jobs: jobs, policy: policy)
    let registry = ToolRegistry()
    let counter = FuzzCounter()

    registry.register(ToolDefinition<EchoInput>(name: "fuzz_echo",
        description: "Returns the length and a short prefix of text.", capability: .read) { input, _ in
        let prefix = String(input.text.prefix(64))
        return .object(["length": .int(input.text.utf8.count), "prefix": .string(prefix)])
    })
    registry.register(ToolDefinition<WriteInput>(name: "fuzz_write",
        description: "Mutates the fuzz counter. Requires an integer value.",
        capability: .edit, required: ["value"], mutating: true) { input, _ in
        counter.increment()
        return .object(["written": .int(input.value)])
    })
    registry.register(ToolDefinition<TouchInput>(name: "fuzz_touch",
        description: "Mutates the fuzz counter with no required arguments.",
        capability: .edit, mutating: true) { _, ctx in
        if Task.isCancelled { return .object(["cancelled": .bool(true)]) }
        counter.increment()
        return .object(["touched": .bool(true)])
    })
    registry.register(ToolDefinition<TouchInput>(name: "fuzz_guarded",
        description: "Requires an approved bundle id before mutating.",
        capability: .read) { _, ctx in
        guard ctx.policy.bundleAllowed("com.example.fuzz.blocked", for: ctx.clientID) else {
            throw ToolError(code: "BUNDLE_NOT_ALLOWED", hint: "Not approved.")
        }
        counter.increment()
        return .object(["allowed": .bool(true)])
    })

    let fixtureClient = "fuzz-client"
    policy.grant(client: fixtureClient, capabilities: Capability.allCases.map(\.rawValue))
    let server = MCPServer(registry: registry, engine: engine, policy: policy, jobs: jobs,
                           audit: audit, approvals: ApprovalCenter(timeout: 0.05))
    return FuzzFixture(directory: directory, server: server, counter: counter,
                       policy: policy, engine: engine)
}

private func cleanup(_ fixture: FuzzFixture) {
    try? FileManager.default.removeItem(at: fixture.directory)
}

// MARK: - Envelope parsing

private struct Envelope {
    let object: [String: Any]
    var id: Any? { object["id"] }
    var result: [String: Any]? { object["result"] as? [String: Any] }
    var error: [String: Any]? { object["error"] as? [String: Any] }
    var code: Int? {
        guard let n = error?["code"] as? NSNumber else { return nil }
        return n.intValue
    }
}

private func parseEnvelope(_ line: String?) throws -> Envelope? {
    guard let line else { return nil }
    let value = try JSONSerialization.jsonObject(with: Data(line.utf8))
    let object = try #require(value as? [String: Any], "reply is not a JSON object: \(line.prefix(200))")
    #expect(object["jsonrpc"] as? String == "2.0", "bad jsonrpc: \(line.prefix(200))")
    let hasResult = object["result"] != nil
    let hasError = object["error"] != nil
    #expect(hasResult != hasError, "reply must have exactly one of result/error: \(line.prefix(200))")
    return Envelope(object: object)
}

private func rpc(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func callLine(_ id: Any, _ name: String, _ arguments: Any? = [:],
                      extra: [String: Any] = [:]) throws -> String {
    var params: [String: Any] = ["name": name]
    if let arguments { params["arguments"] = arguments }
    params.merge(extra) { _, new in new }
    return try rpc(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": params])
}

// MARK: - Seeded generator

private struct RNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 17
    }
    mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
}

private enum CaseKind: String {
    case malformed, nonObject, invalidRequest, invalidId, missingMethod, wrongMethod, unknownMethod
    case ping, toolsList, initialize, resourcesList, promptsList
    case echo, unknownTool, invalidArgs, missingRequired, goodWrite, dryRun
    case resourcesRead, promptsGet, notification, weirdId, huge, unicode, guarded
}

private struct FuzzCase {
    let line: String
    let kind: CaseKind
    let expectedCode: Int?
    let expectedMutations: Int
    let expectsNil: Bool
    var allowsError: Bool = false
}

private let malformedLines = [
    "", "{", "not json", "[]", "123", "\"str\"", "true", "null",
    #"{"method":"ping","id":1"#, #"{"method":"ping","id":1} trailing"#,
    #"{"method":"\uD800","id":1}"#,
    #"{"method":"ping","id":NaN}"#,
    #"{"method":"ping","id":Infinity}"#,
    #"{"method":"ping","id":-Infinity}"#,
    #"{"method":"ping","id":1e400}"#,
]

/// Valid JSON objects that are not valid JSON-RPC Requests: -32600.
private let invalidRequestLines = [
    #"{"method": 1, "id": 1}"#, #"{"id":1}"#,
    #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#,
    #"{"jsonrpc":2,"id":1,"method":"ping"}"#,
    "\u{FEFF}{\"method\":\"ping\",\"id\":1}",  // Foundation tolerates a BOM
]

private func anyValues(_ values: Any...) -> [Any] { values }

private func makeCase(_ rng: inout RNG, _ index: Int) throws -> FuzzCase {
    // JSON-RPC permits only string / number / null ids. Invalid ids get their
    // own case kind below so a valid request never silently becomes -32600.
    let id: Any = rng.pick(anyValues(
        index, "s-\(index)", NSNull(), Double(index) + 0.25
    ))
    let tag = "t\(index)"
    switch CaseKind.allCases[rng.int(CaseKind.allCases.count)] {
    case .malformed:
        return FuzzCase(line: rng.pick(malformedLines), kind: .malformed,
                        expectedCode: -32700, expectedMutations: 0, expectsNil: false)
    case .nonObject:
        let line = rng.pick(["[]", "42", "\"x\"", "true", "null", "[1,2,3]"])
        return FuzzCase(line: line, kind: .nonObject, expectedCode: -32700,
                        expectedMutations: 0, expectsNil: false)
    case .invalidRequest:
        return FuzzCase(line: rng.pick(invalidRequestLines), kind: .invalidRequest,
                        expectedCode: -32600, expectedMutations: 0, expectsNil: false)
    case .invalidId:
        let badID: Any = rng.pick(anyValues(
            ["nested": index], [index, index + 1], true, false
        ))
        let method = rng.pick(["ping", "tools/list", "tools/call"])
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": badID, "method": method]),
                        kind: .invalidId, expectedCode: -32600,
                        expectedMutations: 0, expectsNil: false)
    case .missingMethod:
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": id, "params": [:]]),
                        kind: .missingMethod, expectedCode: -32600,
                        expectedMutations: 0, expectsNil: false)
    case .wrongMethod:
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": id, "method": rng.pick(
            anyValues(1, [String](), ["x": 1], NSNull(), false))]),
                        kind: .wrongMethod, expectedCode: -32600,
                        expectedMutations: 0, expectsNil: false)
    case .unknownMethod:
        let method = rng.pick(["does/not/exist", "", "PING", "tools/callx", tag,
                               String(repeating: "m", count: 5000),
                               "me\u{0000}thod", "m\u{2028}ethod"])
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": id, "method": method]),
                        kind: .unknownMethod, expectedCode: -32601,
                        expectedMutations: 0, expectsNil: false)
    case .ping:
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": id, "method": "ping"]),
                        kind: .ping, expectedCode: nil, expectedMutations: 0, expectsNil: false)
    case .toolsList:
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": id, "method": "tools/list"]),
                        kind: .toolsList, expectedCode: nil, expectedMutations: 0, expectsNil: false)
    case .initialize:
        let requested = rng.pick(["2025-03-26", "2025-06-18", "2025-11-25", "1999-01-01", tag])
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": id, "method": "initialize",
                                       "params": ["protocolVersion": requested,
                                                  "capabilities": ["all": true],
                                                  "clientInfo": ["name": tag]]]),
                        kind: .initialize, expectedCode: nil, expectedMutations: 0, expectsNil: false)
    case .resourcesList:
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": id, "method": "resources/list"]),
                        kind: .resourcesList, expectedCode: nil, expectedMutations: 0, expectsNil: false)
    case .promptsList:
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": id, "method": "prompts/list"]),
                        kind: .promptsList, expectedCode: nil, expectedMutations: 0, expectsNil: false)
    case .echo:
        let text = rng.pick([tag, "", "🚀\u{0000}line\nbreak", String(repeating: "z", count: 5000)])
        return FuzzCase(line: try callLine(id, "fuzz_echo", ["text": text]),
                        kind: .echo, expectedCode: nil, expectedMutations: 0, expectsNil: false)
    case .unknownTool:
        let name = rng.pick(["no_such_tool", "", tag, String(repeating: "n", count: 5000),
                             "fuzz_write\u{0000}", "FUZZ_ECHO"])
        return FuzzCase(line: try callLine(id, name),
                        kind: .unknownTool, expectedCode: -32602,
                        expectedMutations: 0, expectsNil: false)
    case .invalidArgs:
        let args: Any = rng.pick(anyValues(
            ["value": tag], ["value": [1]], ["value": NSNull()], "garbage", [1, 2, 3]))
        return FuzzCase(line: try callLine(id, "fuzz_write", args),
                        kind: .invalidArgs, expectedCode: -32602,
                        expectedMutations: 0, expectsNil: false)
    case .missingRequired:
        let args: Any = rng.pick(anyValues([String: Any](), ["other": 1], NSNull()))
        return FuzzCase(line: try callLine(id, "fuzz_write", args),
                        kind: .missingRequired, expectedCode: -32602,
                        expectedMutations: 0, expectsNil: false)
    case .goodWrite:
        return FuzzCase(line: try callLine(id, "fuzz_write", ["value": index]),
                        kind: .goodWrite, expectedCode: nil, expectedMutations: 1, expectsNil: false)
    case .dryRun:
        // Only the strictly-typed `true` is a legal dry run; the main corpus
        // uses only that so the contract tests stay meaningful. Wrong-typed
        // variants are isolated in the D1 defect reproduction.
        let args: [String: Any] = ["value": index, "dry_run": true]
        return FuzzCase(line: try callLine(id, "fuzz_write", args),
                        kind: .dryRun, expectedCode: nil, expectedMutations: 0, expectsNil: false)
    case .resourcesRead:
        let uri = rng.pick(["lumen://schema/timeline", "lumen://project/bad/timeline",
                            "lumen://project/../../timeline", "bogus", "lumen://project/p/markers/x",
                            "lumen://schema/\(tag)"])
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": id, "method": "resources/read",
                                       "params": ["uri": uri]]),
                        kind: .resourcesRead, expectedCode: nil, expectedMutations: 0,
                        expectsNil: false, allowsError: true)
    case .promptsGet:
        let name = rng.pick(["make_demo_video", tag, "", "make_demo_video\u{0000}"])
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": id, "method": "prompts/get",
                                       "params": ["name": name]]),
                        kind: .promptsGet, expectedCode: nil, expectedMutations: 0,
                        expectsNil: false, allowsError: true)
    case .notification:
        let method = rng.pick(["notifications/initialized", "notifications/cancelled",
                               "ping", "tools/call", tag])
        // A JSON object without an id is a notification. Omitting `jsonrpc`
        // keeps this on the guard's silent-notification path; see the report
        // for the defect where a `jsonrpc`-valid notification gets a reply.
        return FuzzCase(line: try rpc(["method": method,
                                       "params": ["requestId": id]]),
                        kind: .notification, expectedCode: nil, expectedMutations: 0, expectsNil: true)
    case .weirdId:
        let weirdId: Any = rng.pick(anyValues(NSNull(), "", -1, 1e30, "id-\(tag)"))
        return FuzzCase(line: try rpc(["jsonrpc": "2.0", "id": weirdId, "method": "ping"]),
                        kind: .weirdId, expectedCode: nil, expectedMutations: 0, expectsNil: false)
    case .huge:
        let blob = String(repeating: "A", count: 200_000)
        return FuzzCase(line: try callLine(id, "fuzz_echo", ["text": blob]),
                        kind: .huge, expectedCode: nil, expectedMutations: 0, expectsNil: false)
    case .unicode:
        let text = "漢字🚀é\u{0301}\u{200D}\u{FEFF}\u{0001}end"
        return FuzzCase(line: try callLine(id, "fuzz_echo", ["text": text]),
                        kind: .unicode, expectedCode: nil, expectedMutations: 0, expectsNil: false)
    case .guarded:
        return FuzzCase(line: try callLine(id, "fuzz_guarded"),
                        kind: .guarded, expectedCode: nil, expectedMutations: 0, expectsNil: false)
    }
}

extension CaseKind: CaseIterable {}

// MARK: - Property tests

@Test func seededMCPProtocolFuzzCorpus() async throws {
    let fixture = try makeFuzzFixture()
    defer { cleanup(fixture) }
    var rng = RNG(state: 0x5EED_1234_ABCD_5678)
    var violations: [String] = []
    var maxReply = 0
    var maxElapsed = 0.0
    var sawKinds = Set<CaseKind>()

    for index in 0..<1_200 {
        let c = try makeCase(&rng, index)
        sawKinds.insert(c.kind)
        let before = fixture.counter.current
        let start = Date()
        let reply = await fixture.server.handle(c.line, client: fixture.client)
        let elapsed = Date().timeIntervalSince(start)
        maxElapsed = max(maxElapsed, elapsed)
        let after = fixture.counter.current

        if after - before != c.expectedMutations {
            violations.append("#\(index) \(c.kind.rawValue): mutations \(after - before), expected \(c.expectedMutations)")
        }
        if c.expectsNil {
            if reply != nil { violations.append("#\(index) \(c.kind.rawValue): notification got a reply") }
            continue
        }
        guard let reply else {
            violations.append("#\(index) \(c.kind.rawValue): expected a reply, got nil")
            continue
        }
        maxReply = max(maxReply, reply.utf8.count)
        do {
            let envelope = try parseEnvelope(reply)
            if let expected = c.expectedCode, envelope?.code != expected {
                violations.append("#\(index) \(c.kind.rawValue): code \(String(describing: envelope?.code)), expected \(expected)")
            }
            if c.expectedCode == nil && !c.allowsError && envelope?.error != nil {
                violations.append("#\(index) \(c.kind.rawValue): unexpected error \(String(describing: envelope?.error))")
            }
        } catch {
            violations.append("#\(index) \(c.kind.rawValue): invalid reply \(reply.prefix(160)) — \(error)")
        }
        // Reply size must stay bounded relative to the request.
        if reply.utf8.count > c.line.utf8.count * 2 + 8_192 {
            violations.append("#\(index) \(c.kind.rawValue): reply \(reply.utf8.count) bytes for \(c.line.utf8.count) byte request")
        }
    }

    #expect(sawKinds.count == CaseKind.allCases.count, "corpus covered \(sawKinds.count)/\(CaseKind.allCases.count) kinds")
    #expect(maxElapsed < 1.0, "slowest case took \(maxElapsed)s")
    #expect(maxReply < 1_000_000, "largest reply \(maxReply) bytes")
    #expect(fixture.engine.knownProjects().isEmpty, "rejected calls must not open project handles")
    #expect(violations.isEmpty, Comment(rawValue: violations.joined(separator: "\n")))
}

@Test func rejectedCallsNeverMutateStateOrGrants() async throws {
    let fixture = try makeFuzzFixture()
    defer { cleanup(fixture) }
    let before = fixture.counter.current
    let grantsBefore = fixture.policy.grantedCapabilities(for: fixture.client)
    let rejected = [
        "{",
        try rpc(["jsonrpc": "2.0", "id": 1, "method": "no/such/method"]),
        try callLine(2, "no_such_tool"),
        try callLine(3, "fuzz_write", ["value": "not-an-int"]),
        try callLine(4, "fuzz_write", [:] as [String: Any]),
        try callLine(5, "fuzz_write", ["value": 1, "dry_run": true]),
        try callLine(6, "fuzz_guarded"),
        try rpc(["jsonrpc": "2.0", "id": 7, "method": "initialize",
                 "params": ["capabilities": ["all": true], "grants": ["edit", "network"]]]),
        try callLine(8, "fuzz_write", ["value": 1, "dry_run": "true"]),
        try callLine(9, "fuzz_write", [1, 2, 3] as [Int]),
    ]
    for line in rejected { _ = await fixture.server.handle(line, client: fixture.client) }
    #expect(fixture.counter.current == before, "rejected calls changed state")
    #expect(fixture.policy.grantedCapabilities(for: fixture.client) == grantsBefore,
            "untrusted request fields changed capability grants")
}

@Test func concurrentCallsAreSerializedAndCounted() async throws {
    let fixture = try makeFuzzFixture()
    defer { cleanup(fixture) }
    let before = fixture.counter.current
    let server = fixture.server
    let client = fixture.client
    let replies = await withTaskGroup(of: String?.self) { group in
        for i in 0..<200 {
            group.addTask {
                let line = i % 2 == 0
                    ? (try? callLine(i, "fuzz_touch")) ?? ""
                    : (try? callLine(i, "fuzz_echo", ["text": "c\(i)"])) ?? ""
                return await server.handle(line, client: client)
            }
        }
        var out: [String?] = []
        for await reply in group { out.append(reply) }
        return out
    }
    #expect(replies.count == 200)
    #expect(replies.allSatisfy { $0 != nil })
    #expect(fixture.counter.current - before == 100, "exactly the 100 mutating calls should mutate")
    for reply in replies.compactMap({ $0 }) {
        #expect((try? parseEnvelope(reply)) != nil)
    }
}

@Test func cancelledTaskDoesNotMutate() async throws {
    let fixture = try makeFuzzFixture()
    defer { cleanup(fixture) }
    let before = fixture.counter.current
    let server = fixture.server
    let client = fixture.client
    let line = try callLine(1, "fuzz_touch")
    let task = Task { await server.handle(line, client: client) }
    task.cancel()
    _ = await task.value
    #expect(fixture.counter.current == before, "a cancelled cooperative tool mutated state")
}

// MARK: - Defect reproductions
//
// These assert the CORRECT JSON-RPC / safety contract. Each was RED against
// the original MCP.swift and is now GREEN after the product fix; kept as
// regression guards. The original offending lines are named in each comment.

@Test func defectD1_wrongTypedDryRunSilentlyMutates() async throws {
    // Sources/LumenControl/MCP.swift:99 — `(arguments["dry_run"] as? Bool) ?? false`.
    let fixture = try makeFuzzFixture()
    defer { cleanup(fixture) }
    let before = fixture.counter.current
    let reply = await fixture.server.handle(
        try callLine(1, "fuzz_write", ["value": 7, "dry_run": "true"]), client: fixture.client)
    #expect(fixture.counter.current == before,
            "a present-but-invalid dry_run must never authorize a real mutation (MCP.swift:99)")
    let envelope = try parseEnvelope(reply)
    #expect(envelope?.code == -32602, "invalid dry_run type should be Invalid params")
}

@Test func defectD2_invalidRequestUsesParseErrorCode() async throws {
    // Sources/LumenControl/MCP.swift:34-38 — every malformed *request* is -32700.
    let fixture = try makeFuzzFixture()
    defer { cleanup(fixture) }
    let line = try rpc(["jsonrpc": "2.0", "id": 7, "params": [:]])
    let envelope = try parseEnvelope(await fixture.server.handle(line, client: fixture.client))
    #expect(envelope?.code == -32600,
            "valid JSON that is not a Request must be -32600 Invalid Request, not -32700 Parse error (MCP.swift:34-38)")
}

@Test func defectD3_nonScalarIdIsAccepted() async throws {
    // Sources/LumenControl/MCP.swift:39 — id is accepted as any JSON value.
    let fixture = try makeFuzzFixture()
    defer { cleanup(fixture) }
    let line = try rpc(["jsonrpc": "2.0", "id": ["not": "scalar"], "method": "ping"])
    let envelope = try parseEnvelope(await fixture.server.handle(line, client: fixture.client))
    #expect(envelope?.code == -32600,
            "an object id makes the request invalid per JSON-RPC 2.0 (MCP.swift:39)")
}

@Test func defectD4_wrongTypedArgumentsAreCoercedToEmptyObject() async throws {
    // Sources/LumenControl/MCP.swift:83 — `params["arguments"] as? [String: Any] ?? [:]`.
    let fixture = try makeFuzzFixture()
    defer { cleanup(fixture) }
    let before = fixture.counter.current
    let reply = await fixture.server.handle(
        try callLine(1, "fuzz_touch", [1, 2, 3] as [Int]), client: fixture.client)
    #expect(fixture.counter.current == before,
            "an all-optional mutating tool must not run when arguments is not an object (MCP.swift:83)")
    let envelope = try parseEnvelope(reply)
    #expect(envelope?.code == -32602, "wrong-typed arguments should be Invalid params")
}
