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
        lock.lock()
        if let f = cached { lock.unlock(); return f }
        guard let b = pb else { lock.unlock(); return nil }
        let idNow = id
        lock.unlock()
        // SMOOTHNESS/LAG: `CVMetalTextureCacheCreateTextureFromImage` is a
        // synchronous driver call. Building the texture OUTSIDE the lock means
        // the thread calling `current()` (the display link on main, or the
        // render thread) no longer waits behind the lock holder while the
        // driver creates the texture — the per-tick stall the user reported.
        var cv: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, b, nil, .bgra8Unorm, CVPixelBufferGetWidth(b),
                                                        CVPixelBufferGetHeight(b), 0, &cv) == kCVReturnSuccess,
              let cv, let tex = CVMetalTextureGetTexture(cv) else { return nil }
        let f = SourceFrame(id: idNow, pts: 0, pixelBuffer: b, texture: tex, cv: cv)
        lock.lock()
        if id == idNow { cached = f }   // a newer frame may have landed meanwhile; its own caller still gets a valid frame
        lock.unlock()
        return f
    }
}
