import Foundation
import ArgumentParser
import LumenControl

/// Speaks MCP over stdin/stdout by proxying to the Lumen daemon.
///
/// The shim does NO capture and no TCC-sensitive work: the daemon is the
/// signed Lumen app, so Screen Recording, Accessibility and Input Monitoring
/// are attributed to Lumen and never to the MCP client's process.
struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp",
        abstract: "Speak MCP over stdio. Starts the Lumen daemon if it is not running.")

    @Option(name: .long, help: "Path to the daemon socket.")
    var socket: String = ""

    @Flag(name: .long, help: "Do not start the daemon; fail if it is not running.")
    var noLaunch = false

    func run() throws {
        let path = socket.isEmpty ? LumenDaemon.defaultSocketPath()
                                  : URL(fileURLWithPath: (socket as NSString).expandingTildeInPath)
        if !noLaunch {
            try DaemonLauncher.ensureRunning(socketPath: path)
        }
        let client = UnixSocketClient(socketPath: path)
        try client.connect()
        FileHandle.standardError.write(Data("lumen mcp: connected to the Lumen daemon\n".utf8))

        // stdin is read on a worker thread and handed over one line at a
        // time; the socket conversation stays on this thread so replies
        // always match their request.
        let inbox = Inbox()
        let reader = Thread {
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                inbox.put(trimmed)
            }
            inbox.finish()
        }
        reader.start()

        while let line = inbox.next() {
            do {
                try client.send(line)
            } catch {
                FileHandle.standardError.write(Data("lumen mcp: send failed: \(error)\n".utf8))
                break
            }
            // A notification has no reply; a request does.
            guard needsReply(line) else { continue }
            do {
                let reply = try client.receive()
                print(reply)
                fflush(stdout)
            } catch {
                FileHandle.standardError.write(Data("lumen mcp: receive failed: \(error)\n".utf8))
                break
            }
        }
        client.disconnect()
    }

    /// True when the request carries an id, so a reply is expected.
    private func needsReply(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["id"] != nil
    }
}

/// A tiny line queue between the stdin reader and the socket loop.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var done = false
    private let semaphore = DispatchSemaphore(value: 0)

    func put(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
        semaphore.signal()
    }

    func finish() {
        lock.lock(); done = true; lock.unlock()
        semaphore.signal()
    }

    func next() -> String? {
        while true {
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                return line
            }
            let finished = done
            lock.unlock()
            if finished { return nil }
            semaphore.wait()
        }
    }
}
