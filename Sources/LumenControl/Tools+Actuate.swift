import Foundation
import LumenCore
import LumenProject
import LumenActuator

// MARK: - Actuation tools

public struct UISnapshotInput: ToolInput {
    public var bundleID: String = ""
    public var maxDepth: Int = 6
    public init() {}

    enum CodingKeys: String, CodingKey {
    case bundleID = "bundle_id"
    case maxDepth = "max_depth"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
    self.maxDepth = try c.decodeIfPresent(Int.self, forKey: .maxDepth) ?? 6
    }
}

public struct UIActInput: ToolInput {
    public var bundleID: String = ""
    public var actions: [DemoScript.Action] = []
    public init() {}

    enum CodingKeys: String, CodingKey {
    case bundleID = "bundle_id"
    case actions
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
    self.actions = try c.decodeIfPresent([DemoScript.Action].self, forKey: .actions) ?? []
    }
}

public struct UIWaitForInput: ToolInput {
    public var bundleID: String = ""
    public var role: String = ""
    public var title: String = ""
    public var identifier: String = ""
    public var timeoutS: Double = 8
    public init() {}

    enum CodingKeys: String, CodingKey {
    case bundleID = "bundle_id"
    case role
    case title
    case identifier
    case timeoutS = "timeout_s"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
    self.role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
    self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    self.identifier = try c.decodeIfPresent(String.self, forKey: .identifier) ?? ""
    self.timeoutS = try c.decodeIfPresent(Double.self, forKey: .timeoutS) ?? 8
    }
}

public struct RunScriptInput: ToolInput {
    public var script = DemoScript()
    /// physical (real mouse and keyboard) or virtual (accessibility only).
    public var mode: String = "physical"
    public var bundleID: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey {
    case mode
    case bundleID = "bundle_id"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "physical"
    self.bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
    }
}

public extension ToolRegistry {
    func registerActuateTools() {
        register(ToolDefinition<UISnapshotInput>(name: "ui_snapshot",
            description: "Reads the accessibility tree of an app: roles, titles, identifiers, descriptions and positions. Use it to find what to click. Secure fields are redacted.",
            capability: .actuate, required: ["bundle_id"]) { input, ctx in
                // AGENT: reading any app's AX tree was unauthenticated and unchecked.
                try self.requireBundle(input.bundleID, ctx)
                guard let node = AXSupport.snapshot(bundleID: input.bundleID, maxDepth: input.maxDepth) else {
                    throw ToolError.failed("No accessible application found for \(input.bundleID).")
                }
                return .object(["tree": self.nodeJSON(node)])
            })

        register(ToolDefinition<UIActInput>(name: "ui_act",
            description: "Performs a batch of actions on an app: click, type, key, move, scroll, wait. Targets are resolved by role, title or identifier.",
            capability: .actuate, required: ["bundle_id", "actions"], mutating: true) { input, ctx in
                // AGENT: an empty bundle_id used to bypass the allow-list entirely.
                try self.requireBundle(input.bundleID, ctx)
                var script = DemoScript()
                script.app.bundleID = input.bundleID
                script.steps = [DemoScript.Step(id: "ui_act", do: input.actions)]
                let runner = ScriptRunner(mode: .physical, sink: ctx.engine.markerSink(),
                                          allowedBundles: [input.bundleID],
                                          writablePath: { try ctx.paths.writablePath($0, ext: PathGuard.imageExt) })
                let markers = try await runner.run(script)
                return .object(["markers": .array(markers.map { self.markerJSON($0) })])
            })

        register(ToolDefinition<UIWaitForInput>(name: "ui_wait_for",
            description: "Waits until an accessibility element appears (role, title or identifier).",
            capability: .actuate, required: ["bundle_id"]) { input, ctx in
                // AGENT: polling another app's AX tree needs the same allow-list check.
                try self.requireBundle(input.bundleID, ctx)
                let deadline = Date().addingTimeInterval(max(input.timeoutS, 0.1))
                while Date() < deadline {
                    let matches = AXSupport.find(TargetRef(role: input.role.isEmpty ? nil : input.role,
                                                           title: input.title.isEmpty ? nil : input.title,
                                                           identifier: input.identifier.isEmpty ? nil : input.identifier,
                                                           index: 0),
                                                bundleID: input.bundleID)
                    if !matches.isEmpty { return .object(["found": .bool(true)]) }
                    try await Task.sleep(for: .milliseconds(120))
                }
                return .object(["found": .bool(false)])
            })

        register(ToolDefinition<RunScriptInput>(name: "run_script",
            description: "Runs a demo script against an app and records a marker per step. The script is the source of truth: launch, wait_for, click, type, key, move, scroll, sleep. Each step may carry narration in `say`.",
            capability: .actuate, required: ["bundle_id", "script"], mutating: true) { input, ctx in
                var script = input.script
                if !input.bundleID.isEmpty { script.app.bundleID = input.bundleID }
                let bundleID = script.app.bundleID ?? ""
                // AGENT: require a declared target instead of accepting an empty one.
                try self.requireBundle(bundleID, ctx)
                // AGENT: a step could launch any app; validate every launch target up front.
                var allowed: Set<String> = [bundleID]
                for step in script.steps {
                    for action in step.do {
                        if case .launch(let launch) = action, let id = launch.bundleID {
                            try self.requireBundle(id, ctx)
                            allowed.insert(id)
                        }
                    }
                }
                let mode: InputMode = input.mode == "virtual" ? .virtual : .physical
                let runner = ScriptRunner(mode: mode, sink: ctx.engine.markerSink(),
                                          allowedBundles: allowed,
                                          writablePath: { try ctx.paths.writablePath($0, ext: PathGuard.imageExt) })
                do {
                    let markers = try await runner.run(script)
                    return .object(["markers": .array(markers.map { self.markerJSON($0) })])
                } catch let e as ActuatorError {
                    throw ToolError.failed(e.message)
                }
            })
    }

