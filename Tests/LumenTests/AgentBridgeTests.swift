import Foundation
import Testing
import os
import CoreGraphics
import LumenCore
import LumenControl

/// A5 — the shared agent tool core. These tests drive the exact bridge used by
/// `lumen-cli record|edit|export` and by the MCP proxy, against an in-process
/// MCP server and a mock `LumenRuntime`. No Metal, no window, no real capture.
@Suite(.serialized)
struct AgentBridgeTests {

    // MARK: Mock runtime

    private final class RecordingRuntime: LumenRuntime, @unchecked Sendable {
        private struct State {
            var permissions = RuntimePermissions()
            var target: RecordingTarget?
            var options: RecordingOptions?
            var paused = false
            var marks: [CaptureMarker] = []
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        func configure(screen: Bool, input: Bool, mic: Bool) {
            state.withLock {
                $0.permissions = RuntimePermissions()
                $0.permissions.screenRecording = screen
                $0.permissions.inputMonitoring = input
                $0.permissions.microphone = mic
            }
        }

        func captured() -> (target: RecordingTarget?, options: RecordingOptions?, paused: Bool, marks: [CaptureMarker]) {
            state.withLock { ($0.target, $0.options, $0.paused, $0.marks) }
        }

        func runtimeStatus() async -> RuntimeStatus {
            state.withLock { s in
                var status = RuntimeStatus()
                status.phase = s.target == nil ? "idle" : "recording"
                status.recording = s.target != nil
                status.paused = s.paused
                status.permissions = s.permissions
                status.libraryPath = "/tmp/lumen-bridge-tests"
                return status
            }
        }

        func startRecording(_ target: RecordingTarget, options: RecordingOptions) async throws {
            state.withLock {
                $0.target = target
                $0.options = options
                $0.paused = false
            }
        }

        func stopRecording() async throws -> URL {
            state.withLock { $0.target = nil }
            return URL(fileURLWithPath: "/tmp/lumen-bridge-tests/project.lumen")
        }

        func pauseRecording() async throws {
            try state.withLock {
                guard $0.target != nil else { throw RuntimeFailure("not recording") }
                $0.paused = true
            }
        }

        func resumeRecording() async throws {
            try state.withLock {
                guard $0.target != nil else { throw RuntimeFailure("not recording") }
                $0.paused = false
            }
        }

        func addMarker(_ marker: CaptureMarker) async throws {
            state.withLock { $0.marks.append(marker) }
        }

        func activeRecordingBundle() async -> URL? { nil }
        func recordingLibrary() async -> [URL] { [] }
    }

    private struct Fixture {
        let directory: URL
        let runtime: RecordingRuntime
        let bridge: AgentBridge
        let registry: ToolRegistry
    }

    private func makeFixture(screen: Bool = true, input: Bool = true, mic: Bool = true) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-a5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtime = RecordingRuntime()
        runtime.configure(screen: screen, input: input, mic: mic)
        let jobs = JobManager()
        let policy = Policy(fileURL: directory.appendingPathComponent("policy.json"))
        policy.grant(client: "a5-test", capabilities: Capability.allCases.map(\.rawValue))
        let audit = AuditLog(fileURL: directory.appendingPathComponent("audit.jsonl"))
        let engine = Engine(runtime: runtime, jobs: jobs, policy: policy)
        let registry = ToolRegistry()
        registerAllTools(in: registry)
        let server = MCPServer(registry: registry, engine: engine, policy: policy, jobs: jobs, audit: audit)
        return Fixture(directory: directory, runtime: runtime,
                       bridge: AgentBridge(server: server, client: "a5-test"), registry: registry)
    }

    private func cleanup(_ directory: URL) { try? FileManager.default.removeItem(at: directory) }

    // MARK: Strict JSON schemas

