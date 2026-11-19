import Foundation

/// Value type. A source-pixel rect with a top-left origin.
/// Ownership: none (copied by value). Threading: immutable `Sendable`, safe to
/// share across queues; all maths is pure and deterministic.
public struct PxRect: Sendable, Equatable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    public var maxX: Double { x + w }
    public var maxY: Double { y + h }
    public var cx: Double { x + w / 2 }
    public var cy: Double { y + h / 2 }
    public var aspect: Double { w / max(h, 1e-9) }
    public var isValid: Bool { w > 0 && h > 0 && x.isFinite && y.isFinite && w.isFinite && h.isFinite }

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && px <= maxX && py >= y && py <= maxY
    }

    public func insetBy(_ d: Double) -> PxRect {
        PxRect(x: x + d, y: y + d, w: max(1, w - 2 * d), h: max(1, h - 2 * d))
    }

    public func centered(w nw: Double, h nh: Double) -> PxRect {
        PxRect(x: cx - nw / 2, y: cy - nh / 2, w: nw, h: nh)
    }

    public func intersection(_ o: PxRect) -> PxRect {
        let nx = max(x, o.x), ny = max(y, o.y)
        return PxRect(x: nx, y: ny,
                      w: max(1, min(maxX, o.maxX) - nx),
                      h: max(1, min(maxY, o.maxY) - ny))
    }

    /// Centre lerps linearly, size lerps geometrically. Stays inside the source
    /// rect when both inputs do. Pure; used by the 480 Hz quintic crop blends.
    public static func blend(_ a: PxRect, _ b: PxRect, _ s: Double) -> PxRect {
        let cx = a.cx + (b.cx - a.cx) * s, cy = a.cy + (b.cy - a.cy) * s
        let w = exp(log(a.w) + (log(b.w) - log(a.w)) * s)
        let h = exp(log(a.h) + (log(b.h) - log(a.h)) * s)
        return PxRect(x: cx - w / 2, y: cy - h / 2, w: w, h: h)
    }
}
