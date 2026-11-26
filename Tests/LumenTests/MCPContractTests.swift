import Foundation
import Testing
import LumenCore
import LumenProject
import LumenControl

// M5: executable companion to Docs/VIDEO-EDIT-API.md and Docs/AGENT-MCP-EDITING.md.
// These tests parse the shipped docs and compare them with the live registry so
// drift in either direction fails. Pure logic + JSON-RPC over an in-memory fixture:
// headless, no window, no app activation, no global input.

// MARK: - Doc parsing

private func docRoot() -> URL {
    let file = URL(fileURLWithPath: #filePath)
    return file.deletingLastPathComponent()      // Tests/LumenTests
        .deletingLastPathComponent()              // Tests
        .deletingLastPathComponent()              // package root
}

private func docText(_ name: String) throws -> String {
    try String(contentsOf: docRoot().appendingPathComponent("Docs").appendingPathComponent(name),
               encoding: .utf8)
}

/// Returns the meaningful lines inside a `<!-- M5:<marker>:BEGIN/END -->` block.
private func block(_ marker: String, in text: String) -> [String] {
    let begin = "<!-- M5:\(marker):BEGIN -->"
    let end = "<!-- M5:\(marker):END -->"
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == begin }),
          let finish = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == end }),
          finish > start else {
        Issue.record("Missing or unbalanced \(begin) / \(end)")
        return []
    }
    return lines[(start + 1)..<finish]
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("#") }
}

