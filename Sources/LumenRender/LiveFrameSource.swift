import Foundation
import CoreVideo
import Metal

/// Latest capture frame, shared between the capture queue and renderer.
public final class LiveFrameSource: @unchecked Sendable {
    private let cache: CVMetalTextureCache
    private let lock = NSLock()
    private var pb: CVPixelBuffer?, id: UInt64 = 0, cached: SourceFrame?

    public init?(device: MTLDevice) {
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
        guard let c else { return nil }
        cache = c
    }
    public func submit(_ b: CVPixelBuffer) {
        lock.lock(); pb = b; id &+= 1; cached = nil; lock.unlock()
    }
    public func current() -> SourceFrame? {
        lock.lock(); defer { lock.unlock() }
        if let f = cached { return f }
        guard let b = pb else { return nil }
        var cv: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, b, nil, .bgra8Unorm, CVPixelBufferGetWidth(b),
                                                        CVPixelBufferGetHeight(b), 0, &cv) == kCVReturnSuccess,
              let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        let f = SourceFrame(id: id, pts: 0, pixelBuffer: b, texture: tex, cv: cv)
        cached = f
        return f
    }
}
