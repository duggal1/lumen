import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import LumenCore
import LumenProject
import LumenCapture

// MARK: - Status tools

public struct StatusInput: ToolInput {
    public init() {}
}

public struct ListAppsInput: ToolInput {
    public init() {}
}

public struct ListWindowsInput: ToolInput {
    public var bundleID: String = ""
    public var includeOffscreen: Bool = false
    public init() {}

    enum CodingKeys: String, CodingKey {
    case bundleID = "bundle_id"
    case includeOffscreen = "include_offscreen"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
    self.bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
    self.includeOffscreen = try c.decodeIfPresent(Bool.self, forKey: .includeOffscreen) ?? false
    }
}

public struct ListDisplaysInput: ToolInput {
    public init() {}
}

public extension ToolRegistry {
    func registerStatusTools() {
        register(ToolDefinition<StatusInput>(name: "lumen_status",
            description: "Lumen's current state: permissions, phase, library size and version. Call this first; it reports every permission the agent needs and the System Settings pane to open when one is missing.",
            capability: .read) { _, ctx in
                let status = await ctx.engine.runtime.runtimeStatus()
                return .object([
                    "phase": .string(status.phase),
                    "paused": .bool(status.paused),
                    "recording": .bool(status.recording),
                    "permissions": .object([
                        "screen_recording": .bool(status.permissions.screenRecording),
                        "accessibility": .bool(status.permissions.accessibility),
                        "input_monitoring": .bool(status.permissions.inputMonitoring),
                        "microphone": .bool(status.permissions.microphone),
                        "camera": .bool(status.permissions.camera),
                    ]),
                    "permission_links": .object([
                        "screen_recording": .string("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
                        "accessibility": .string("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
                        "input_monitoring": .string("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"),
                    ]),
                    "library": .string(status.libraryPath),
                    "projects": .int(status.projects),
                    "active_project": status.activeProjectPath.map { .string($0) } ?? .null,
                    "version": .string(status.version),
                ])
            })

        register(ToolDefinition<ListAppsInput>(name: "list_apps",
            description: "Running macOS applications with their bundle identifiers. Use it to find the bundle id of the app you want to drive.",
            capability: .read) { _, _ in
                var apps: [JSONValue] = []
                for app in NSWorkspace.shared.runningApplications where !app.isTerminated && app.bundleIdentifier != nil {
                    apps.append(.object([
                        "bundle_id": .string(app.bundleIdentifier ?? ""),
                        "name": .string(app.localizedName ?? ""),
                        "pid": .int(Int(app.processIdentifier)),
                        "frontmost": .bool(app.isActive),
                    ]))
                }
                return .object(["apps": .array(apps)])
            })

        register(ToolDefinition<ListWindowsInput>(name: "list_windows",
            description: "On-screen windows with their ids, owning app and title. Use it to pick the window to record or to act on.",
            capability: .read) { input, _ in
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [NSDictionary] ?? []
                // The window list has no bundle id, so it is resolved from the
                // owner process.
                var bundlesByPID: [Int32: String] = [:]
                for app in NSWorkspace.shared.runningApplications {
                    if let identifier = app.bundleIdentifier {
                        bundlesByPID[Int32(app.processIdentifier)] = identifier
                    }
                }
                var rows: [JSONValue] = []
                for entry in list {
                    let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
                    let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
                    let bundle = bundlesByPID[pid] ?? ""
                    let title = entry[kCGWindowName as String] as? String ?? ""
                    let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
                    let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
                    if !input.includeOffscreen && layer != 0 { continue }
                    if !input.bundleID.isEmpty && bundle != input.bundleID { continue }
                    guard number != 0 else { continue }
                    rows.append(.object(["window_id": .int(Int(number)), "app": .string(owner),
                                        "bundle_id": .string(bundle), "title": .string(title),
                                        "layer": .int(layer)]))
                }
                return .object(["windows": .array(rows)])
            })

        register(ToolDefinition<ScreenLookInput>(name: "screen_look",
            description: "Captures the currently visible window for an approved app as an image. Requires that app's bundle id to be allow-listed.",
            capability: .actuate, required: [], outputSchema: ToolSchemas.outputSchema(for: "screen_look")) { input, ctx in
                let bundleID = input.bundleID.isEmpty
                    ? (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
                    : input.bundleID
                guard !bundleID.isEmpty else {
                    throw ToolError.invalidArguments("bundle_id is required unless an approved app is frontmost.")
                }
                guard ctx.policy.bundleAllowed(bundleID, for: ctx.clientID) else {
                    throw ToolError(code: "BUNDLE_NOT_ALLOWED",
                                    hint: "Approve this app in Lumen Settings > Agents before capturing its window.")
                }
                guard (await ctx.engine.runtime.runtimeStatus()).permissions.screenRecording else {
                    throw ToolError.permission("screen recording", pane: "ScreenCapture")
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: {
                    $0.owningApplication?.bundleIdentifier == bundleID && $0.frame.width > 0 && $0.frame.height > 0
                }) else {
                    throw ToolError(code: "WINDOW_NOT_FOUND", hint: "Bring an on-screen window for \(bundleID) forward, then retry.")
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                configuration.width = max(Int(window.frame.width.rounded()), 1)
                configuration.height = max(Int(window.frame.height.rounded()), 1)
                configuration.showsCursor = true
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                let bitmap = NSBitmapImageRep(cgImage: image)
                guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                    throw ToolError.failed("The app window could not be encoded as JPEG.")
                }
                // AGENT: return pixels through MCP image content instead of a text-encoded screenshot.
                return .object(["image_base64": .string(data.base64EncodedString()), "mime_type": .string("image/jpeg"),
                                "bundle_id": .string(bundleID), "width": .int(image.width), "height": .int(image.height)])
            })

        register(ToolDefinition<ListDisplaysInput>(name: "list_displays",
            description: "Connected displays with their ids, names and bounds. Use it to pick a display to record.",
            capability: .read) { _, _ in
                var rows: [JSONValue] = []
                for (id, name) in NSScreen.screens.compactMap({ s -> (CGDirectDisplayID, String)? in
                    guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
                    return (n, s.localizedName)
                }) {
                    let bounds = CGDisplayBounds(id)
                    rows.append(.object(["display_id": .int(Int(id)), "name": .string(name),
                                         "x": .number(bounds.origin.x), "y": .number(bounds.origin.y),
                                         "width": .number(bounds.size.width), "height": .number(bounds.size.height)]))
                }
                return .object(["displays": .array(rows)])
            })
    }
}

public struct ScreenLookInput: ToolInput {
    public var bundleID: String = ""
    public init() {}

    enum CodingKeys: String, CodingKey { case bundleID = "bundle_id" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID) ?? ""
    }
}
