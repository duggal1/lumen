import Foundation

/// One 10 Hz browser observation in SOURCE time and SOURCE pixels.
/// Ownership: none (plain value produced by Capture, consumed by Director).
/// Threading: immutable `Sendable`, safe to cross the capture/Director boundary.
public struct ViewportRecord: Sendable, Equatable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let browserFront = Flags(rawValue: 1 << 0)
        /// Keyboard focus is in browser chrome, not the page.
        public static let uiFocus = Flags(rawValue: 1 << 1)
        public static let webValid = Flags(rawValue: 1 << 2)
    }

    public var t: Double
    public var flags: Flags
    public var window: PxRect
    public var web: PxRect

    public init(t: Double, flags: Flags, window: PxRect, web: PxRect) {
        self.t = t; self.flags = flags; self.window = window; self.web = web
    }
}
