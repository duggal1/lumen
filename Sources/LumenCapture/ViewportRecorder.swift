import AppKit
import ApplicationServices
import Foundation
import os
import LumenCore
import LumenProject

/// Polls the focused browser's AXWebArea at 10 Hz and appends one 48-byte
/// `ViewportRecord` per poll to `viewport.bin`.
///
/// Ownership: one instance per recording, owned by `RecordingSession`.
/// Threading: ALL mutable state is confined to the private serial `queue`.
/// Never call into this from the SCK sample queue or the event-tap thread;
/// Accessibility can block for a frame and must not stall capture.
public final class ViewportRecorder: @unchecked Sendable {
    /// How source pixels map to the global display the browser sits on.
    public struct Geometry: Sendable {
        /// Global top-left origin of the captured area, in points.
        public var originPt: @Sendable () -> (x: Double, y: Double)
        public var pixelsPerPoint: Double

        public init(originPt: @escaping @Sendable () -> (x: Double, y: Double), pixelsPerPoint: Double) {
            self.originPt = originPt; self.pixelsPerPoint = pixelsPerPoint
        }
    }

    /// Chromium requires an explicit opt-in before its AX tree is populated.
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera"
    ]
    static let browsers: Set<String> = chromium.union(["com.apple.Safari"])

    private let queue = DispatchQueue(label: "lumen.viewport", qos: .utility)
    private let logger = Logger(subsystem: "com.lumen.studio", category: "viewport")
    private let signpost = OSLog(subsystem: "com.lumen.studio", category: "viewport")
    private let writer: ViewportLog.Writer
    private let geometry: Geometry
    /// Source seconds; `nil` while paused or before the first video frame.
    private let now: @Sendable () -> Double?
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private var enabledPID: pid_t = 0
    private var cachedWeb: AXUIElement?
    private var lastWindow: AXUIElement?
    private var lastSearch = -10.0
    private var lastFlush = 0.0
    private var warnedNoWeb = false

    public init(writer: ViewportLog.Writer, geometry: Geometry, now: @escaping @Sendable () -> Double?) {
        self.writer = writer; self.geometry = geometry; self.now = now
    }

    public func start() {
        queue.sync {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.poll() }
            }
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o); observer = nil }
            writer.close()
        }
    }

    private func poll() {
        guard let t = now() else { return }
        os_signpost(.begin, log: signpost, name: "viewport.poll")
        defer { os_signpost(.end, log: signpost, name: "viewport.poll") }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        guard let app = element(sys, kAXFocusedApplicationAttribute as CFString) else { return emit(t, front: false) }
        var pid: pid_t = 0
        _ = AXUIElementGetPid(app, &pid)
        guard let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              Self.browsers.contains(bid) else { return emit(t, front: false) }
        AXUIElementSetMessagingTimeout(app, 0.08)
        if pid != enabledPID {
            enabledPID = pid; cachedWeb = nil; warnedNoWeb = false
            if Self.chromium.contains(bid) {
                AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue as CFTypeRef)
            }
        }
        guard let win = element(app, kAXFocusedWindowAttribute as CFString) ?? element(app, kAXMainWindowAttribute as CFString),
              let winFrame = frame(of: win) else { return emit(t, front: true) }
        if let lw = lastWindow, !CFEqual(lw, win) { cachedWeb = nil }
        lastWindow = win

        var webFrame = cachedWeb.flatMap { frame(of: $0) }
        if webFrame == nil || t - lastSearch > 2.0 {
            lastSearch = t
            if let found = findWebArea(in: win) { cachedWeb = found; webFrame = frame(of: found) }
            else if webFrame == nil { cachedWeb = nil }
        }
        if webFrame == nil, !warnedNoWeb {
            warnedNoWeb = true
            logger.warning("No AXWebArea for \(bid, privacy: .public); browser crop disabled for this window")
        }
        var ui = false
        if let wf = webFrame, let fe = element(sys, kAXFocusedUIElementAttribute as CFString), let ff = frame(of: fe),
           ff.width > 0, ff.height > 0 {
            ui = !wf.contains(CGPoint(x: ff.midX, y: ff.midY))
        }
        emit(t, front: true, window: winFrame, web: webFrame, ui: ui)
    }

    private func emit(_ t: Double, front: Bool, window: CGRect? = nil, web: CGRect? = nil, ui: Bool = false) {
        let o = geometry.originPt(), k = geometry.pixelsPerPoint
        func px(_ r: CGRect?) -> PxRect {
            guard let r else { return PxRect(x: 0, y: 0, w: 0, h: 0) }
            return PxRect(x: (r.minX - o.x) * k, y: (r.minY - o.y) * k,
                          w: r.width * k, h: r.height * k)
        }
        var flags: ViewportRecord.Flags = []
        if front { flags.insert(.browserFront) }
        if ui { flags.insert(.uiFocus) }
        let w = px(web)
        if w.w > 0 && w.h > 0 { flags.insert(.webValid) }
        writer.append(ViewportRecord(t: t, flags: flags, window: px(window), web: w))
        if t - lastFlush >= 0.25 {
            writer.flush(sync: t - lastFlush >= 2.0)
            lastFlush = t
        }
    }

    /// BFS, depth <= 14, <= 600 nodes. Returns the largest AXWebArea so the
    /// DevTools pane or a popup never wins over the real page.
    private func findWebArea(in root: AXUIElement) -> AXUIElement? {
        var nodes: [(AXUIElement, Int)] = [(root, 0)]
        var best: (AXUIElement, Double)?
        var visited = 0, head = 0
        while head < nodes.count, visited < 600 {
            let (el, depth) = nodes[head]; head += 1; visited += 1
            if role(el) == "AXWebArea" {
                if let f = frame(of: el), f.width * f.height > (best?.1 ?? 0) {
                    best = (el, f.width * f.height)
                }
                continue
            }
            if depth < 14 { for c in children(el) { nodes.append((c, depth + 1)) } }
        }
        return best?.0
    }
}

// MARK: AX helpers (free functions; no shared state, never on a hot queue)

private func element(_ el: AXUIElement, _ attr: CFString) -> AXUIElement? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr, &v) == .success,
          let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

private func children(_ el: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
          let arr = v as? [AXUIElement] else { return [] }
    return arr
}

private func role(_ el: AXUIElement) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v) == .success else { return nil }
    return v as? String
}

private func frame(of el: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
          let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
    return CGRect(origin: pt, size: sz)
}
