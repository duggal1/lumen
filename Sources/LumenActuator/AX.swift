import Foundation
import ApplicationServices
import AppKit

// MARK: - AX tree

/// One node of a compact accessibility snapshot.
public struct AXNode: Sendable, Codable, Equatable {
    public var role: String
    public var title: String?
    public var value: String?
    public var identifier: String?
    public var descriptionText: String?
    public var enabled: Bool
    public var focused: Bool
    /// Normalized position inside the window (0...1, top-left origin).
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    /// Screen rect in points.
    public var frame: CGRect?
    public var children: [AXNode] = []
    public init(role: String = "AXUnknown", title: String? = nil, value: String? = nil,
                identifier: String? = nil, descriptionText: String? = nil, enabled: Bool = true,
                focused: Bool = false, x: Double? = nil, y: Double? = nil, width: Double? = nil,
                height: Double? = nil, frame: CGRect? = nil, children: [AXNode] = []) {
        self.role = role; self.title = title; self.value = value; self.identifier = identifier
        self.descriptionText = descriptionText; self.enabled = enabled; self.focused = focused
        self.x = x; self.y = y; self.width = width; self.height = height
        self.frame = frame; self.children = children
    }

    public var label: String {
        [title, value, identifier].compactMap { $0 }.first ?? role
    }
}

/// Reads the accessibility tree of an application.
public enum AXSupport {
    /// The application element for a bundle identifier.
    public static func application(bundleID: String) -> AXUIElement? {
        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { $0.bundleIdentifier == bundleID }) else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium and Electron apps answer AX queries only when these are set.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return element
    }

    public static func frontmostApplication() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// A compact snapshot of the app (or the frontmost app).
    public static func snapshot(bundleID: String?, maxDepth: Int = 6, maxNodes: Int = 400) -> AXNode? {
        guard let app = bundleID.flatMap({ application(bundleID: $0) }) ?? frontmostApplication() else { return nil }
        let window = focusedWindow(in: app)
        let root = window ?? app
        var count = 0
        return axNode(for: root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, counter: &count)
    }

    private static func focusedWindow(in app: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    private static func axNode(for element: AXUIElement, depth: Int, maxDepth: Int, maxNodes: Int,
                                counter: inout Int) -> AXNode {
        var node = AXNode()
        counter += 1
        AXUIElementSetMessagingTimeout(element, 0.1)
        node.role = attribute(element, kAXRoleAttribute) as? String ?? "AXUnknown"
        node.title = attribute(element, kAXTitleAttribute) as? String
        node.value = attribute(element, kAXValueAttribute) as? String
        node.identifier = attribute(element, kAXIdentifierAttribute) as? String
        node.descriptionText = attribute(element, kAXDescriptionAttribute) as? String
        node.enabled = (attribute(element, kAXEnabledAttribute) as? Bool) ?? true
        node.focused = (attribute(element, kAXFocusedAttribute) as? Bool) ?? false
        if let frame = rect(element) {
            node.frame = frame
            if let window = enclosingWindow(element) {
                let origin = window.origin
                node.x = (frame.origin.x - origin.x) / max(window.size.width, 1)
                node.y = (frame.origin.y - origin.y) / max(window.size.height, 1)
                node.width = frame.size.width / max(window.size.width, 1)
                node.height = frame.size.height / max(window.size.height, 1)
            }
        }
        if depth < maxDepth, counter < maxNodes {
            var children: [AXNode] = []
            if let list = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                for child in list.prefix(maxNodes - counter) {
                    children.append(axNode(for: child, depth: depth + 1, maxDepth: maxDepth,
                                          maxNodes: maxNodes, counter: &counter))
                }
            }
            node.children = children
        }
        return node
    }

    private static func enclosingWindow(_ element: AXUIElement) -> (origin: CGPoint, size: CGSize)? {
        var current: AXUIElement = element
        for _ in 0..<12 {
            if let role = attribute(current, kAXRoleAttribute) as? String, role == "AXWindow" {
                guard let p = attribute(current, kAXPositionAttribute), let s = attribute(current, kAXSizeAttribute),
                      CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
                var pos = CGPoint.zero, size = CGSize.zero
                AXValueGetValue(p as! AXValue, .cgPoint, &pos)
                AXValueGetValue(s as! AXValue, .cgSize, &size)
                return (pos, size)
            }
            guard let parent = attribute(current, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            let parentElement = parent as! AXUIElement
            current = parentElement
        }
        return nil
    }

    // MARK: Element lookup

    /// Finds elements matching a target reference.
    public static func find(_ target: TargetRef, bundleID: String?) -> [AXUIElement] {
        guard let app = bundleID.flatMap({ application(bundleID: $0) }) ?? frontmostApplication() else { return [] }
        var found: [AXUIElement] = []
        var stack: [AXUIElement] = [app]
        var visited = 0
        while !stack.isEmpty, visited < 4000 {
            let element = stack.removeFirst()
            visited += 1
            if matches(element, target) { found.append(element) }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children)
            }
        }
        return found
    }

    private static func matches(_ element: AXUIElement, _ target: TargetRef) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.05)
        if let role = target.role, (attribute(element, kAXRoleAttribute) as? String) != role { return false }
        if let title = target.title {
            let name = (attribute(element, kAXTitleAttribute) as? String) ?? ""
            let desc = (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
            let value = (attribute(element, kAXValueAttribute) as? String) ?? ""
            if !(name == title || desc == title || value == title) { return false }
        }
        if let identifier = target.identifier,
           (attribute(element, kAXIdentifierAttribute) as? String) != identifier { return false }
        return true
    }

    /// Performs an AX press on an element.
    @discardableResult
    public static func press(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.2)
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Sets the value of a text field.
    @discardableResult
    public static func setValue(_ value: String, on element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.2)
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    public static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    public static func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(x: pos.x, y: pos.y, width: size.width, height: size.height)
    }

    /// The centre of an element in screen points.
    public static func center(of element: AXUIElement) -> CGPoint? {
        guard let r = rect(element) else { return nil }
        return CGPoint(x: r.midX, y: r.midY)
    }
}
