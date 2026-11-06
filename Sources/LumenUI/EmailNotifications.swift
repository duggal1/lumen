import Foundation
import AppKit

// MARK: - Message

public struct EmailMessage: Sendable, Equatable {
    public var to: String
    public var subject: String
    public var body: String

    public init(to: String, subject: String, body: String) {
        self.to = to; self.subject = subject; self.body = body
    }

    /// `mailto:` URL used by the system mail composer. Query values are
    /// percent-encoded, including newlines in the body.
    public var mailtoURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = to
        c.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        return c.url
    }
}

public enum EmailError: LocalizedError, Equatable {
    case cannotOpenComposer, missingRecipient
    public var errorDescription: String? {
        switch self {
        case .cannotOpenComposer: "Could not open the default mail app."
        case .missingRecipient: "Add an email address in Settings."
        }
    }
}

// MARK: - Transport

public protocol EmailTransport: Sendable {
    func send(_ message: EmailMessage) async throws
}

/// Opens the user's default mail client with a prefilled draft. Sending stays
/// a human action: Lumen never talks to an SMTP server or stores credentials.
public struct MailtoTransport: EmailTransport {
    public typealias Opener = @Sendable (URL) -> Bool
    private let open: Opener

    public init(open: @escaping Opener = { url in
        NSWorkspace.shared.open(url)
    }) {
        self.open = open
    }

    public func send(_ message: EmailMessage) async throws {
        guard let url = message.mailtoURL, open(url) else { throw EmailError.cannotOpenComposer }
    }
}

// MARK: - Preferences

public struct EmailPreferences: Sendable, Equatable {
    public static let enabledKey = "LumenEmailEnabled"
    public static let recipientKey = "LumenEmailRecipient"
    public static let onRecordingKey = "LumenEmailOnRecording"
    public static let onExportKey = "LumenEmailOnExport"

    public var enabled: Bool
    public var recipient: String
    public var onRecordingFinished: Bool
    public var onExportFinished: Bool

    public init(enabled: Bool = false, recipient: String = "",
                onRecordingFinished: Bool = true, onExportFinished: Bool = true) {
        self.enabled = enabled; self.recipient = recipient
        self.onRecordingFinished = onRecordingFinished; self.onExportFinished = onExportFinished
    }

    public init(defaults: UserDefaults) {
        enabled = defaults.bool(forKey: Self.enabledKey)
        recipient = defaults.string(forKey: Self.recipientKey) ?? ""
        onRecordingFinished = defaults.object(forKey: Self.onRecordingKey) as? Bool ?? true
        onExportFinished = defaults.object(forKey: Self.onExportKey) as? Bool ?? true
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(recipient, forKey: Self.recipientKey)
        defaults.set(onRecordingFinished, forKey: Self.onRecordingKey)
        defaults.set(onExportFinished, forKey: Self.onExportKey)
    }

    public var normalizedRecipient: String {
        recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Trigger

/// Event -> draft. Disabled or incomplete preferences return `false` without
/// touching the transport, so opt-in is real and testable.
public final class EmailNotificationService: @unchecked Sendable {
    public static let shared = EmailNotificationService()

    private let transport: any EmailTransport
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var _sent: [EmailMessage] = []

    public init(transport: any EmailTransport = MailtoTransport(), defaults: UserDefaults = .standard) {
        self.transport = transport; self.defaults = defaults
    }

    /// Drafts delivered since launch (useful for the Settings hint and tests).
    public var sent: [EmailMessage] { lock.withLock { _sent } }

    @discardableResult
    public func recordingFinished(project: URL, duration: Double) async -> Bool {
        await deliver(recording: true, subject: "Lumen recording finished: \(project.deletingPathExtension().lastPathComponent)",
                      body: """
A recording is ready in Lumen.

Project: \(project.lastPathComponent)
Duration: \(Self.clock(duration))

Open the project to edit or export it.
""")
    }

    @discardableResult
    public func exportFinished(file: URL) async -> Bool {
        await deliver(recording: false, subject: "Lumen export ready: \(file.lastPathComponent)",
                      body: """
Your export finished.

File: \(file.path)
""")
    }

    private func deliver(recording: Bool, subject: String, body: String) async -> Bool {
        let prefs = EmailPreferences(defaults: defaults)
        guard prefs.enabled,
              !prefs.normalizedRecipient.isEmpty,
              recording ? prefs.onRecordingFinished : prefs.onExportFinished else { return false }
        let message = EmailMessage(to: prefs.normalizedRecipient, subject: subject, body: body)
        do {
            try await transport.send(message)
            lock.withLock { _sent.append(message) }
            return true
        } catch {
            return false
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
