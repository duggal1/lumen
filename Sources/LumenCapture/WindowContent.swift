import Foundation
import ApplicationServices
import CoreGraphics
import os

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
        let inset = min(max(contentTop - frame.minY, 0), frame.height * 0.6)
        guard inset > 1 else { return nil }
        return Geometry(topInset: inset, width: frame.width, height: frame.height)
    }

    /// Point height of the chrome band for a window we can describe but cannot
    /// inspect (used only to keep an estimate while the window is off-screen).
    public static func estimatedInset(for frame: CGRect) -> Double {
        min(52, max(frame.height * 0.05, 28))
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
            var score = distance
            if let title, let own = attribute(element, kAXTitleAttribute) as? String, !title.isEmpty, own == title {
                score -= 400
            }
            if best == nil || score < best!.1 { best = (element, score) }
        }
        // A collapsed mismatch means we found a different window of the app.
        guard let best, best.1 < max(frame.width, frame.height) * 0.5 else { return nil }
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
            if spansWidth && touchesBottom && startsBelowTop { tops.append(rect.minY) }
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
}
