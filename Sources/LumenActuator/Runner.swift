import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import ScreenCaptureKit
import LumenCore

/// Receives the markers a script run produces.
public protocol MarkerSink: AnyObject, Sendable {
    func record(marker: CaptureMarker) async
}

/// Watches for a human taking over: an untagged mouse jump, or repeated
/// Escape presses. The kill switch always works.
public final class HumanWatchdog: @unchecked Sendable {
    public enum Takeover: Sendable, Equatable {
        case humanMoved
        case escaped
    }

    private let lock = NSLock()
    private var lastPoint: CGPoint?
    private var escapeCount = 0
    private var lastEscapeDown = false
    private var armed = false

    /// Starts watching from the current pointer position.
    public func arm() {
        lock.lock()
        lastPoint = InputSynthesizer.currentMouseLocation()
        escapeCount = 0
        lastEscapeDown = false
        armed = true
        lock.unlock()
    }

    public func disarm() {
        lock.lock(); armed = false; lock.unlock()
    }

    /// Call while the script is running. Returns a takeover reason, if any.
    public func check() -> Takeover? {
        lock.lock(); defer { lock.unlock() }
        guard armed else { return nil }
        // Escape counting: the key bit is set while the key is held.
        let escapeDown = CGEventSource.keyState(.combinedSessionState, key: 53)
        if escapeDown && !lastEscapeDown {
            escapeCount += 1
            if escapeCount >= 3 { return .escaped }
        }
        lastEscapeDown = escapeDown
        let point = InputSynthesizer.currentMouseLocation()
        if let last = lastPoint {
            let dx = point.x - last.x, dy = point.y - last.y
            if (dx * dx + dy * dy).squareRoot() > 30 { return .humanMoved }
        }
        lastPoint = point
        return nil
    }
}

/// Runs a demo script: launches an app, drives it, and writes a marker for
/// every step.
public actor ScriptRunner {
    public let mode: InputMode
    private let sink: MarkerSink
    private let synth: InputSynthesizer
    private let watchdog = HumanWatchdog()
    private var bundleID: String?

    public init(mode: InputMode = .physical, sink: MarkerSink) {
        self.mode = mode
        self.sink = sink
        self.synth = InputSynthesizer(mode: mode)
    }

    /// Runs the script and returns the markers it produced.
    @discardableResult
    public func run(_ script: DemoScript) async throws -> [CaptureMarker] {
        bundleID = script.app.bundleID ?? bundleID
        watchdog.arm()
        defer { watchdog.disarm() }
        var markers: [CaptureMarker] = []
        for (index, step) in script.steps.enumerated() {
            try Task.checkCancellation()
            let start = HostClock.now()
            var resolved: CGRect?
            for action in step.do {
                if let takeover = watchdog.check() {
                    throw ActuatorError.humanTakeover(takeover)
                }
                resolved = try await perform(action, fallbackRect: resolved)
            }
            let end = HostClock.now()
            let marker = CaptureMarker(id: step.id.isEmpty ? "step-\(index + 1)" : step.id,
                                       label: step.say,
                                       startHostSeconds: start,
                                       endHostSeconds: end,
                                       rect: resolved)
            await sink.record(marker: marker)
            markers.append(marker)
            if step.padAfterS > 0 {
                try await Task.sleep(for: .seconds(step.padAfterS))
            }
        }
        return markers
    }

    private func perform(_ action: DemoScript.Action, fallbackRect: CGRect?) async throws -> CGRect? {
        switch action {
        case .launch(let launch):
            let id = launch.bundleID ?? bundleID
            if let id {
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                    ?? URL(fileURLWithPath: "/Applications/\(id).app")
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.open(url)
                }
            }
            try await Task.sleep(for: .seconds(max(launch.waitS, 0.1)))
            return fallbackRect

        case .waitFor(let wait):
            let deadline = Date().addingTimeInterval(max(wait.timeoutS, 0.1))
            while Date() < deadline {
                let matches = AXSupport.find(TargetRef(role: wait.role, title: wait.title,
                                                       identifier: wait.identifier, index: 0), bundleID: bundleID)
                if !matches.isEmpty { return fallbackRect }
                try await Task.sleep(for: .milliseconds(120))
            }
            throw ActuatorError.timeout("No element matched \(wait.role ?? "any") / \(wait.title ?? "")")

        case .click(let click):
            let element = try resolve(click.target)
            if mode == .virtual, let element = element, AXSupport.press(element) {
                return AXSupport.rect(element)
            }
            guard let point = targetPoint(click.target, element: element, fallback: fallbackRect) else {
                throw ActuatorError.failed("Could not resolve the click target.")
            }
            try await synth.moveCursor(to: point, ms: max(click.moveMs, 50))
            try synth.click(at: point)
            return element.flatMap { AXSupport.rect($0) } ?? fallbackRect

        case .move(let move):
            guard let point = targetPoint(move.target, element: nil, fallback: fallbackRect) else {
                throw ActuatorError.failed("Could not resolve the move target.")
            }
            try await synth.moveCursor(to: point, ms: max(move.moveMs, 50))
            return fallbackRect

        case .type(let type):
            try await synth.type(type.text, cps: type.cps)
            return fallbackRect

        case .key(let key):
            try synth.press(key: key.key, modifiers: key.modifiers)
            return fallbackRect

        case .sleep(let sleep):
            try await Task.sleep(for: .seconds(max(sleep.seconds, 0)))
            return fallbackRect

        case .scroll(let scroll):
            let point = targetPoint(scroll.target, element: nil, fallback: fallbackRect) ?? InputSynthesizer.currentMouseLocation()
            try synth.scroll(at: point, dy: scroll.dy)
            return fallbackRect

        case .screenshot(let shot):
            if let path = shot.path {
                try await captureScreen(to: path)
            }
            return fallbackRect
        }
    }

    private func resolve(_ target: TargetRef?) throws -> AXUIElement? {
        guard let target else { return nil }
        let matches = AXSupport.find(target, bundleID: bundleID)
        guard !matches.isEmpty else { return nil }
        return matches[min(max(target.index, 0), matches.count - 1)]
    }

    private func targetPoint(_ target: TargetRef?, element: AXUIElement?, fallback: CGRect?) -> CGPoint? {
        if let element, let center = AXSupport.center(of: element) { return center }
        if let target {
            let matches = AXSupport.find(target, bundleID: bundleID)
            if let first = matches.first, let center = AXSupport.center(of: first) { return center }
        }
        if let fallback {
            return CGPoint(x: fallback.midX, y: fallback.midY)
        }
        return nil
    }

    private func captureScreen(to path: String) async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.width)
        configuration.height = Int(display.height)
        configuration.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url)
    }
}

/// Actuator failures.
public enum ActuatorError: Error, Sendable {
    case failed(String)
    case timeout(String)
    case humanTakeover(HumanWatchdog.Takeover)

    public var message: String {
        switch self {
        case .failed(let m): return m
        case .timeout(let m): return "Timed out waiting for \(m)."
        case .humanTakeover(.humanMoved): return "A human moved the mouse, so the run was paused."
        case .humanTakeover(.escaped): return "The run was aborted (Escape pressed three times)."
        }
    }
}
