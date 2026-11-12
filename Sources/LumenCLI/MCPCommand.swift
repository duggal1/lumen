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

        // stdin -> daemon
        let writer = Thread {
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                do {
                    try client.send(trimmed)
                } catch {
                    return
                }
            }
        }
        // daemon -> stdout
        let reader = Thread {
            while true {
                do {
                    let reply = try client.receive()
                    print(reply)
                    fflush(stdout)
                } catch {
                    return
                }
            }
        }
        writer.start()
        reader.start()
        // The reader owns the process: it exits when the daemon closes.
        while reader.isExecuting { Thread.sleep(forTimeInterval: 0.2) }
    }
}
