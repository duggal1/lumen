import Foundation
import ApplicationServices
import CoreGraphics
import os

/// A frontmost surface Lumen can resolve to a real frame: a window, a sheet,
/// a modal dialog or a popover. Produced by `WindowContent.visibleSurfaces()`
/// in production and injected by a deterministic probe in headless tests.
///
/// `id` is the CGWindowNumber (or a stable AX token for a sheet child), so a
/// click can diff the current set against the previous one and emit a frame
/// the instant a *new* surface appears — the dialog-opening moment the camera
/// used to miss.
public struct AXSurface: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case window, sheet, modal, popover
    }
    public var id: Int
    public var kind: Kind
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var frame: CGRect
    public var appName: String?

    public init(id: Int, kind: Kind, role: String?, subrole: String?, title: String?,
                frame: CGRect, appName: String?) {
        self.id = id; self.kind = kind; self.role = role; self.subrole = subrole
        self.title = title; self.frame = frame; self.appName = appName
    }

    /// Stable surface identity for new-surface diffing and focus epochs.
    public var token: String {
        "\(kind.rawValue):\(id):\(role ?? ""):\(subrole ?? ""):\(title ?? "")"
    }

    /// Window-level AX label. Pipe-separated on purpose: element hit-tests use
    /// space-joined labels, so a planner can tell "the dialog itself" from
    /// "a control inside it" without a second channel.
    public var axLabel: String {
        "window|\(role ?? "AXWindow")|\(subrole ?? "")|\(title ?? "")"
    }

    /// Classifies a native surface from its AX role/subrole. Unknown roles are
    /// left alone rather than guessed into a dialog.
    public static func classify(role: String?, subrole: String?) -> Kind? {
        let r = role ?? "", s = subrole ?? ""
        if r.contains("Sheet") || s.contains("Sheet") { return .sheet }
        if r.contains("Popover") || s.contains("Popover") { return .popover }
        if r.contains("Dialog") || s.contains("Dialog") || s.contains("Modal") { return .modal }
        if r.contains("Window") || s.contains("Window") { return .window }
        return nil
    }
}

/// Finds the part of a window that is *content*: everything below the title
/// bar and any top toolbar. ScreenCaptureKit hands back the whole window frame
/// (traffic lights, title, toolbar), so the capture engine crops this band out
/// and the recording contains only what the app drew below it.
///
/// Resolution is done through the Accessibility tree, which is the only
/// public source of window layout in points. Threading: pure queries, call
/// from any queue, never from the video queue (AX can block for a frame).
public enum WindowContent {
    public struct Geometry: Sendable, Equatable {
        /// Chrome height in points measured from the window frame's top edge.
        public var topInset: Double
        /// Window frame in points.
        public var width: Double
        public var height: Double

        public init(topInset: Double, width: Double, height: Double) {
            self.topInset = topInset
            self.width = width
            self.height = height
        }

        /// Fraction of the window height occupied by chrome. Stable across
        /// window resizes because a title bar keeps its point height.
        public var insetFraction: Double {
            guard height > 1 else { return 0 }
            return min(max(topInset / height, 0), 0.6)
        }

        public var contentWidth: Double { max(width, 1) }
        public var contentHeight: Double { max(height - topInset, 1) }
    }

    private static let log = Logger(subsystem: "com.lumen.studio", category: "window-content")

    /// Resolves chrome for a captured window. Returns `nil` when the window is
    /// gone or Accessibility is off, in which case the caller keeps the whole
    /// frame rather than guessing wrong.
    public static func resolve(windowID: CGWindowID, processID: pid_t, frame: CGRect) -> Geometry? {
        guard frame.width > 8, frame.height > 8 else { return nil }
        guard AXIsProcessTrusted() else {
            log.notice("accessibility is off: window capture keeps the full frame")
            return nil
        }
        guard let window = axWindow(processID: processID, title: windowTitle(windowID), frame: frame) else {
            log.notice("no accessibility window matched \(windowID)")
            return nil
        }
        guard let contentTop = contentTop(window, frame: frame) else { return nil }
        // CGFloat and Double are distinct types on some Swift toolchains;
        // convert explicitly so this compiles on both the local and CI SDKs.
        let inset = min(max(contentTop - Double(frame.minY), 0), Double(frame.height) * 0.6)
        guard inset > 1 else { return nil }
        return Geometry(topInset: inset, width: Double(frame.width), height: Double(frame.height))
    }

    /// Point height of the chrome band for a window we can describe but cannot
    /// inspect (used only to keep an estimate while the window is off-screen).
    public static func estimatedInset(for frame: CGRect) -> Double {
        min(52, max(Double(frame.height) * 0.05, 28))
    }

    // MARK: AX helpers

