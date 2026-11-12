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
