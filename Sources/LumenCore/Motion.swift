import Foundation

/// A scalar quintic with specified position, velocity, and acceleration at
/// both ends. The default end state is rest; retargets can continue C2.
public struct QuinticMove: Sendable {
    public let t0: Double
    public let T: Double
    private let c0, c1, c2, c3, c4, c5: Double

    public init(t0: Double, T: Double, x0: Double, v0: Double, a0: Double,
                x1: Double, v1: Double = 0, a1: Double = 0) {
        let duration = max(T.isFinite ? T : 1e-3, 1e-3)
        let duration2 = duration * duration
        let residualPosition = x1 - x0 - v0 * duration - 0.5 * a0 * duration2
        let residualVelocity = v1 * duration - v0 * duration - a0 * duration2
        let residualAcceleration = a1 * duration2 - a0 * duration2

        self.t0 = t0
        self.T = duration
        c0 = x0
        c1 = v0 * duration
        c2 = 0.5 * a0 * duration2
        c3 = 10 * residualPosition - 4 * residualVelocity + 0.5 * residualAcceleration
        c4 = -15 * residualPosition + 7 * residualVelocity - residualAcceleration
        c5 = 6 * residualPosition - 3 * residualVelocity + 0.5 * residualAcceleration
    }

    @inline(__always)
    public func sample(_ t: Double) -> (x: Double, v: Double, a: Double) {
        let u = min(max((t - t0) / T, 0), 1)
        let x = c0 + u * (c1 + u * (c2 + u * (c3 + u * (c4 + u * c5))))
        let v = (c1 + u * (2 * c2 + u * (3 * c3 + u * (4 * c4 + u * 5 * c5)))) / T
        let a = (2 * c2 + u * (6 * c3 + u * (12 * c4 + u * 20 * c5))) / (T * T)
        return (x, v, a)
    }
}

extension QuinticMove {
    /// The one temporal envelope a camera move is made of. Both the pan and
    /// the dolly ride this same normalised quintic, so they accelerate and
    /// settle together instead of looking like two unrelated animations.
    /// Quintic smootherstep is monotone (no overshoot), C2, exact at both
    /// ends, and arrives with zero velocity and zero acceleration — a gentle,
    /// filmed settle rather than a stop dead on the target.
    @inline(__always)
    public static func envelope(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }

    /// Quintic Hermite slope bases on [0,1] (the standard h10 / h11).
    /// Each has zero value, zero acceleration and zero jerk at BOTH ends, and
    /// unit derivative at exactly one end. Added to `envelope` they carry a
    /// handoff's incoming/outgoing velocity without moving the endpoints or
    /// changing the shape at zero velocity.
    ///
    /// The zero endpoint acceleration is the whole point: the cubic bases
    /// reach a hold with h''(1) of 2 and 4, so `fillHold` forced acceleration
    /// to zero in a single tick — an acceleration step that reads as a jerk
    /// spike (and fails the bounded-jerk motion-trace invariant). Quintic bases
    /// arrive with h'' = 0, so the move flows into the still hold with no step.
    @inline(__always)
    public static func leadSlope(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * (1 + x * x * (-6 + x * (8 - 3 * x)))
    }

    @inline(__always)
    public static func trailSlope(_ u: Double) -> Double {
        let x = min(max(u, 0), 1)
        return x * x * x * (-4 + x * (7 - 3 * x))
    }
}

/// Hard motion limits shared by the recorded camera. They are expressed in the
/// curve's own units so the solver can size a runway from the distance it must
/// travel instead of discovering a too-short quintic by its jerk spike at 480 Hz.
public enum MotionLimits {
    /// A filmed move stays under this jerk. It is a limit, not a target: the
    /// camera budgets runway from it so a pan/dolly never needs a snap to arrive.
    public static let cameraJerk = 1.0e6

    /// The solver's runway budget. It sits below the hard ceiling so the two
    /// continuity slopes a bridged handoff adds cannot push a move over it.
    /// Shared by the camera and its headless accuracy tests: one number, no magic
    /// literals duplicated in each place.
    public static let filmJerk = 7.0e5

    /// |envelope'''(u)| peaks at 60 (smootherstep); each Hermite slope basis
    /// peaks at 36 (|h'''(u)| of h10/h11). A rest-to-rest move carrying two
    /// continuity slopes therefore needs this much more runway than a plain one.
    @inline(__always)
    public static func minDuration(delta: Double, continuitySlopes: Int = 0,
                                   maxJerk: Double = cameraJerk) -> Double {
        let weight = 60.0 + 36.0 * Double(max(0, continuitySlopes))
        return pow(max(weight * abs(delta), 1e-12) / max(maxJerk, 1), 1.0 / 3.0)
    }

    /// The single jerk meter for a baked channel: peak |third difference| at the
    /// sample rate, in the curve's own units. Both the solver's limit and the
    /// headless invariant are measured this way, so "bounded jerk" means one
    /// thing everywhere.
    public static func peakJerk(_ values: [Float], rate: Double) -> Double {
        guard values.count > 3 else { return 0 }
        var peak = 0.0
        for i in 2..<(values.count - 1) {
            let j = (Double(values[i + 1]) - 3 * Double(values[i])
                     + 3 * Double(values[i - 1]) - Double(values[i - 2])) * rate * rate * rate
            peak = max(peak, abs(j))
        }
        return peak
    }
}
