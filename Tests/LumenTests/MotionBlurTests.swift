import Foundation
import Testing
import Metal
import CoreVideo
@testable import LumenRender
import LumenProject
import LumenDirector
import LumenCore

private func blurFrame(device: MTLDevice) -> SourceFrame {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferMetalCompatibilityKey as String: true,
                 kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
    CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, attrs, &pb)
    let buffer = pb!
    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    var cv: CVMetalTexture?
    CVMetalTextureCacheCreateTextureFromImage(nil, cache!, buffer, nil, .bgra8Unorm, 1920, 1080, 0, &cv)
    return SourceFrame(id: 1, pts: 0, pixelBuffer: buffer, texture: CVMetalTextureGetTexture(cv!)!, cv: cv!)
}

@Test func motionBlurAccumulatesSubframesUnderMotionOnly() throws {
    let renderer = try Renderer()
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 4, backingScale: 1, originX: 0, originY: 0)
    // Fast pan: cursor sweeps the screen in 0.5s around t=2.
    let events = (0...20).map { i -> InputEvent in
        InputEvent(t: 1.75 + Double(i) * 0.025, kind: .move, x: Float(100 + i * 85), y: 540)
    }
    var tl = Timeline(duration: 4)
    tl.audio.speedRampsAuto = false
    tl.camera.shutter = 0.5
    tl.camera.maxSamples = 8
    tl = Director.derive(tl, input: DirectorInput(events: events, source: src), revision: 1)
    let frame = blurFrame(device: renderer.device)
    let g = Geometry(canvas: SIMD2(1920, 1080), src: SIMD2(1920, 1080), style: tl.style)
    func count(at t: Double, shutter: Double) -> Int {
        var copy = tl
        copy.camera.shutter = shutter
        let req = RenderRequest(timeline: copy, t: t, screen: frame, canvas: SIMD2(1920, 1080), fps: 60)
        return renderer.sampleCount(req, g)
    }
    #expect(count(at: 2.0, shutter: 0.5) > 1, "fast pan must accumulate sub-frames")
    #expect(count(at: 0.2, shutter: 0.5) == 1, "static scene must cost one sample")
    #expect(count(at: 2.0, shutter: 0) == 1, "shutter off must disable accumulation")
}
