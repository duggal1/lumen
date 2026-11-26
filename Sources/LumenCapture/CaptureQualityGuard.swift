import Foundation

/// Measures actual accepted writer frames, not configured FPS or duplicated
/// frames. ScreenCaptureKit may suppress unchanged frames, so low cadence alone
/// is not evidence of overload; dropped writer frames or thermal pressure are.
public struct CaptureQualityGuard: Sendable {
    public enum Result: Equatable, Sendable { case nominal, belowRequestedFormat, shedOptionalWork }
    private var baseline: CaptureStats?
    private var badWindows = 0
    public init() {}

    public mutating func observe(_ sample: CaptureStats, paused: Bool) -> Result {
        if paused { baseline = nil; badWindows = 0; return .nominal }
        guard sample.configuredFPS > 0, sample.width > 0, sample.height > 0,
              sample.elapsed.isFinite else { return .nominal }
        if sample.configuredFPS < 50 || max(sample.width, sample.height) < 3072 {
            return .belowRequestedFormat
        }
        guard let old = baseline else { baseline = sample; return .nominal }
        let elapsed = sample.elapsed - old.elapsed
        if elapsed < 0 || sample.written < old.written || sample.dropped < old.dropped {
            baseline = sample; badWindows = 0; return .nominal
        }
        guard elapsed >= 1 else { return .nominal }
        baseline = sample
        let accepted = Double(sample.written - old.written) / elapsed
        let drops = sample.dropped - old.dropped
        if (accepted < 50 && drops > 0) || sample.thermal >= 2 { badWindows += 1 }
        else { badWindows = 0 }
        return badWindows >= 2 ? .shedOptionalWork : .nominal
    }
}