    private static func windowTitle(_ windowID: CGWindowID) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [NSDictionary],
              let entry = list.first else { return nil }
        return entry[kCGWindowName as String] as? String
    }

    private static func axWindow(processID: pid_t, title: String?, frame: CGRect) -> AXUIElement? {
        guard processID > 0 else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let raw = attribute(app, kAXWindowsAttribute) as? [AXUIElement], !raw.isEmpty else { return nil }
        var best: (AXUIElement, Double)?
        for element in raw {
            AXUIElementSetMessagingTimeout(element, 0.15)
            guard let rect = axFrame(element) else { continue }
            // Windows of the same app can sit on other screens: compare the
            // frame, then prefer the one whose title matches the captured one.
            let distance = abs(rect.minX - frame.minX) + abs(rect.minY - frame.minY)
                + abs(rect.width - frame.width) + abs(rect.height - frame.height)
            var score = Double(distance)
            if let title, let own = attribute(element, kAXTitleAttribute) as? String, !title.isEmpty, own == title {
                score -= 400
            }
            if best == nil || score < best!.1 { best = (element, score) }
        }
        // A collapsed mismatch means we found a different window of the app.
        guard let best, best.1 < Double(max(frame.width, frame.height)) * 0.5 else { return nil }
        return best.0
    }

    private static func contentTop(_ window: AXUIElement, frame: CGRect) -> Double? {
        guard let raw = attribute(window, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        var tops: [Double] = []
        for child in raw {
            AXUIElementSetMessagingTimeout(child, 0.12)
            guard let rect = axFrame(child), rect.width > 0, rect.height > 0 else { continue }
            // Only children that are pinned to the bottom and span most of the
            // window define the content body; floating panels and inspectors
            // must not move the crop.
            let spansWidth = rect.width >= frame.width * 0.5
            let touchesBottom = rect.maxY >= frame.maxY - 10
            let startsBelowTop = rect.minY > frame.minY + 1
            if spansWidth && touchesBottom && startsBelowTop { tops.append(Double(rect.minY)) }
        }
        return tops.min()
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = axValue(element, kAXPositionAttribute),
              let size = axValue(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }

    // MARK: - Frontmost surface observation (dialog / new-window detection)

    /// Snapshot of on-screen, non-Lumen surfaces. Cheap CGWindowList pass with
    /// a best-effort AX read for role/subrole/title; a hung app only costs its
    /// own short messaging timeout. Never called from the event-tap thread.
    public static func visibleSurfaces() -> [AXSurface] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [NSDictionary] else { return [] }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        var result: [AXSurface] = []
        result.reserveCapacity(list.count)
        for entry in list {
            guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.intValue, number > 0,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                  pid > 0, pid != selfPID,
                  (entry[kCGWindowIsOnscreen as String] as? Bool ?? true),
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 40, frame.height > 40 else { continue }
            let title = entry[kCGWindowName as String] as? String
            let owner = entry[kCGWindowOwnerName as String] as? String
            let info = axWindowInfo(processID: pid_t(pid), windowID: number, title: title, frame: frame)
            let role = info?.role ?? "AXWindow"
            let subrole = info?.subrole
            let kind = AXSurface.classify(role: role, subrole: subrole) ?? .window
            let surface = AXSurface(id: number, kind: kind, role: role, subrole: subrole,
                                    title: title ?? info?.title, frame: frame, appName: owner)
            result.append(surface)
            // Native sheets/dialogs are AX children, not separate CG windows.
            // Give them a stable synthetic id derived from their AX identity.
            for child in axDialogChildren(processID: pid_t(pid), frame: frame) {
                result.append(child)
            }
        }
        return result
    }

    private static func axWindowInfo(processID: pid_t, windowID: Int, title: String?,
                                     frame: CGRect) -> (role: String?, subrole: String?, title: String?)? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var best: (AXUIElement, Double)?
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.05)
            guard let rect = axFrame(window) else { continue }
            let distance = abs(rect.minX - frame.minX) + abs(rect.minY - frame.minY)
                + abs(rect.width - frame.width) + abs(rect.height - frame.height)
            var score = Double(distance)
            if let title, let own = attribute(window, kAXTitleAttribute) as? String, own == title { score -= 400 }
            if best == nil || score < best!.1 { best = (window, score) }
        }
        guard let best, best.1 < Double(max(frame.width, frame.height)) * 0.5 else { return nil }
        return (attribute(best.0, kAXRoleAttribute) as? String,
                attribute(best.0, kAXSubroleAttribute) as? String,
                attribute(best.0, kAXTitleAttribute) as? String)
    }

    private static func axDialogChildren(processID: pid_t, frame: CGRect) -> [AXSurface] {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.04)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var result: [AXSurface] = []
        for window in windows.prefix(4) {
            AXUIElementSetMessagingTimeout(window, 0.04)
            guard let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children.prefix(24) {
                AXUIElementSetMessagingTimeout(child, 0.04)
                let role = attribute(child, kAXRoleAttribute) as? String ?? ""
                let subrole = attribute(child, kAXSubroleAttribute) as? String ?? ""
                guard let kind = AXSurface.classify(role: role, subrole: subrole),
                      kind != .window, let rect = axFrame(child), rect.width > 40, rect.height > 40 else { continue }
                let title = attribute(child, kAXTitleAttribute) as? String
                var id = 0
                for scalar in "\(role)|\(subrole)|\(title ?? "")".unicodeScalars {
                    id = id &* 31 &+ Int(scalar.value)
                }
                result.append(AXSurface(id: abs(id) & 0x7fff_ffff, kind: kind, role: role,
                                        subrole: subrole, title: title, frame: rect,
                                        appName: nil))
            }
        }
        return result
    }
}
