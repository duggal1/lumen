import Foundation
import LumenCore

public enum ClickEffect: String, Codable, CaseIterable, Sendable { case none, ripple, pulse, burst, glass }
// Glass click is rendered in the Metal ringFS path, not SwiftUI, so preview
// and export share the same pixels. There is no SwiftUI Liquid Glass toggle
// on the canvas; the translucent bloom is baked into the shader.

// NOTE: MotionBlurParams/LoopMode used to live here but were dead code
// (never read). Real motion-blur controls are CameraParams.shutter /
// maxSamples (Renderer.sampleCount) and CursorStyle.loop (CursorPipeline).

public struct UpscaleParams: Codable, Equatable, Sendable {
    public var enabled = true
    public var blendStart = 1.5, blendEnd = 2.2
    public var maxFactor = 10
    public var edgeSharpness = 0.85
    public var shock = 0.7
    public var shockIterations = 4
    public var finalSharpen = 0.6
    public init() {}
}
