import Foundation
import AppKit
import LumenCore

/// Assembles the agent layer: registry, policy, audit, jobs, engine, MCP
/// server and the private socket.
public final class LumenDaemon: @unchecked Sendable {
    public let registry: ToolRegistry
    public let policy: Policy
    public let audit: AuditLog
    public let jobs: JobManager
    public let engine: Engine
    public let server: MCPServer
    public let socket: UnixSocketServer
    public var http: HTTPServer?

    public init(runtime: LumenRuntime, socketPath: URL? = nil, httpPort: UInt16? = nil) {
        registry = ToolRegistry()
        policy = Policy()
        audit = AuditLog()
        jobs = JobManager()
        engine = Engine(runtime: runtime, jobs: jobs, policy: policy)
        server = MCPServer(registry: registry, engine: engine, policy: policy, jobs: jobs, audit: audit)
        socket = UnixSocketServer(socketPath: socketPath ?? LumenDaemon.defaultSocketPath(), server: server)
        if let httpPort { http = HTTPServer(port: httpPort, server: server, policy: policy) }
        registerAllTools(in: registry)
    }

    /// Where the daemon listens. 0600, inside the user's Application Support.
    public static func defaultSocketPath() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Lumen", isDirectory: true).appendingPathComponent("agent.sock")
    }

    public func start() throws {
        try socket.start()
        try http?.start()
    }

    public func stop() {
        socket.stop()
        http?.stop()
    }
}

/// Registers the whole catalog.
public func registerAllTools(in registry: ToolRegistry) {
    registry.registerStatusTools()
    registry.registerRecordTools()
    registry.registerProjectTools()
    registry.registerMediaTools()
    registry.registerActuateTools()
}

/// Starts the daemon on demand from the CLI.
public enum DaemonLauncher {
    /// Makes sure a daemon is listening, starting the app in headless mode
    /// when it is not. Returns once the socket answers.
    public static func ensureRunning(socketPath: URL = LumenDaemon.defaultSocketPath(),
                                    timeout: TimeInterval = 25) throws {
        if canConnect(socketPath) { return }
        // A socket file with no daemon behind it is stale: remove it so the
        // new daemon can bind the path.
        if let pid = liveDaemonPID(socketPath: socketPath) {
            throw ToolError(code: "DAEMON_UNREACHABLE",
                            hint: "A Lumen daemon is running (pid \(pid)) but its socket at \(socketPath.path) is gone. Quit Lumen and try again.")
        }
        try? FileManager.default.removeItem(at: socketPath)
        let app = locateApp()
        guard let app else {
            throw ToolError(code: "DAEMON_NOT_FOUND",
                            hint: "Lumen.app was not found. Install it, or run the daemon from the app bundle.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--headless"]
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if canConnect(socketPath) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ToolError(code: "DAEMON_NOT_RUNNING",
                        hint: "The Lumen daemon did not start in time. Open Lumen once and check its permissions.")
    }

    /// The pid of a daemon that is still alive, if any.
    static func liveDaemonPID(socketPath: URL) -> Int32? {
        let pidURL = socketPath.deletingLastPathComponent().appendingPathComponent("agent.pid")
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return kill(pid, 0) == 0 ? pid : nil
    }

    static func canConnect(_ path: URL) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dest in
                for (i, b) in bytes.enumerated() { dest[i] = CChar(bitPattern: b) }
                dest[bytes.count] = 0
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return ok == 0
    }

    /// The Lumen.app that contains this CLI, or the installed one.
    static func locateApp() -> URL? {
        var candidates: [URL] = []
        let mainBundle = Bundle.main.bundleURL
        if mainBundle.pathExtension == "app" { candidates.append(mainBundle) }
        candidates.append(URL(fileURLWithPath: "/Applications/Lumen.app"))
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // .../Lumen.app/Contents/MacOS/lumen-cli -> .../Lumen.app
        if executable.path.contains("/Contents/MacOS/") {
            let app = URL(fileURLWithPath: executable.path)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            candidates.insert(app, at: 0)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
