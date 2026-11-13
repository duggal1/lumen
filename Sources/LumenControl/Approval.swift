import Foundation
import AppKit

/// Asks the human, from inside the signed Lumen app, before a client gets a
/// capability it was not granted.
///
/// AGENT: the MCP client used to be the only thing deciding what it could do;
/// approval now comes from a native alert the client cannot answer.
public actor ApprovalCenter {
    public enum Decision: Sendable {
        case once, always, deny
    }

    /// How long a human has to answer before the request is refused.
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    public func request(client: String, capability: Capability) async -> Decision {
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let alert = NSAlert()
                let name = (client as NSString).lastPathComponent
                alert.messageText = "“\(name)” wants to \(capability.humanVerb) with Lumen"
                alert.informativeText = client
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Allow once")
                alert.addButton(withTitle: "Always allow")
                alert.addButton(withTitle: "Deny")
                // A headless daemon has no window, so abort the modal instead of hanging.
                let timer = DispatchWorkItem { NSApp.abortModal() }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
                let response = alert.runModal()
                timer.cancel()
                let decision: Decision
                switch response {
                case .alertFirstButtonReturn: decision = .once
                case .alertSecondButtonReturn: decision = .always
                default: decision = .deny
                }
                continuation.resume(returning: decision)
            }
        }
    }
}

extension Capability {
    /// What the human is being asked to allow, in their words.
    public var humanVerb: String {
        switch self {
        case .read: return "read your projects"
        case .record: return "record your screen"
        case .actuate: return "control other apps"
        case .edit: return "edit your projects"
        case .export: return "export videos"
        case .network: return "use the network"
        }
    }
}
