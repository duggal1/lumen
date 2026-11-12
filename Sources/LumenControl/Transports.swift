import Foundation

// MARK: - Unix domain socket (the daemon's private transport)

/// The daemon's private transport: a Unix domain socket with 0600
/// permissions. Only processes running as the same user can reach it, and no
/// token is needed because the filesystem is the authentication.
public final class UnixSocketServer: @unchecked Sendable {
    public let path: URL
    private let server: MCPServer
    private let queue = DispatchQueue(label: "lumen.agent.socket", qos: .userInitiated)
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var running = false

    public init(socketPath: URL, server: MCPServer) {
        self.path = socketPath
        self.server = server
    }

    public func start() throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolError.failed("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ToolError.failed("Socket path is too long: \(path.path)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dest in
                for (i, b) in pathBytes.enumerated() { dest[i] = CChar(bitPattern: b) }
                dest[pathBytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw ToolError.failed("Could not bind the agent socket at \(path.path)")
        }
        // 0600: the socket is private to the signed-in user.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        // A pid file lets the CLI tell a stale socket from a live daemon.
        try? String(String(ProcessInfo.processInfo.processIdentifier)).write(to: pidURL, atomically: true, encoding: .utf8)
        listener = fd
        running = true
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    public func stop() {
        running = false
        source?.cancel(); source = nil
        if listener >= 0 { close(listener); listener = -1 }
        try? FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: pidURL)
    }

    /// The pid of the daemon that owns this socket.
    public var pidURL: URL { path.deletingLastPathComponent().appendingPathComponent("agent.pid") }

    private func accept() {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        // One queue per connection: an idle client must never block another
        // client, and the replies on one connection stay in order.
        let connection = DispatchQueue(label: "lumen.agent.socket.conn", qos: .userInitiated)
        connection.async { [weak self] in self?.serve(client, on: connection) }
    }

    private func serve(_ fd: Int32, on connection: DispatchQueue) {
        var clientID = "socket"
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while running {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            buffer.append(chunk, count: n)
            while let index = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
                // The client introduces itself with the initialize request;
                // its name is what capability grants are checked against.
                if let name = MCPServer.clientName(from: line) { clientID = name }
                let requestClient = clientID
                // Handle it on this connection's own queue, in order. The
                // read loop waits for the reply so replies never overtake
                // each other, and no other connection is affected.
                let done = DispatchSemaphore(value: 0)
                Task {
                    if let reply = await self.server.handle(line, client: requestClient) {
                        var bytes = Array(reply.utf8)
                        bytes.append(0x0A)
                        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                    }
                    done.signal()
                }
                done.wait()
            }
        }
        close(fd)
    }
}

/// Client side of the Unix socket. Used by `lumen-cli mcp`.
public final class UnixSocketClient: @unchecked Sendable {
    public let path: URL
    private var fd: Int32 = -1
    private var buffer = Data()

    public init(socketPath: URL) { self.path = socketPath }

