import Foundation

/// The QA gate is intent-aware. An absent optional signal is not a failure;
/// missing required evidence never passes.
enum AgentQualityPolicy {
    static func zoomPass(clicks: Int, zoomed: Int, centered: Int, settled: Int, automatic: Bool) -> Bool {
        guard automatic, clicks > 0 else { return true }
        return zoomed > 0 && centered == zoomed && settled == zoomed
    }

    static func audioPass(expected: Bool, measured: Bool, loudness: Double, truePeak: Double) -> (level: Bool, audible: Bool) {
        guard expected else { return (true, true) }
        guard measured, loudness.isFinite, truePeak.isFinite else { return (false, false) }
        return (loudness >= -24 && loudness <= -14 && truePeak <= -1, loudness > -70)
    }
}
