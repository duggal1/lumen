import Foundation
import QuartzCore

/// UI-only display cadence. 60 Hz panels stay at 60; higher refresh displays
/// may negotiate up to 90 Hz. The OS ultimately chooses presentation cadence.
enum StudioDisplayRate {
    static func range(screenMaximum: Int) -> CAFrameRateRange {
        let target = Float(min(90, max(1, screenMaximum)))
        return CAFrameRateRange(minimum: min(60, target), maximum: target, preferred: target)
    }
}

/// Exact solution of a critically damped spring. Remaining distance is the
/// target minus position, velocity is in points/second. No substep loop,
/// allocation, overshoot or queued animations. Only discrete wheel input.
struct StudioWheelSpring {
    private(set) var remaining = 0.0
    private(set) var velocity = 0.0
    var isIdle: Bool { remaining == 0 }
    private let omega = 42.0

    mutating func add(_ delta: Double) {
        guard delta.isFinite else { return }
        let next = min(max(remaining + delta, -1200), 1200)
        if next == 0 || next.sign != remaining.sign || delta.sign != remaining.sign { velocity = 0 }
        remaining = next
    }

    mutating func advance(dt: Double) -> Double {
        guard !isIdle, dt.isFinite, dt > 0 else { return 0 }
        let h = min(dt, 0.1), old = remaining
        let slope = omega * old - velocity
        let decay = exp(-omega * h)
        let next = (old + slope * h) * decay
        let nextVelocity = (velocity + omega * slope * h) * decay
        if abs(next) <= 0.35 || next.sign != old.sign {
            remaining = 0; velocity = 0
            return old
        }
        // Strong retargeting may leave velocity pointing away from the
        // current destination. Never emit movement in the wrong direction.
        let delta = old - next
        guard delta.sign == old.sign, abs(delta) <= abs(old) else {
            velocity = 0
            return 0
        }
        remaining = next
        velocity = nextVelocity
        return delta
    }
}
