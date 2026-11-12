import Foundation
import Security

/// The agent's shared secret.
///
/// One file, 0600, owned by the signed-in user. The daemon's unix socket is
/// already private to that user; this token is what protects the optional
/// HTTP transport and the in-app MCP server, which are reachable from other
/// processes on the machine.
public enum AgentCredentials {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    public static var tokenURL: URL {
        directory.appendingPathComponent("Lumen", isDirectory: true).appendingPathComponent("agent-token")
    }

    /// The token, created on first use.
    public static func token() -> String {
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let value = Data(bytes).base64EncodedString()
        try? FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(value.utf8).write(to: tokenURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return value
    }

    /// Compares two secrets without leaking their length through timing.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        let n = max(x.count, y.count)
        for i in 0..<n {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            diff |= Int(xi ^ yi)
        }
        return diff == 0
    }

    /// True when an Authorization header carries the right bearer token.
    public static func authorizes(header: String?) -> Bool {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return false }
        let presented = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        guard !presented.isEmpty else { return false }
        return constantTimeEquals(presented, token())
    }

    /// True when an Origin header is local. Non-local origins are rejected so
    /// a browser cannot be tricked into calling the agent API (DNS rebinding).
    public static func isLocalOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        let lowered = origin.lowercased()
        return lowered.hasPrefix("http://127.0.0.1") || lowered.hasPrefix("http://localhost")
            || lowered.hasPrefix("http://[::1]") || lowered == "null"
    }
}
