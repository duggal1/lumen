import Foundation
import LumenCore

/// Offline, zero-phase smoothing. Forward/backward exact critically-damped
/// steps do not trail the recorded action. No network or runtime allocation
/// occurs in video rendering; this runs once during Director derivation.
public func zeroPhaseSmooth(_ input: [Double], omega: Double, dt: Double) -> [Double] {
    guard input.count > 1, omega.isFinite, omega > 0, dt > 0 else { return input }
    var output = input
    var x = input[0], velocity = 0.0
    for i in input.indices {
        springStep(&x, &velocity, target: input[i], omega: omega, dt: dt)
        output[i] = x
    }
    x = output[output.count - 1]
    velocity = 0
    for i in output.indices.reversed() {
        springStep(&x, &velocity, target: output[i], omega: omega, dt: dt)
        output[i] = x
    }
    return output
}

/// Scale-corrected exact critically damped spring used by the LIVE camera.
/// The offline camera no longer requires it, but live zoom/pan still does.
@inline(__always) func scaledSpring(_ x: inout Double, _ v: inout Double,
                                     target: Double, omega w: Double,
                                     dt: Double, scale s: Double) {
    let d = (x - target) * s, vs = v * s, e = exp(-w * dt)
    let nd = (d + (vs + w * d) * dt) * e
    let nv = (vs - w * (vs + w * d) * dt) * e
    x = target + nd / s
    v = nv / s
}