private func cells(_ line: String) -> [String] {
    line.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

private func setOf(_ raw: String) -> Set<String> {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    return trimmed == "-" ? [] : Set(trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
}

private func flag(_ raw: String) -> Bool { raw.trimmingCharacters(in: .whitespaces) == "yes" }

// MARK: - Fixtures

private func makeRegistry() -> ToolRegistry {
    let registry = ToolRegistry()
    registerAllTools(in: registry)
    return registry
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumen-m5-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class ContractRuntime: LumenRuntime, @unchecked Sendable {
    var permissions = RuntimePermissions()
    var lastOptions: RecordingOptions?

    func runtimeStatus() async -> RuntimeStatus {
        RuntimeStatus(phase: "idle", paused: false, recording: false, permissions: permissions,
                      libraryPath: "/tmp/Lumen", projects: 3, activeProjectPath: nil, version: "0.1.0")
    }
    func startRecording(_ target: RecordingTarget, options: RecordingOptions) async throws {
        lastOptions = options
    }
    func stopRecording() async throws -> URL { throw RuntimeFailure("Not used by contract tests.") }
    func pauseRecording() async throws {}
    func resumeRecording() async throws {}
    func addMarker(_ marker: CaptureMarker) async throws {}
    func activeRecordingBundle() async -> URL? { nil }
    func recordingLibrary() async -> [URL] { [] }
}

private struct Fixture {
    let directory: URL
    let server: MCPServer
    let runtime: ContractRuntime
}

private func makeFixture() throws -> Fixture {
    let directory = try tempDir()
    let jobs = JobManager()
    let policy = Policy(fileURL: directory.appendingPathComponent("policy.json"))
    let audit = AuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
    let runtime = ContractRuntime()
    let engine = Engine(runtime: runtime, jobs: jobs, policy: policy)
    let server = MCPServer(registry: makeRegistry(), engine: engine, policy: policy, jobs: jobs, audit: audit)
    return Fixture(directory: directory, server: server, runtime: runtime)
}

private func rpc(_ object: [String: Any]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Catalog

@Test func documentedCatalogMatchesLiveRegistry() throws {
    let rows = block("CONTRACT", in: try docText("VIDEO-EDIT-API.md"))
    #expect(rows.count == 52, "the API doc must describe all 52 tools")

    var documented: [String: [String]] = [:]
    for row in rows {
        let columns = cells(row)
        #expect(columns.count == 11, "malformed catalog row: \(row)")
        if columns.count == 11 { documented[columns[0]] = columns }
    }

    let specs = makeRegistry().allSpecs()
    #expect(specs.count == 52, "registerAllTools must register exactly 52 tools")
    #expect(Set(documented.keys) == Set(specs.map(\.name)), "doc and registry tool names diverged")

    for spec in specs {
        guard let column = documented[spec.name] else { continue }
        let name = spec.name
        #expect(column[1] == spec.capability.rawValue, "\(name): capability")
        let expectedApproval = Set([spec.capability.rawValue] + spec.additionalCapabilities.map(\.rawValue))
            .filter { $0 != "read" }
        #expect(setOf(column[2]) == expectedApproval, "\(name): approval capabilities")
        #expect(setOf(column[3]) == Set(spec.required), "\(name): required arguments")
        #expect(flag(column[4]) == spec.mutating, "\(name): mutating")
        #expect(flag(column[5]) == spec.idempotent, "\(name): idempotent")
        #expect(flag(column[6]) == spec.destructive, "\(name): destructive")
        #expect(flag(column[7]) == spec.longRunning, "\(name): longRunning")
        #expect(flag(column[8]) == spec.customDryRun, "\(name): customDryRun")
        #expect(flag(column[9]) == (spec.outputSchema != nil), "\(name): outputSchema")
        #expect(setOf(column[10]) == Set(spec.additionalCapabilities.map(\.rawValue)), "\(name): additionalCapabilities")
        #expect(spec.title == name.replacingOccurrences(of: "_", with: " "), "\(name): generated title")
    }
}

@Test func registryShapeCountsAreLocked() {
    let specs = makeRegistry().allSpecs()
    let capabilities = Dictionary(grouping: specs, by: \.capability).mapValues(\.count)
    #expect(capabilities == [.read: 13, .record: 5, .actuate: 6, .edit: 25, .network: 1, .export: 2])
    #expect(specs.filter(\.mutating).count == 36)
    #expect(specs.filter(\.destructive).count == 8)
    #expect(specs.filter(\.longRunning).count == 4)
    #expect(specs.filter(\.customDryRun).count == 13)
    #expect(specs.filter { $0.outputSchema != nil }.count == 20)
    #expect(specs.filter { $0.additionalCapabilities.isEmpty }.count == 51)
}

@Test func exactlyOneVideoEditVocabularyIsRegistered() throws {
    let names = Set(makeRegistry().allSpecs().map(\.name))
    // M2's typed edit verbs vs. the general catalog's overlapping edit verbs.
    // Both sets registered at once means agents see two ways to do one edit.
    let typedVerbs = ["cut_span", "set_speed", "set_zoom", "add_music", "remove_music",
                      "add_caption", "get_edit", "render_preview", "export_final"]
    let generalVerbs = ["cut_range", "speed_ramp_set", "zoom_add", "zoom_set", "audio_import",
                        "preview_frame", "preview_sheet", "export_start", "timeline_get"]
    let typedCount = typedVerbs.filter { names.contains($0) }.count
    let generalCount = generalVerbs.filter { names.contains($0) }.count
    #expect(typedCount == 0 || generalCount == 0,
            "two competing video-edit vocabularies are registered; agree one canonical catalog, then update Docs/VIDEO-EDIT-API.md and this table in the same change")

    // Whatever the chosen catalog, every registered name must be documented.
    let documented = Set(block("CONTRACT", in: try docText("VIDEO-EDIT-API.md")).compactMap { cells($0).first })
    #expect(generalVerbs.allSatisfy { !names.contains($0) },
            "the legacy overlapping vocabularies must stay retired: \(generalVerbs.filter { names.contains($0) })")
    #expect(names.isSubset(of: documented),
            "new tools must be added to the contract table: \(names.subtracting(documented).sorted())")
}

@Test func toolsListOnTheWireMatchesTheDocumentedCatalog() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let line = try rpc(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
    let output = try #require(await fixture.server.handle(line, client: "m5-contract"))
    let json = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    let result = try #require(json["result"] as? [String: Any])
    let tools = try #require(result["tools"] as? [[String: Any]])
    #expect(tools.count == 52)

    let registry = makeRegistry()
    #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(registry.allSpecs().map(\.name)))
    for tool in tools {
        let name = tool["name"] as? String ?? ""
        #expect((tool["title"] as? String)?.isEmpty == false, "\(name): missing title")
        #expect(tool["description"] as? String != nil, "\(name): missing description")
        #expect(tool["inputSchema"] as? [String: Any] != nil, "\(name): missing inputSchema")
        #expect(tool["annotations"] as? [String: Any] != nil, "\(name): missing annotations")
        let hasOutput = tool["outputSchema"] as? [String: Any] != nil
        #expect(hasOutput == (registry.spec(name)?.outputSchema != nil), "\(name): outputSchema on the wire")
    }
}

// MARK: - Capabilities and approval

@Test func capabilityAndApprovalModelMatchesPolicy() throws {
    let rows = block("CAPABILITIES", in: try docText("VIDEO-EDIT-API.md"))
    var documented: [String: (Bool, String)] = [:]
    for row in rows {
        let column = cells(row)
        #expect(column.count == 3, "malformed capability row: \(row)")
        if column.count == 3 { documented[column[0]] = (flag(column[1]), column[2]) }
    }
    #expect(Set(documented.keys) == Set(Capability.allCases.map(\.rawValue)))

    let client = Policy.Client()
    #expect(client.capabilities == ["read"], "only read is granted by default")
    for capability in Capability.allCases {
        let values = try #require(documented[capability.rawValue])
        #expect(values.0 == client.capabilities.contains(capability.rawValue),
                "\(capability.rawValue): default grant")
        #expect(values.1 == capability.humanVerb, "\(capability.rawValue): human-facing verb")
    }

    let guide = try docText("AGENT-MCP-EDITING.md")
    for capability in Capability.allCases {
        #expect(guide.contains(capability.humanVerb), "guide omits \(capability.rawValue) prompt copy")
    }
}

