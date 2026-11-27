import Foundation
import LumenCore
import LumenProject

/// 4-point Catmull-Rom. Linear interpolation at a fractional offset is a low-pass
/// (-2 dB @ 10 kHz, -6 dB @ 16 kHz at half a sample); this keeps the highs.
@inline(__always) private func cubic(_ x: [Float], _ pos: Double) -> Float {
    let i = Int(pos.rounded(.down))
    guard i >= 0, i + 1 < x.count else { return 0 }
    let f = Float(pos - Double(i))
    if f < 1e-6 { return x[i] }
    let p1 = x[i], p2 = x[i + 1]
    let p0 = i >= 1 ? x[i - 1] : p1
    let p3 = i + 2 < x.count ? x[i + 2] : p2
    return p1 + 0.5 * f * (p2 - p0 + f * (2 * p0 - 5 * p1 + 4 * p2 - p3 + f * (3 * (p1 - p2) + p3 - p0)))
}

/// Time-map audio sampling. Pure function of (samples, TimeMap).
extension AudioMixer {
    private struct CutWindow {
        let order: Int, center: Int, start: Int, end: Int
        let pre: Double, post: Double
    }

    /// 1ms source interpolation with the original 40ms equal-power cut
    /// crossfade. A chronological window sweep avoids testing every cut
    /// against every output sample. Overlapping windows preserve original
    /// cut-array precedence. Destination is supplied by the caller.
    private static func visitMapped(_ x: [Float], offset: Double, tm: TimeMap, n: Int,
                                    muteRamps: Bool, cancelled: (() -> Bool)?,
                                    emit: (Int, Float) -> Void) -> Bool {
        guard n > 0, cancelled?() != true else { return false }
        let fs = AudioIO.fs, spms = Int(fs / 1000), half = Int(0.020 * fs)
        let windows: [CutWindow] = tm.cuts.enumerated().compactMap { order, cut in
            guard cut.end > cut.start else { return nil }
            let t = tm.output(atSource: cut.end)
            guard t.isFinite, abs(t * fs) < Double(Int.max / 2) else { return nil }
            let center = Int(t * fs)
            return CutWindow(order: order, center: center, start: center - half, end: center + half,
                             pre: tm.source(atOutput: max(0, t - 0.001)),
                             post: tm.source(atOutput: t + 0.001))
        }.sorted { $0.start == $1.start ? $0.order < $1.order : $0.start < $1.start }
        var next = 0, active: [CutWindow] = []
        var prevS = tm.source(atOutput: 0), prevG = 1.0
        for k in 1...(n / spms + 1) {
            if k & 63 == 0, cancelled?() == true { return false }
            let block = (k - 1) * spms
            if block >= n { break }
            let t = Double(k) / 1000, s = tm.source(atOutput: t)
            let target = muteRamps && tm.speed(atOutput: t) > 1.2 ? 0.0 : 1.0
            let g = prevG + clamp(target - prevG, -0.1, 0.1)
            if !active.isEmpty { active.removeAll { $0.end <= block } }
            let firstNew = next
            while next < windows.count, windows[next].start < block + spms {
                if windows[next].end > block { active.append(windows[next]) }
                next += 1
            }
            if next != firstNew && active.count > 1 { active.sort { $0.order < $1.order } }
            for j in 0..<min(spms, n - block) {
                let i = block + j
                let u = Double(j) / Double(spms)
                let ss = (prevS + (s - prevS) * u - offset) * fs
                let gg = prevG + (g - prevG) * u
                if let cut = active.first(where: { i >= $0.start && i < $0.end }) {
                    let w = Float(i - cut.start) / Float(half * 2)
                    let advance = Double(i - cut.center) / fs
                    let pre = (cut.pre + advance - offset) * fs
                    let post = (cut.post + advance - offset) * fs
                    func sample(_ pos: Double) -> Float {
                        guard pos >= 0, pos < Double(x.count - 1) else { return 0 }
                        return cubic(x, pos)
                    }
                    let mix = Float(gg) * (sample(pre) * sqrtf(1 - w) + sample(post) * sqrtf(w))
                    if abs(mix) > 0.00001 { emit(i, mix) }
                    continue
                }
                if gg > 0.001, ss >= 0, ss < Double(x.count - 1) {
                    emit(i, cubic(x, ss) * Float(gg))
                }
            }
            prevS = s; prevG = g
        }
        return cancelled?() != true
    }

    static func mapped(_ x: [Float], offset: Double, tm: TimeMap, n: Int, muteRamps: Bool) -> [Float] {
        guard n > 0 else { return [] }
        var y = [Float](repeating: 0, count: n)
        _ = visitMapped(x, offset: offset, tm: tm, n: n, muteRamps: muteRamps, cancelled: nil) {
            y[$0] = $1
        }
        return y
    }

    /// Accumulate mono into both output channels, eliminating a full-duration
    /// intermediate buffer and retaining the same float operation order.
    static func addMappedMono(_ x: [Float], offset: Double, tm: TimeMap,
                              muteRamps: Bool, gain: Float, left: inout [Float],
                              right: inout [Float], cancelled: (() -> Bool)?) -> Bool {
        visitMapped(x, offset: offset, tm: tm, n: min(left.count, right.count),
                    muteRamps: muteRamps, cancelled: cancelled) { i, sample in
            left[i] += sample * gain; right[i] += sample * gain
        }
    }

    static func addMappedChannel(_ x: [Float], offset: Double, tm: TimeMap,
                                 muteRamps: Bool, gain: Float, output: inout [Float],
                                 cancelled: (() -> Bool)?) -> Bool {
        visitMapped(x, offset: offset, tm: tm, n: output.count,
                    muteRamps: muteRamps, cancelled: cancelled) { i, sample in
            output[i] += sample * gain
        }
    }
}
