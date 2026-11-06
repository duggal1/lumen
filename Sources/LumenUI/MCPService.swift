import Foundation
import Metal
import LumenCore
import LumenProject
import LumenRender
import LumenExport

// MARK: - Preferences

public enum MCPPreferences {
    public static let enabledKey = "LumenMCPEnabled"
    public static let portKey = "LumenMCPPort"
    public static let defaultPort: UInt16 = 8765
    public static func port(defaults: UserDefaults = .standard) -> UInt16 {
        let raw = defaults.integer(forKey: portKey)
        return (1...65535).contains(raw) ? UInt16(raw) : defaultPort
    }
}

public struct MCPStatus: Codable, Sendable, Equatable {
    public var phase: String
    public var paused: Bool
    public var recording: Bool
    public var projects: Int
    public init(phase: String, paused: Bool, recording: Bool, projects: Int) {
        self.phase = phase; self.paused = paused; self.recording = recording; self.projects = projects
    }
}

public enum MCPError: LocalizedError, Equatable {
    case noDevice, invalidPreset(String), unknownTool(String), socket(String), notRecording, noOutput
    public var errorDescription: String? {
        switch self {
        case .noDevice: "No Metal device is available."
        case .invalidPreset(let name): "Unknown export preset \(name)."
        case .unknownTool(let name): "Unknown tool \(name)."
        case .socket(let reason): "MCP server could not start: \(reason)."
        case .notRecording: "Lumen is not recording."
        case .noOutput: "The export produced no file."
        }
    }
}

@MainActor public protocol MCPActions: AnyObject {
    var mcpStatus: MCPStatus { get }
    func mcpStart() async throws
    func mcpStop() async throws
    func mcpPauseToggle() async throws
    func mcpOpen(path: String) throws
    func mcpExport(project: String, preset: String, output: String) async throws -> String
}

// MARK: - JSON-RPC router

/// Minimal MCP surface (protocol 2025-06-18, tools capability). Pure request ->
/// response so it can be exercised without opening a socket.
@MainActor public final class MCPRouter {
    public static let protocolVersion = "2025-06-18"
    private let actions: any MCPActions

    public init(actions: any MCPActions) { self.actions = actions }

    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = request["method"] as? String else {
            return error(id: nil, code: -32700, message: "Parse error")
        }
        // Notifications carry no id and must not be answered.
        let id = request["id"]
        if id == nil { return nil }
        switch method {
        case "initialize":
            return result(id: id, [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "lumen", "version": "1.0.0"],
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": tools])
        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return error(id: id, code: -32602, message: "Missing tool name")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await call(name, args)
                return result(id: id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                return result(id: id, ["content": [["type": "text", "text": message]], "isError": true])
            }
        default:
            return error(id: id, code: -32601, message: "Unknown method \(method)")
        }
    }

    private func call(_ name: String, _ args: [String: Any]) async throws -> String {
        switch name {
        case "lumen_status":
            return json(actions.mcpStatus)
        case "lumen_start_recording":
            try await actions.mcpStart()
            return "Recording started."
        case "lumen_stop_recording":
            try await actions.mcpStop()
            return "Recording stopped."
        case "lumen_toggle_pause":
            try await actions.mcpPauseToggle()
            return actions.mcpStatus.paused ? "Paused." : "Resumed."
        case "lumen_open_project":
            guard let path = args["path"] as? String, !path.isEmpty else { throw MCPError.noOutput }
            try actions.mcpOpen(path: path)
            return "Opened \(path)."
        case "lumen_export":
            guard let project = args["project"] as? String, !project.isEmpty else { throw MCPError.noOutput }
            guard let output = args["output"] as? String, !output.isEmpty else { throw MCPError.noOutput }
            let preset = args["preset"] as? String ?? "1080p60-h264"
            return try await actions.mcpExport(project: project, preset: preset, output: output)
        default:
            throw MCPError.unknownTool(name)
        }
    }

    private var tools: [[String: Any]] {
        [
            tool("lumen_status", "Current phase, pause state and library size.", [:]),
            tool("lumen_start_recording", "Start a recording with the current capture settings.", [:]),
            tool("lumen_stop_recording", "Stop the active recording and save it.", [:]),
            tool("lumen_toggle_pause", "Pause or resume the active recording.", [:]),
            tool("lumen_open_project", "Open a .lumen project in the editor.",
                 ["path": ["type": "string", "description": "Absolute .lumen bundle path"]]),
            tool("lumen_export", "Render a .lumen project headlessly.",
                 ["project": ["type": "string"], "output": ["type": "string"],
                  "preset": ["type": "string", "description": "e.g. 1080p60-h264"]]),
        ]
    }