// MARK: - Protocol

@Test func documentedProtocolFactsMatchTheServer() async throws {
    let rows = block("PROTOCOL", in: try docText("VIDEO-EDIT-API.md"))
    var facts: [String: String] = [:]
    for row in rows {
        let pair = row.split(separator: "=", maxSplits: 1).map(String.init)
        #expect(pair.count == 2, "malformed protocol fact: \(row)")
        if pair.count == 2 { facts[pair[0]] = pair[1] }
    }
    #expect(facts["protocolVersion"] == MCPServer.protocolVersion)
    #expect(Set((facts["supportedProtocolVersions"] ?? "").split(separator: ",").map(String.init))
            == Set(MCPServer.supportedProtocolVersions))

    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let methods = (facts["methods"] ?? "").split(separator: ",").map(String.init)
    #expect(methods.count == 8)
    for method in methods {
        let request = try rpc(["jsonrpc": "2.0", "id": 1, "method": method, "params": [:]])
        let output = try #require(await fixture.server.handle(request, client: "m5-contract"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        if let error = json["error"] as? [String: Any] {
            #expect(error["code"] as? Int != -32601, "documented method \(method) is not implemented")
        }
    }
    let unknown = try rpc(["jsonrpc": "2.0", "id": 2, "method": "agent/not/a/method"])
    let output = try #require(await fixture.server.handle(unknown))
    let json = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    #expect((json["error"] as? [String: Any])?["code"] as? Int == -32601)
}

// MARK: - Patch ops (the description/schema drift defect)

@Test func documentedPatchOperationsMatchTheDeclaredSchemaEnum() throws {
    let ops = block("PATCH-OPS", in: try docText("VIDEO-EDIT-API.md"))
    let registry = makeRegistry()
    let patch = try #require(registry.spec("timeline_patch"))
    guard case .object(let root) = patch.inputSchema,
          case .object(let properties)? = root["properties"],
          case .object(let opsProperty)? = properties["ops"],
          case .object(let items)? = opsProperty["items"],
          case .object(let opProperties)? = items["properties"],
          case .object(let opProperty)? = opProperties["op"],
          case .array(let values)? = opProperty["enum"] else {
        Issue.record("timeline_patch op enum is missing from the input schema")
        return
    }
    let declared = Set(values.compactMap(\.stringValue))
    #expect(declared.count == 20, "schema must declare all 20 patch operations")
    #expect(Set(ops) == declared, "the doc must list the schema ops, not the stale description")
    #expect(ops.count == 20)
    #expect(registry.spec("edit_apply")?.inputSchema == patch.inputSchema,
            "edit_apply and timeline_patch share the patch schema")

    // Drift guard: the source description text still under-advertises these ops.
    #expect(patch.description.contains("privacy_set"))
    #expect(!patch.description.contains("paste_clip"),
            "if the description starts advertising clip ops, update the doc and remove this note")
}

// MARK: - Errors

@Test func documentedErrorCodesCoverEveryStructuredToolError() throws {
    let rows = block("ERROR-CODES", in: try docText("VIDEO-EDIT-API.md"))
    let documented = Set(rows.compactMap { cells($0).first })
    let guide = try docText("AGENT-MCP-EDITING.md")
    let errors: [ToolError] = [
        .unknownTool("missing"),
        .invalidArguments("bad"),
        .revisionConflict(expected: 1, actual: 2),
        .notRecording(),
        .permission("screen recording", pane: "ScreenCapture"),
        .capabilityDenied(.edit),
        .pathNotAllowed("/tmp/outside"),
        .failed("broken"),
    ]
    #expect(errors.count == 8)
    for error in errors {
        guard case .object(let body) = error.json,
              case .object(let detail)? = body["error"],
              let code = detail["code"]?.stringValue else {
            Issue.record("ToolError did not serialize an error code")
            continue
        }
        #expect(documented.contains(code), "API doc is missing error code \(code)")
        #expect(guide.contains(code), "agent guide is missing error code \(code)")
    }
}

