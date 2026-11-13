import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
@preconcurrency import ScreenCaptureKit
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
    // AGENT: compare against the last synthesized position instead of the previous action's position.
    public func check(expected: CGPoint? = nil, monitorsPointer: Bool = true) -> Takeover? {
        lock.lock(); defer { lock.unlock() }
        guard armed else { return nil }
        // Escape counting: the key bit is set while the key is held.
        let escapeDown = CGEventSource.keyState(.combinedSessionState, key: 53)
        if escapeDown && !lastEscapeDown {
            escapeCount += 1
            if escapeCount >= 3 { lastEscapeDown = escapeDown; return .escaped }
        }
        lastEscapeDown = escapeDown
        if monitorsPointer {
            let point = InputSynthesizer.currentMouseLocation()
            if let last = expected ?? lastPoint {
                let dx = point.x - last.x, dy = point.y - last.y
                if (dx * dx + dy * dy).squareRoot() > 12 { return .humanMoved }
            }
            lastPoint = point
        }
        return nil
    }
}

/// Runs a demo script: launches an app, drives it, and writes a marker for
/// every step.
public actor ScriptRunner {
    /// Called as soon as a marker is posted.
    ///
    /// AGENT: a run that stopped mid-script used to lose every marker it had
    /// already produced; the caller can now persist each one as it lands.
    public typealias Checkpoint = @Sendable (CaptureMarker) async -> Void

    public let mode: InputMode
    private let sink: MarkerSink
    private let synth: InputSynthesizer
    private let watchdog = HumanWatchdog()
    private var bundleID: String?
    /// AGENT: the frontmost app must stay inside this set for the whole run.
    private let allowedBundles: Set<String>
    /// AGENT: LumenActuator cannot import LumenControl, so confinement arrives as
    /// a closure. Defaults to refusing writes so a forgotten caller is safe.
    private let writablePath: @Sendable (String) throws -> URL
    /// AGENT: process-targeted events need a runtime seam to enter the recording event log.
    private let inputInjector: InputSynthesizer.EventInjector?

    public init(mode: InputMode = .physical, sink: MarkerSink,
                allowedBundles: Set<String> = [],
                inputInjector: InputSynthesizer.EventInjector? = nil,
                writablePath: @escaping @Sendable (String) throws -> URL = { _ in
                    throw ActuatorError.failed("Screenshot paths are not permitted for this run.")
                }) {
        self.mode = mode
        self.sink = sink
        self.synth = InputSynthesizer(mode: mode)
        self.synth.eventInjector = inputInjector
        self.allowedBundles = allowedBundles
        self.inputInjector = inputInjector
        self.writablePath = writablePath
    }

    /// Runs the script and returns the markers it produced.
    @discardableResult
    public func run(_ script: DemoScript, checkpoint: Checkpoint? = nil) async throws -> [CaptureMarker] {
        // AGENT: duplicate step IDs would make later marker references ambiguous.
        let ids = script.steps.enumerated().map { $0.element.id.isEmpty ? "step-\($0.offset + 1)" : $0.element.id }
        guard Set(ids).count == ids.count else { throw ActuatorError.failed("Script step IDs must be unique.") }
        bundleID = script.app.bundleID ?? bundleID
        guard let bundleID, !bundleID.isEmpty, allowedBundles.contains(bundleID) else {
            throw ActuatorError.failed("The script target must be a non-empty, approved bundle_id.")
        }
        for step in script.steps {
            for action in step.do {
                if case .launch(let launch) = action {
                    let target = launch.bundleID ?? bundleID
                    guard allowedBundles.contains(target) else {
                        throw ActuatorError.failed("Launch target \(target) is not on the allow-list.")
                    }
                }
            }
        }
        synth.gate = ActuationGate(allowed: allowedBundles, expectedFrontmost: bundleID)
        watchdog.arm()
        let monitorsPointer = mode == .physical
        synth.checkpoint = { [watchdog, weak synth] in
            if let takeover = watchdog.check(expected: synth?.lastPosted, monitorsPointer: monitorsPointer) {
                throw ActuatorError.humanTakeover(takeover)
            }
        }
        defer { synth.checkpoint = nil; watchdog.disarm() }
        if mode == .virtual {
            guard inputInjector != nil else {
                throw ActuatorError.failed("Virtual mode requires an active recording event sink.")
            }
        }
        if let running = runningApplication(for: bundleID) {
            if mode == .virtual { synth.delivery = .pid(running.processIdentifier) }
            // AGENT: activate only the approved target before sending its events.
            running.activate(options: [.activateAllWindows])
            try await waitForFrontmost(bundleID, timeout: 5)
        } else if mode == .virtual {
            let launchesTarget = script.steps.contains { step in
                step.do.contains { if case .launch(let launch) = $0 { return (launch.bundleID ?? bundleID) == bundleID }; return false }
            }
            if !launchesTarget {
                throw ActuatorError.failed("The virtual target is not running; add a launch action for \(bundleID).")
            }
        }
        var markers: [CaptureMarker] = []
        for (index, step) in script.steps.enumerated() {
            try Task.checkCancellation()
            let start = HostClock.now()
            var resolved: CGRect?
            for action in step.do {
                try checkTakeover()
                resolved = try await perform(action, fallbackRect: resolved)
            }
            let end = HostClock.now()
            let marker = CaptureMarker(id: step.id.isEmpty ? "step-\(index + 1)" : step.id,
                                       label: step.say,
                                       startHostSeconds: start,
                                       endHostSeconds: end,
                                       rect: resolved)
            await sink.record(marker: marker)
            await checkpoint?(marker)
            markers.append(marker)
            if step.padAfterS > 0 {
                try await nap(step.padAfterS)
            }
        }
        return markers
    }

    /// Waits, but keeps listening for the kill switch.
    ///
    /// AGENT: a `sleep: 30` step used to be uninterruptible, so Escape did
    /// nothing until it finished. Long waits are sliced and re-checked.
    private func nap(_ seconds: Double) async throws {
        var remaining = seconds
        while remaining > 0 {
            try checkTakeover()
            try Task.checkCancellation()
            let slice = min(remaining, 0.1)
            try await Task.sleep(for: .seconds(slice))
            remaining -= slice
        }
    }

    private func perform(_ action: DemoScript.Action, fallbackRect: CGRect?) async throws -> CGRect? {
        switch action {
        case .launch(let launch):
            let id = launch.bundleID ?? bundleID
            guard let id, allowedBundles.contains(id) else {
                throw ActuatorError.failed("Launch target is not on the allow-list.")
            }
            bundleID = id
            synth.gate = ActuationGate(allowed: allowedBundles, expectedFrontmost: id)
            if let running = runningApplication(for: id) {
                // AGENT: activate only the approved target before sending its events.
                running.activate(options: [.activateAllWindows])
            } else {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
                      NSWorkspace.shared.open(url) else {
                    throw ActuatorError.failed("Could not launch approved app \(id).")
                }
            }
            // AGENT: virtual delivery needs the newly launched app's process id before sending input.
            let deadline = Date().addingTimeInterval(10)
            var targetPID = processID(for: id)
            while targetPID == nil, Date() < deadline {
                try checkTakeover()
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
                targetPID = processID(for: id)
            }
            guard let targetPID else { throw ActuatorError.timeout("launching \(id)") }
            if mode == .virtual { synth.delivery = .pid(targetPID) }
            try await waitForFrontmost(id, timeout: 5)
            try await nap(max(launch.waitS, 0.1))
            return fallbackRect

        case .waitFor(let wait):
            let deadline = Date().addingTimeInterval(max(wait.timeoutS, 0.1))
            while Date() < deadline {
                let matches = AXSupport.find(TargetRef(role: wait.role, title: wait.title,
                                                       identifier: wait.identifier, index: 0), bundleID: bundleID)
                if !matches.isEmpty { return fallbackRect }
                try checkTakeover()
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(120))
            }
            throw ActuatorError.timeout("No element matched \(wait.role ?? "any") / \(wait.title ?? "")")

        case .click(let click):
            let element = try resolve(click.target)
            guard let point = targetPoint(click.target, x: click.x, y: click.y,
                                          element: element, fallback: fallbackRect) else {
                throw ActuatorError.failed("Could not resolve the click target.")
            }
            try await synth.moveCursor(to: point, ms: max(click.moveMs, 50))
            try synth.checkBeforeAction()
            if mode == .virtual, max(click.count, 1) == 1, click.button?.lowercased() != "right",
               let element, AXSupport.press(element) {
                try await synth.recordPointer(kind: .down, at: point)
                try await synth.recordPointer(kind: .up, at: point)
            } else {
                try await synth.click(at: point, button: click.button, count: click.count)
            }
            return element.flatMap { AXSupport.rect($0) } ?? fallbackRect

        case .drag(let drag):
            guard let start = targetPoint(drag.from, x: drag.fromX, y: drag.fromY,
                                          element: nil, fallback: fallbackRect),
                  let end = targetPoint(drag.to, x: drag.toX, y: drag.toY,
                                        element: nil, fallback: fallbackRect) else {
                throw ActuatorError.failed("Could not resolve the drag endpoints.")
            }
            try await synth.drag(from: start, to: end, ms: max(drag.moveMs, 100))
            return fallbackRect

        case .move(let move):
            guard let point = targetPoint(move.target, x: move.x, y: move.y,
                                          element: nil, fallback: fallbackRect) else {
                throw ActuatorError.failed("Could not resolve the move target.")
            }
            try await synth.moveCursor(to: point, ms: max(move.moveMs, 50))
            return fallbackRect

        case .type(let type):
            try await synth.type(type.text, cps: type.cps)
            return fallbackRect

        case .paste(let paste):
            // AGENT: long text goes in atomically instead of keystroke by keystroke.
            try await synth.paste(paste.text)
            return fallbackRect

        case .key(let key):
            try await synth.press(key: key.key, modifiers: key.modifiers)
            return fallbackRect

        case .sleep(let sleep):
            try await nap(max(sleep.seconds, 0))
            return fallbackRect

        case .scroll(let scroll):
            let point = targetPoint(scroll.target, x: nil, y: nil,
                                    element: nil, fallback: fallbackRect) ?? InputSynthesizer.currentMouseLocation()
            try await synth.scroll(at: point, dy: scroll.dy)
            return fallbackRect

        case .screenshot(let shot):
            if let raw = shot.path {
                // AGENT: a screenshot could write a PNG anywhere the user could write.
                try await captureScreen(to: try writablePath(raw).path)
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

    private func checkTakeover() throws {
        if let takeover = watchdog.check(expected: synth.lastPosted, monitorsPointer: mode == .physical) {
            throw ActuatorError.humanTakeover(takeover)
        }
    }

    private func processID(for bundleID: String) -> pid_t? {
        runningApplication(for: bundleID)?.processIdentifier
    }

    private func runningApplication(for bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
    }

    private func waitForFrontmost(_ bundleID: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID, Date() < deadline {
            try checkTakeover()
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else {
            throw ActuatorError.timeout("bringing \(bundleID) to the front")
        }
    }

    private func targetPoint(_ target: TargetRef?, x: Double?, y: Double?,
                             element: AXUIElement?, fallback: CGRect?) -> CGPoint? {
        var frame: CGRect?
        if let element, let rect = AXSupport.rect(element) { frame = rect }
        if frame == nil, let target,
           let match = AXSupport.find(target, bundleID: bundleID).first {
            frame = AXSupport.rect(match)
        }
        if frame == nil { frame = fallback }
        guard let frame else { return nil }
        // AGENT: x/y were parsed and then ignored, so every click landed on the
        // centre. They are fractions of the target, clamped to its bounds.
        if let x, let y {
            let fx = min(max(x, 0), 1), fy = min(max(y, 0), 1)
            return CGPoint(x: frame.minX + frame.width * fx, y: frame.minY + frame.height * fy)
        }
        return CGPoint(x: frame.midX, y: frame.midY)
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