    /// AGENT: one bundle check for every actuate tool; empty means "everything", which is never OK.
    private func requireBundle(_ id: String, _ ctx: ToolContext) throws {
        guard !id.isEmpty else {
            throw ToolError.invalidArguments(
                "bundle_id is required for UI actions. Call list_apps to see the bundle ids.")
        }
        guard ctx.policy.bundleAllowed(id, for: ctx.clientID) else {
            throw ToolError(code: "BUNDLE_NOT_ALLOWED",
                            hint: "\(id) is not on the allow-list. A human must grant it in Lumen > Settings > Agents.")
        }
    }

    private func markerJSON(_ marker: CaptureMarker) -> JSONValue {
        .object(["id": .string(marker.id),
                 "label": marker.label.map { .string($0) } ?? .null,
                 "host_start": .number(marker.startHostSeconds),
                 "host_end": .number(marker.endHostSeconds)])
    }

    private func nodeJSON(_ node: AXNode) -> JSONValue {
        var payload: [String: JSONValue] = ["role": .string(node.role),
                 "title": node.title.map { .string($0) } ?? .null,
                 "value": node.value.map { .string($0) } ?? .null,
                 "identifier": node.identifier.map { .string($0) } ?? .null,
                 "enabled": .bool(node.enabled),
                 "focused": .bool(node.focused),
                 "x": node.x.map { .number($0) } ?? .null,
                 "y": node.y.map { .number($0) } ?? .null,
                 "width": node.width.map { .number($0) } ?? .null,
                 "height": node.height.map { .number($0) } ?? .null,
                 "children": .array(node.children.map { nodeJSON($0) })]
        // AGENT: icon-only buttons have no title or value; description is their only label.
        payload["description"] = node.descriptionText.map { .string($0) } ?? .null
        // AGENT: the screen rect lets an agent click a target instead of guessing from fractions.
        if let frame = node.frame {
            payload["frame"] = .object(["x": .number(frame.origin.x), "y": .number(frame.origin.y),
                                        "w": .number(frame.size.width), "h": .number(frame.size.height)])
        }
        if node.redacted { payload["redacted"] = .bool(true) }
        return .object(payload)
    }
}