// MARK: - Worked sequence and guide

@Test func workedSequenceUsesOnlyRegisteredToolsInOrder() throws {
    let rows = block("SEQUENCE", in: try docText("VIDEO-EDIT-API.md"))
    var tools: [String] = []
    for row in rows {
        let column = cells(row)
        #expect(column.count == 3, "malformed sequence row: \(row)")
        if column.count == 3 { tools.append(column[1]) }
    }
    let registry = makeRegistry()
    #expect(tools.allSatisfy { registry.spec($0) != nil }, "sequence references an unregistered tool")
    #expect(tools.first == "lumen_status", "preflight must come first")
    #expect(tools.last == "project_close", "the session must be released last")

    func position(_ name: String) -> Int {
        guard let index = tools.firstIndex(of: name) else {
            Issue.record("sequence is missing \(name)")
            return -1
        }
        return index
    }
    let cut = position("cut_span")
    let music = position("add_music")
    let preview = position("render_preview")
    let qa = position("qa_report")
    let export = position("export_final")
    let poll = position("job_status")
    #expect(cut < music, "cut before music")
    #expect(music < preview, "music before visual verification")
    #expect(preview < qa, "look at frames before the QA gate")
    #expect(qa < export, "never export on a failed QA report")
    #expect(export < poll, "poll the export job after starting it")
}

@Test func agentGuideCoversRequiredSectionsAndLinksTheContract() throws {
    let guide = try docText("AGENT-MCP-EDITING.md")
    let sections = [
        "## Connect",
        "## The contract at a glance",
        "## Capabilities and approval",
        "## Worked sequence: cut a sentence → add music → export",
        "## Verifying the result",
        "## Error handling",
        "## Untrusted content",
    ]
    for section in sections {
        #expect(guide.contains(section), "agent guide is missing \(section)")
    }
    #expect(guide.contains("Docs/VIDEO-EDIT-API.md"))
}

// MARK: - Behavioral drift: advertised vs effective fps floor

@Test func recordStartFpsClampMatchesTheDocumentedEffectiveRange() async throws {
    let api = try docText("VIDEO-EDIT-API.md")
    #expect(api.contains("clamps to **24...120**"),
            "document the real fps floor, not only the schema minimum")

    let directory = try tempDir()
    defer { try? FileManager.default.removeItem(at: directory) }
    let jobs = JobManager()
    let policy = Policy(fileURL: directory.appendingPathComponent("policy.json"))
    let audit = AuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
    let runtime = ContractRuntime()
    runtime.permissions.screenRecording = true
    runtime.permissions.inputMonitoring = true
    let engine = Engine(runtime: runtime, jobs: jobs, policy: policy)
    let registry = makeRegistry()
    let context = ToolContext(engine: engine, policy: policy, jobs: jobs, audit: audit,
                              clientID: "m5-contract", dryRun: false)

    let spec = try #require(registry.spec("record_start"))
    guard case .object(let root) = spec.inputSchema,
          case .object(let properties)? = root["properties"],
          case .object(let fps)? = properties["fps"] else {
        Issue.record("record_start fps schema is missing")
        return
    }
    #expect(fps["minimum"]?.doubleValue == 15, "schema advertises 15, the runtime enforces 24")

    _ = try await registry.call("record_start",
                                arguments: .object(["target": .string("display"), "fps": .number(20)]),
                                context: context)
    #expect(runtime.lastOptions?.fps == 24, "a 20 fps request must be clamped to the effective floor")
}

@Test func mcpSkillResourcesAreReadableOverJsonRpc() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let list = try #require(await fixture.server.handle(try rpc(["jsonrpc": "2.0", "id": 1, "method": "resources/list"])))
    let listObject = try #require(JSONSerialization.jsonObject(with: Data(list.utf8)) as? [String: Any])
    let result = try #require(listObject["result"] as? [String: Any])
    let resources = try #require(result["resources"] as? [[String: Any]])
    #expect(resources.contains { $0["uri"] as? String == "lumen://skills/audio-edit" })
    let read = try #require(await fixture.server.handle(try rpc(["jsonrpc": "2.0", "id": 2, "method": "resources/read", "params": ["uri": "lumen://skills/audio-edit"]])))
    let readObject = try #require(JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any])
    let readResult = try #require(readObject["result"] as? [String: Any])
    let contents = try #require(readResult["contents"] as? [[String: Any]])
    let content = try #require(contents.first)
    #expect(content["mimeType"] as? String == "text/markdown")
    #expect((content["text"] as? String)?.contains("audio_edit_v2") == true)
}