    public func connect(timeout: TimeInterval = 10) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ToolError.failed("Socket path is too long.")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dest in
                for (i, b) in bytes.enumerated() { dest[i] = CChar(bitPattern: b) }
                dest[bytes.count] = 0
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let client = socket(AF_UNIX, SOCK_STREAM, 0)
            guard client >= 0 else { throw ToolError.failed("socket() failed") }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if ok == 0 { fd = client; return }
            close(client)
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ToolError(code: "DAEMON_NOT_RUNNING",
                        hint: "The Lumen daemon is not running. Start it with: open -a Lumen --args --headless")
    }

    public func disconnect() { if fd >= 0 { Darwin.close(fd); fd = -1 } }

    /// Sends one line without waiting for a reply (a notification).
    public func send(_ line: String) throws {
        guard fd >= 0 else { throw ToolError.failed("Not connected.") }
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// Waits for the next line the daemon sends.
    public func receive(timeout: TimeInterval = 600) throws -> String {
        guard fd >= 0 else { throw ToolError.failed("Not connected.") }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = buffer.firstIndex(of: 0x0A) {
                let data = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                return String(decoding: data, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { throw ToolError.failed("The daemon closed the connection.") }
            buffer.append(chunk, count: n)
        }
        throw ToolError.failed("Timed out waiting for the daemon.")
    }

    /// Sends one line and waits for one line back.
    public func call(_ line: String, timeout: TimeInterval = 600) throws -> String {
        guard fd >= 0 else { throw ToolError.failed("Not connected.") }
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = buffer.firstIndex(of: 0x0A) {
                let data = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                return String(decoding: data, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { throw ToolError.failed("The daemon closed the connection.") }
            buffer.append(chunk, count: n)
        }
        throw ToolError.failed("Timed out waiting for the daemon.")
    }
}

// MARK: - stdio

/// Speaks MCP over stdin/stdout. The daemon can use it directly; the CLI uses
/// it as a thin proxy to the daemon socket so no capture ever runs in the
/// MCP client's process.
public final class StdioServer: @unchecked Sendable {
    private let server: MCPServer

    public init(server: MCPServer) { self.server = server }

    public func run() {
        let queue = DispatchQueue(label: "lumen.agent.stdio")
        queue.async {
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                Task {
                    guard let reply = await self.server.handle(trimmed, client: "stdio") else { return }
                    print(reply)
                    fflush(stdout)
                }
            }
        }
        dispatchMain()
    }
}

// MARK: - Optional HTTP transport (remote agents)

/// A minimal HTTP/1.1 transport for remote agents. It binds 127.0.0.1 only,
/// requires a bearer token with a constant-time compare, and rejects any
/// request whose Origin header is not local (that blocks DNS rebinding).
public final class HTTPServer: @unchecked Sendable {
    private let server: MCPServer
    private let policy: Policy
    private let port: UInt16
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "lumen.agent.http")

    public init(port: UInt16, server: MCPServer, policy: Policy) {
        self.port = port
        self.server = server
        self.policy = policy
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolError.failed("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw ToolError.failed("Could not bind 127.0.0.1:\(port)")
        }
        listener = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel(); source = nil
        if listener >= 0 { close(listener); listener = -1 }
    }

    private func accept() {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        queue.async { [weak self] in self?.serve(client) }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        // Read until the headers are complete.
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            buffer.append(chunk, count: n)
        }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return }
        let path = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        var body = Data(buffer[headerEnd.upperBound...])
        while body.count < contentLength {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            body.append(chunk, count: n)
        }
        // 1. Authorization: a bearer token, compared in constant time.
        let auth = headers["authorization"] ?? ""
        let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : ""
        guard Policy.constantTimeEquals(token, policy.bearerToken), !token.isEmpty else {
            respond(fd, status: 401, body: "{\"error\":\"unauthorized\"}")
            return
        }
        // 2. Origin: local only. This is what stops DNS rebinding.
        if let origin = headers["origin"] {
            let lowered = origin.lowercased()
            let local = lowered.hasPrefix("http://127.0.0.1") || lowered.hasPrefix("http://localhost")
                || lowered.hasPrefix("http://[::1]")
            if !local {
                respond(fd, status: 403, body: "{\"error\":\"origin_not_allowed\"}")
                return
            }
        }
        guard path.contains("/mcp") || path == "/" else {
            respond(fd, status: 404, body: "{\"error\":\"not_found\"}")
            return
        }
        guard let line = String(data: body, encoding: .utf8), !line.isEmpty else {
            respond(fd, status: 400, body: "{\"error\":\"empty_body\"}")
            return
        }
        Task {
            let reply = await server.handle(line, client: "http") ?? "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{}}"
            respond(fd, status: 200, body: reply)
        }
    }

    private func respond(_ fd: Int32, status: Int, body: String) {
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Forbidden")
        let data = Data(body.utf8)
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(data)
        _ = out.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}
