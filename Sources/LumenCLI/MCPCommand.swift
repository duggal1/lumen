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

        // AGENT: read replies independently so long requests do not block subsequent requests.
        let finished = DispatchSemaphore(value: 0)
        let reader = Thread {
            defer { finished.signal() }
            while let reply = try? client.receive() {
                print(reply)
                fflush(stdout)
            }
        }
        reader.start()
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            do {
                try client.send(line)
            } catch {
                FileHandle.standardError.write(Data("lumen mcp: send failed: \(error)\n".utf8))
                break
            }
        }
        client.shutdownWrite()
        finished.wait()
        client.disconnect()
    }
}
