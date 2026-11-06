import Foundation
import LumenCore

public enum ClickEffect: String, Codable, CaseIterable, Sendable { case none, ripple, pulse, burst }

public enum LoopMode: Codable, Equatable, Sendable { case off, cursorAndCamera(duration: Double) }

public struct MotionBlurParams: Codable, Equatable, Sendable {
    public var enabled = true
    public var shutter = 0.5
    public var maxSamples = 8
    public var previewSamples = 2
    public init() {}
}

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
