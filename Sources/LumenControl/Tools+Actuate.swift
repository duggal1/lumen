import Foundation
import LumenCore
import LumenProject
import LumenActuator

// MARK: - Actuation tools

public struct UISnapshotInput: ToolInput {
    public var bundleID: String = ""
    public var maxDepth: Int = 6
    public init() {}
}

public struct UIActInput: ToolInput {
    public var bundleID: String = ""
    public var actions: [DemoScript.Action] = []
    public init() {}
}

public struct UIWaitForInput: ToolInput {
    public var bundleID: String = ""
    public var role: String = ""
    public var title: String = ""
    public var identifier: String = ""
    public var timeoutS: Double = 8
    public init() {}
}

public struct RunScriptInput: ToolInput {
    public var script = DemoScript()
    /// physical (real mouse and keyboard) or virtual (accessibility only).
    public var mode: String = "physical"
    public var bundleID: String = ""
    public init() {}
}

public extension ToolRegistry {
    func registerActuateTools() {
        register(ToolDefinition<UISnapshotInput>(name: "ui_snapshot",
            description: "Reads the accessibility tree of an app (or the frontmost app): roles, titles, identifiers and normalized positions. Use it to find what to click.",
            capability: .actuate) { input, ctx in
                guard let node = AXSupport.snapshot(bundleID: input.bundleID.isEmpty ? nil : input.bundleID,
                                                   maxDepth: input.maxDepth) else {
                    throw ToolError.failed("No accessible application found.")
                }
                return .object(["tree": self.nodeJSON(node)])
            })

        register(ToolDefinition<UIActInput>(name: "ui_act",
            description: "Performs a batch of actions on an app: click, type, key, move, scroll, wait. Targets are resolved by role, title or identifier.",
            capability: .actuate, required: ["actions"]) { input, ctx in
                guard ctx.policy.bundleAllowed(input.bundleID, for: ctx.clientID) || input.bundleID.isEmpty else {
                    throw ToolError(code: "BUNDLE_NOT_ALLOWED",
                                    hint: "\(input.bundleID) is not on the allow-list. A human must grant it in Lumen > Settings > Agents.")
                }
                var script = DemoScript()
                script.app.bundleID = input.bundleID.isEmpty ? nil : input.bundleID
                script.steps = [DemoScript.Step(id: "ui_act", do: input.actions)]
                let runner = ScriptRunner(mode: .physical, sink: ctx.engine.markerSink())
                let markers = try await runner.run(script)
                return .object(["markers": .array(markers.map { self.markerJSON($0) })])
            })

        register(ToolDefinition<UIWaitForInput>(name: "ui_wait_for",
            description: "Waits until an accessibility element appears (role, title or identifier).",
            capability: .actuate) { input, ctx in
                let deadline = Date().addingTimeInterval(max(input.timeoutS, 0.1))
                while Date() < deadline {
                    let matches = AXSupport.find(TargetRef(role: input.role.isEmpty ? nil : input.role,
                                                           title: input.title.isEmpty ? nil : input.title,
                                                           identifier: input.identifier.isEmpty ? nil : input.identifier,
                                                           index: 0),
                                                bundleID: input.bundleID.isEmpty ? nil : input.bundleID)
                    if !matches.isEmpty { return .object(["found": .bool(true)]) }
                    try await Task.sleep(for: .milliseconds(120))
                }
                return .object(["found": .bool(false)])
            })

        register(ToolDefinition<RunScriptInput>(name: "run_script",
            description: "Runs a demo script against an app and records a marker per step. The script is the source of truth: launch, wait_for, click, type, key, move, scroll, sleep. Each step may carry narration in `say`.",
            capability: .actuate, required: ["script"]) { input, ctx in
                var script = input.script
                if !input.bundleID.isEmpty { script.app.bundleID = input.bundleID }
                let bundleID = script.app.bundleID ?? ""
                guard bundleID.isEmpty || ctx.policy.bundleAllowed(bundleID, for: ctx.clientID) else {
                    throw ToolError(code: "BUNDLE_NOT_ALLOWED",
                                    hint: "\(bundleID) is not on the allow-list. A human must grant it in Lumen > Settings > Agents.")
                }
                let mode: InputMode = input.mode == "virtual" ? .virtual : .physical
                let runner = ScriptRunner(mode: mode, sink: ctx.engine.markerSink())
                do {
                    let markers = try await runner.run(script)
                    return .object(["markers": .array(markers.map { self.markerJSON($0) })])
                } catch let e as ActuatorError {
                    throw ToolError.failed(e.message)
                }
            })
    }

    private func markerJSON(_ marker: CaptureMarker) -> JSONValue {
        .object(["id": .string(marker.id),
                 "label": marker.label.map { .string($0) } ?? .null,
                 "host_start": .number(marker.startHostSeconds),
                 "host_end": .number(marker.endHostSeconds)])
    }

    private func nodeJSON(_ node: AXNode) -> JSONValue {
        .object(["role": .string(node.role),
                 "title": node.title.map { .string($0) } ?? .null,
                 "value": node.value.map { .string($0) } ?? .null,
                 "identifier": node.identifier.map { .string($0) } ?? .null,
                 "enabled": .bool(node.enabled),
                 "focused": .bool(node.focused),
                 "x": node.x.map { .number($0) } ?? .null,
                 "y": node.y.map { .number($0) } ?? .null,
                 "width": node.width.map { .number($0) } ?? .null,
                 "height": node.height.map { .number($0) } ?? .null,
                 "children": .array(node.children.map { nodeJSON($0) })])
    }
}
