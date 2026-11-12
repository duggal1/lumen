import Foundation
import ArgumentParser
import LumenControl
import LumenCore

/// The human's side of the agent layer: see what a client may do, grant or
/// revoke a capability, and read the shared token.
struct Agent: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "agent",
        abstract: "Manage agent permissions: capabilities, the app allow-list and shared folders.",
        subcommands: [AgentStatus.self, AgentGrant.self, AgentRevoke.self, AgentToken.self, AgentProbe.self])

    struct AgentStatus: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status",
            abstract: "Show the capability grants per client.")
        @Option(name: .long, help: "Client id (default: stdio).")
        var client: String = "stdio"
        func run() throws {
            let policy = Policy()
            print("Policy file: \(policy.fileURL.path)")
            print("Client \(client):")
            for capability in Capability.allCases {
                let allowed = policy.allowed(capability, for: client)
                print("  \(allowed ? "granted" : "denied " ) \(capability.rawValue)")
            }
            let paths = policy.allowedPaths(for: client)
            print("  folders: \(paths.isEmpty ? "(library only)" : paths.joined(separator: ", "))")
            let tokenPath = AgentCredentials.tokenURL.path
            print("Token file: \(tokenPath) (mode 0600)")
        }
    }

    struct AgentGrant: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "grant",
            abstract: "Grant a capability, an app bundle id or a folder to a client.")
        @Option(name: .long, help: "Client id (default: stdio).")
        var client: String = "stdio"
        @Option(name: .long, help: "Capability to grant: read, record, actuate, edit, export, network.")
        var capability: String?
        @Option(name: .long, help: "Bundle id this client may act on, e.g. com.apple.TextEdit.")
        var bundleId: String?
        @Option(name: .long, help: "Folder this client may read and write.")
        var path: String?
        func run() throws {
            let policy = Policy()
            var capabilities: [String]? = nil
            if let capability {
                guard Capability(rawValue: capability) != nil else {
                    throw ValidationError("Unknown capability \(capability). Use: "
                        + Capability.allCases.map(\.rawValue).joined(separator: ", "))
                }
                var current = policy.grantedCapabilities(for: client)
                if !current.contains(capability) { current.append(capability) }
                capabilities = current
            }
            var bundles: [String]? = nil
            if let bundleId {
                var current = policy.grantedBundleIDs(for: client)
                if !current.contains(bundleId) { current.append(bundleId) }
                bundles = current
            }
            var paths: [String]? = nil
            if let path {
                var current = policy.grantedPaths(for: client)
                let expanded = (path as NSString).expandingTildeInPath
                if !current.contains(expanded) { current.append(expanded) }
                paths = current
            }
            policy.grant(client: client, capabilities: capabilities, bundleIDs: bundles, paths: paths)
            print("Updated grants for \(client).")
        }
    }

    struct AgentRevoke: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "revoke",
            abstract: "Revoke a capability from a client.")
        @Option(name: .long, help: "Client id (default: stdio).")
        var client: String = "stdio"
        @Option(name: .long, help: "Capability to revoke.")
        var capability: String
        func run() throws {
            let policy = Policy()
            policy.revoke(client: client, capabilities: [capability])
            print("Revoked \(capability) for \(client).")
        }
    }

    struct AgentToken: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "token",
            abstract: "Print the shared agent token (for the HTTP transport).")
        func run() throws {
            print(AgentCredentials.token())
        }
    }
}

/// Debug helper: connect to the daemon, send one request, print the reply.
struct AgentProbe: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "probe",
        abstract: "Send one JSON-RPC line to the daemon and print the reply.")
    @Argument var request: String = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
    func run() throws {
        let client = UnixSocketClient(socketPath: LumenDaemon.defaultSocketPath())
        try client.connect()
        try client.send(request)
        print(try client.receive())
    }
}
