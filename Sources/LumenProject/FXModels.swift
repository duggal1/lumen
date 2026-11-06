import Foundation
import LumenCore

public enum ClickEffect: String, Codable, CaseIterable, Sendable { case none, ripple, pulse, burst }

// NOTE: MotionBlurParams/LoopMode used to live here but were dead code
// (never read). Real motion-blur controls are CameraParams.shutter /
// maxSamples (Renderer.sampleCount) and CursorStyle.loop (CursorPipeline).

public struct UpscaleParams: Codable, Equatable, Sendable {
    public var enabled = true
    public var blendStart = 1.5, blendEnd = 2.2
    public var maxFactor = 8
    public var edgeSharpness = 0.6
    public var shock = 0.55
    public var shockIterations = 2
    public var finalSharpen = 0.35
    public init() {}
}
