import Foundation
import Security

// MARK: - Peer identity

/// Who is on the other end of a connection, as the kernel reports it.
///
/// AGENT: a client used to name itself in `initialize`, so any local process
/// could claim to be an approved one. Identity now comes from the peer.
public struct PeerIdentity: Sendable {
    public let pid: pid_t
    public let path: String
    public let signingID: String?

    /// What grants are keyed on: the code signature, or the executable path.
    public var key: String { signingID ?? path }

    public init?(fd: Int32) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        // Same user only: a different user has no business on this socket.
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return nil }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        // SOL_LOCAL = 0 and LOCAL_PEERPID = 0x002 on macOS; Swift does not import them.
        guard getsockopt(fd, 0, 0x002, &pid, &length) == 0, pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        var signingID: String?
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        if SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code {
            var staticCode: SecStaticCode?
            var information: CFDictionary?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
               SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                             &information) == errSecSuccess,
               let information = information as? [String: Any] {
                signingID = information[kSecCodeInfoIdentifier as String] as? String
            }
        }
        self.pid = pid
        self.path = String(cString: buffer)
        self.signingID = signingID
    }
}

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
    /// AGENT: held for the process lifetime so a second daemon cannot steal the socket.
    private var lockFD: Int32 = -1

    public init(socketPath: URL, server: MCPServer) {
        self.path = socketPath
        self.server = server
    }

    public func start() throws {
        let directory = path.deletingLastPathComponent()
        // AGENT: the socket lives in a 0700 directory so it is private before bind.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // AGENT: never unlink a live daemon's socket; the lock file is the arbiter.
        let lockPath = directory.appendingPathComponent("agent.lock").path
        let lock = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock) }
            throw ToolError(code: "DAEMON_ALREADY_RUNNING",
                            hint: "Another Lumen daemon owns the agent socket.")
        }
        lockFD = lock
        // AGENT: the socket is born 0600 instead of being chmod'ed after bind.
        let oldMask = umask(0o177)
        defer { umask(oldMask) }
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
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        try? FileManager.default.removeItem(at: path)
        try? FileManager.default.removeItem(at: pidURL)
    }

    /// The pid of the daemon that owns this socket.
    public var pidURL: URL { path.deletingLastPathComponent().appendingPathComponent("agent.pid") }

    private func accept() {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        // AGENT: a client that vanishes mid-reply must not raise SIGPIPE and kill the daemon.
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // AGENT: grants are keyed on who the kernel says is calling, not on a
        // name the client typed into its initialize request.
        guard let peer = PeerIdentity(fd: client) else {
            close(client)
            return
        }
        // One queue per connection: an idle client must never block another
        // client, and the replies on one connection stay in order.
        let connection = DispatchQueue(label: "lumen.agent.socket.conn", qos: .userInitiated)
        connection.async { [weak self] in self?.serve(client, peer: peer, on: connection) }
    }

    private func serve(_ fd: Int32, peer: PeerIdentity, on connection: DispatchQueue) {
        let clientID = peer.key
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while running {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            buffer.append(chunk, count: n)
            // AGENT: cap the per-connection buffer so one client cannot exhaust memory.
            guard buffer.count < 16 << 20 else { break }
            while let index = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
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
