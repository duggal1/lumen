import Foundation
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector
@testable import LumenRender

/// A1 / R5 — sharp zoom. The shader is checked at the source (a GPU kernel has
/// no unit-test harness here): the loupe must crop-sample the full-resolution
/// source with the 5-tap Catmull kernel, never a bilinear upscale.
private enum A1Sharp {
    static func shader(_ name: String) -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("Sources/LumenRender/Shaders/\(name)")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) { return text }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("shader \(name) not found from \(#filePath)")
        return ""
    }
}

// R5.1 — the loupe resamples the source lattice at level 0 with Catmull5.
@Test func a1LoupeUsesCatmullFromFullResolutionSource() {
    let src = A1Sharp.shader("Shaders.metal")
    #expect(!src.isEmpty, "shader source unavailable")
    guard let start = src.range(of: "fragment float4 loupeFS") else {
        Issue.record("loupeFS not found"); return
    }
    let tail = src[start.lowerBound...]
    // Only this function's body: later shaders also use linClamp legitimately.
    let end = tail.range(of: "struct SourceMask")?.lowerBound ?? tail.endIndex
    let body = String(tail[..<end])
    #expect(body.contains("catmull5("), "loupe must use the 5-tap Catmull kernel")
    #expect(!body.contains("src.sample(linClamp"), "loupe still uses a bilinear upscale")
    #expect(body.contains("catmull5(src,"), "loupe must sample the full-resolution source")
}

// R5.2 — the source->canvas->source round trip is subpixel accurate, including
// off-centre camera results where a sloppy transform drifts most.
@Test func a1ZoomTransformRoundTripSubpixel() {
    let source = SIMD2<Double>(3840, 2160)
    let style = Timeline(duration: 4).style
    var worst = 0.0
    for scale in [1.0, 1.5, 2.0, 3.2] {
        for center in [SIMD2<Double>(1920, 1080), SIMD2<Double>(600, 400), SIMD2<Double>(3300, 1800)] {
            let t = ZoomTransform(canvas: SIMD2(1920, 1080), source: source, style: style,
                                  cameraCenter: center, scale: scale)
            let half = source / (2 * scale)
            let clamped = ZoomTransform.clamp(center, source: source, scale: scale)
            #expect(abs(clamped.x - center.x) < 0.5 || center.x < half.x || center.x > source.x - half.x)
            for f in [SIMD2<Double>(-0.3, -0.2), SIMD2<Double>(0.1, 0.35), SIMD2<Double>(0.42, -0.41)] {
                let p = clamped + f * half
                let back = t.canvasToSource(t.sourceToCanvas(p))
                worst = max(worst, abs(back.x - p.x), abs(back.y - p.y))
            }
        }
    }
    print("A1 zoom roundtrip worst=\(worst)px")
    #expect(worst < 0.5, "round trip drift \(worst)px")
}

// R5.3 — the upscaler reports the rung it actually applies; no fake factor,
// no blend below 1:1, no diluted blend above the engagement ramp.
@Test func a1UpscalerFactorAndBlendAreHonest() {
    #expect(Upscaler.factor(forMagnification: 1.1, maxFactor: 8) == 2)
    #expect(Upscaler.factor(forMagnification: 2.5, maxFactor: 8) == 3)
    #expect(Upscaler.factor(forMagnification: 3.2, maxFactor: 8) == 4)
    #expect(Upscaler.factor(forMagnification: 7.9, maxFactor: 8) == 8)
    #expect(Upscaler.factor(forMagnification: 9, maxFactor: 4) == 4, "cap ignored")
    #expect(Upscaler.factor(forMagnification: .nan, maxFactor: 8) == 8, "NaN must not make a fake rung")
    #expect(Upscaler.factor(forMagnification: -4, maxFactor: 8) == 2, "negative must clamp to real rung")
    var params = UpscaleParams()
    #expect(Upscaler.blend(forMagnification: 1.0, params) == 0, "blend below 1:1")
    #expect(Upscaler.blend(forMagnification: 2.5, params) == 1, "blend not fully applied on real upscale")
    params.enabled = false
    #expect(Upscaler.blend(forMagnification: 2.5, params) == 0, "blend with upscaler disabled")
    // Each rung must decompose into real integer stages (product = factor).
    for f in Upscaler.stages(10) { #expect(f >= 2) }
    #expect(Upscaler.stages(10).reduce(1, *) == 10)
    #expect(Upscaler.stages(8).reduce(1, *) == 8)
}

// R5.4 — the live camera never frames outside the recorded source, even at a
// corner click while fully zoomed.
@Test func a1LiveCameraZoomedCenterInsideFrame() {
    var cam = LiveCamera(source: SIMD2(3840, 2160))
    cam.maxScale = 3
    _ = cam.step(to: 1)
    let spots = [SIMD2<Float>(10, 10), SIMD2<Float>(3830, 2150), SIMD2<Float>(1920, 1080)]
    for (i, p) in spots.enumerated() {
        var c = cam
        c.ingest(InputEvent(t: 1 + Double(i) * 3, kind: .down, x: p.x, y: p.y))
        let f = c.step(to: 1 + Double(i) * 3 + 0.5)
        let s = Double(f.cameraScale), half = SIMD2<Double>(1920 / s, 1080 / s)
        #expect(Double(f.cameraCenter.x) >= half.x - 0.01)
        #expect(Double(f.cameraCenter.x) <= 3840 - half.x + 0.01)
        #expect(Double(f.cameraCenter.y) >= half.y - 0.01)
        #expect(Double(f.cameraCenter.y) <= 2160 - half.y + 0.01)
    }
}