    @Test func bridgeListsStrictSchemasForEveryTool() async throws {
        let f = try makeFixture(); defer { cleanup(f.directory) }
        let tools = try await f.bridge.listTools()
        #expect(tools.count >= 50, "expected the full pipeline catalog, got \(tools.count)")

        let names = Set(tools.map(\.name))
        for required in ["record_start", "record_stop", "list_displays", "list_windows", "lumen_status",
                         "trim_clip", "split_clip", "set_speed", "post_process", "crop_set", "cursor_set",
                         "style_set", "audio_mix_set", "add_caption", "export_final"] {
            #expect(names.contains(required), "missing pipeline tool \(required)")
        }

        for tool in tools {
            #expect(!tool.title.isEmpty, "\(tool.name) has no title")
            #expect(!tool.description.isEmpty, "\(tool.name) has no description")
            #expect(tool.inputSchema["type"]?.stringValue == "object", "\(tool.name) is not an object schema")
            #expect(tool.inputSchema["additionalProperties"]?.boolValue == false,
                    "\(tool.name) does not close additional properties")
            let properties = tool.inputSchema["properties"]?.objectValue ?? [:]
            let required = tool.inputSchema["required"]?.arrayValue ?? []
            for field in required {
                #expect(properties[field.stringValue ?? ""] != nil,
                        "\(tool.name) requires an undeclared field")
            }
        }
    }

    @Test func recordStartSchemaDeclaresAllCaptureOptions() async throws {
        let f = try makeFixture(); defer { cleanup(f.directory) }
        let tools = try await f.bridge.listTools()
        let schema = try #require(tools.first { $0.name == "record_start" }?.inputSchema)
        let properties = try #require(schema["properties"]?.objectValue)
        for key in ["target", "display_id", "bundle_id", "window_id", "region_x", "region_y",
                    "region_width", "region_height", "fps", "microphone", "system_audio",
                    "webcam", "privacy_auto_mask"] {
            #expect(properties[key] != nil, "record_start schema is missing \(key)")
        }
        let fps = try #require(properties["fps"])
        #expect(fps["type"]?.stringValue == "integer")
        #expect(fps["minimum"]?.doubleValue == 15)
    }

    // MARK: Round trips against the mock engine

    @Test func recordRoundTripReachesMockRuntime() async throws {
        let f = try makeFixture(); defer { cleanup(f.directory) }
        let started = try await f.bridge.callObject("record_start", arguments: [
            "target": .string("display"), "fps": .int(30), "privacy_auto_mask": .bool(false),
        ])
        #expect(started["recording"]?.boolValue == true)
        let captured = f.runtime.captured()
        #expect(captured.target?.kind == .display)
        #expect(captured.options?.fps == 30)
        #expect(captured.options?.privacyAutoMask == false)

        let paused = try await f.bridge.callObject("record_pause")
        #expect(paused["paused"]?.boolValue == true)
        #expect(f.runtime.captured().paused == true)

        let marker = try await f.bridge.callObject("record_marker", arguments: [
            "id": .string("step-1"), "label": .string("open app"),
        ])
        #expect(marker["marker_id"]?.stringValue == "step-1")
        #expect(f.runtime.captured().marks.count == 1)

        let resumed = try await f.bridge.callObject("record_resume")
        #expect(resumed["paused"]?.boolValue == false)
        #expect(f.runtime.captured().paused == false)
    }

    @Test func statusRoundTripReportsPermissionStateAndLinks() async throws {
        let f = try makeFixture(mic: false); defer { cleanup(f.directory) }
        let status = try await f.bridge.callObject("lumen_status")
        let permissions = try #require(status["permissions"]?.objectValue)
        #expect(permissions["screen_recording"]?.boolValue == true)
        #expect(permissions["microphone"]?.boolValue == false)
        let links = try #require(status["permission_links"]?.objectValue)
        #expect(links["screen_recording"]?.stringValue?.contains("ScreenCapture") == true)
    }

    @Test func dryRunNeverReachesTheRuntime() async throws {
        let f = try makeFixture(); defer { cleanup(f.directory) }
        let started = try await f.bridge.callObject("record_start", arguments: ["target": .string("display")])
        #expect(started["recording"]?.boolValue == true)
        let dry = try await f.bridge.call("record_pause", dryRun: true)
        #expect(dry.structured?["dry_run"]?.boolValue == true)
        #expect(dry.structured?["would_run_with"] != nil)
        #expect(f.runtime.captured().paused == false, "a dry run must not pause the capture")
    }

    // MARK: Typed error paths

    @Test func unknownToolIsAnInvalidParamsError() async throws {
        let f = try makeFixture(); defer { cleanup(f.directory) }
        do {
            _ = try await f.bridge.call("no_such_tool")
            Issue.record("an unknown tool must fail")
        } catch BridgeError.rpc(let code, _) {
            #expect(code == -32602)
        }
    }

    @Test func missingRequiredFieldIsAnInvalidParamsError() async throws {
        let f = try makeFixture(); defer { cleanup(f.directory) }
        do {
            _ = try await f.bridge.call("get_edit")
            Issue.record("get_edit without project_id must fail")
        } catch BridgeError.rpc(let code, let message) {
            #expect(code == -32602)
            #expect(message.contains("project_id"))
        }
    }

    @Test func missingPermissionReturnsATypedToolFailure() async throws {
        let f = try makeFixture(screen: false); defer { cleanup(f.directory) }
        do {
            _ = try await f.bridge.call("record_start", arguments: ["target": .string("display")])
            Issue.record("recording without Screen Recording permission must fail")
        } catch BridgeError.toolFailure(let code, _, let deepLink) {
            // The documented code preserves the human-readable phrase verbatim.
            #expect(code == "PERMISSION_SCREEN RECORDING")
            #expect(deepLink?.contains("ScreenCapture") == true)
        }
    }

    @Test func optionToolsDeclareClosedEnums() async throws {
        let f = try makeFixture(); defer { cleanup(f.directory) }
        let tools = try await f.bridge.listTools()
        let crop = try #require(tools.first { $0.name == "crop_set" }?.inputSchema)
        let cropProps = try #require(crop["properties"]?.objectValue)
        #expect(cropProps["uncrop"]?["enum"]?.arrayValue?.count == 3)
        let cursor = try #require(tools.first { $0.name == "cursor_set" }?.inputSchema)
        let cursorProps = try #require(cursor["properties"]?.objectValue)
        let effects = try #require(cursorProps["click_effect"]?["enum"]?.arrayValue)
        #expect(effects.count == 5)
        #expect(cursorProps["pack"]?["type"]?.stringValue == "string")
    }

    @Test func postProcessOnUnknownProjectIsATypedFailure() async throws {
        let f = try makeFixture(); defer { cleanup(f.directory) }
        do {
            _ = try await f.bridge.call("post_process", arguments: ["project_id": .string("missing")])
            Issue.record("post_process on an unknown project must fail")
        } catch BridgeError.toolFailure(let code, let hint, _) {
            #expect(code == "FAILED")
            #expect(hint.contains("project_open"))
        }
    }

    @Test func invalidRegionRejectsBeforeCapture() async throws {
        let f = try makeFixture(); defer { cleanup(f.directory) }
        do {
            _ = try await f.bridge.call("record_start", arguments: [
                "target": .string("region"), "region_x": .number(0.8), "region_width": .number(0.5),
            ])
            Issue.record("an out-of-bounds region must fail")
        } catch BridgeError.rpc(let code, let message) {
            // INVALID_ARGUMENTS is reported as a JSON-RPC parameter error.
            #expect(code == -32602)
            #expect(message.contains("Region"))
        }
        #expect(f.runtime.captured().target == nil, "invalid input must never start a capture")
    }
}