    private func tool(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties,
                            "required": properties.keys.sorted()],
        ]
    }

    private func result(id: Any?, _ value: [String: Any]) -> String? {
        jsonObject(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value])
    }

    private func error(id: Any?, code: Int, message: String) -> String? {
        jsonObject(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func jsonObject(_ value: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Localhost server

/// Newline-delimited JSON-RPC over TCP on 127.0.0.1 only. One tool call at a
/// time per connection; the listener is opt-in from Settings.
public final class MCPTCPServer: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (String) async -> String?

    private let port: UInt16
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "lumen.mcp.accept")
    private var listenerFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var clientFDs: Set<Int32> = []

    public init(port: UInt16, handler: @escaping Handler) {
        self.port = port; self.handler = handler
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPError.socket("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd); throw MCPError.socket("bind/listen failed on port \(port)")
        }
        listenerFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel(); source = nil
        lock.lock()
        let clients = clientFDs
        clientFDs.removeAll()
        lock.unlock()
        for fd in clients { close(fd) }
        if listenerFD >= 0 { close(listenerFD); listenerFD = -1 }
    }

    private func accept() {
        let client = Darwin.accept(listenerFD, nil, nil)
        guard client >= 0 else { return }
        lock.lock(); clientFDs.insert(client); lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.read(client)
        }
    }

    private func read(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var pending = Data()
        while true {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { break }
            pending.append(buffer, count: n)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[..<newline]
                pending.removeSubrange(pending.startIndex..<pending.index(after: newline))
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                let handler = self.handler
                let fd = fd
                Task { @MainActor in
                    guard let reply = await handler(line) else { return }
                    var bytes = Array(reply.utf8); bytes.append(0x0A)
                    _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
                }
            }
        }
        lock.lock(); clientFDs.remove(fd); lock.unlock()
        close(fd)
    }
}

// MARK: - Host

/// Owns the optional server so AppModel doesn't grow another lifecycle field.
@MainActor public final class MCPHost {
    public static let shared = MCPHost()
    private var server: MCPTCPServer?
    public private(set) var runningPort: UInt16?

    public func configure(enabled: Bool, port: UInt16 = MCPPreferences.port(), actions: any MCPActions) {
        server?.stop(); server = nil; runningPort = nil
        guard enabled else { return }
        let router = MCPRouter(actions: actions)
        let server = MCPTCPServer(port: port) { line in
            await router.handle(line)
        }
        do {
            try server.start()
            self.server = server
            runningPort = port
        } catch {
            self.server = nil
        }
    }
}

// MARK: - AppModel conformance

extension AppModel: MCPActions {
    public var mcpStatus: MCPStatus {
        let name: String = switch phase {
        case .idle: "idle"
        case .preparing: "preparing"
        case .countdown: "countdown"
        case .recording: "recording"
        case .finishing: "finishing"
        }
        return MCPStatus(phase: name, paused: paused, recording: phase == .recording, projects: projects.count)
    }

    public func mcpStart() async throws {
        await start()
        guard phase == .recording else { throw MCPError.notRecording }
    }

    public func mcpStop() async throws {
        guard phase == .recording else { throw MCPError.notRecording }
        await stop()
    }

    public func mcpPauseToggle() async throws {
        guard phase == .recording else { throw MCPError.notRecording }
        togglePause()
    }

    public func mcpOpen(path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MCPError.noOutput }
        onFinished?(url)
    }

    public func mcpExport(project: String, preset: String, output: String) async throws -> String {
        guard let device = MTLCreateSystemDefaultDevice() else { throw MCPError.noDevice }
        guard let p = ExportPresets.parse(preset) else { throw MCPError.invalidPreset(preset) }
        let bundle = ProjectBundle(url: URL(fileURLWithPath: project))
        let (session, source) = try await ProjectSession.open(bundle, device: device)
        let timeline = session.derive(source, revision: 1)
        let url = URL(fileURLWithPath: output)
        try await Exporter.run(session: session, timeline: timeline, preset: p, to: url, progress: { _ in })
        guard FileManager.default.fileExists(atPath: url.path) else { throw MCPError.noOutput }
        return url.path
    }
}
