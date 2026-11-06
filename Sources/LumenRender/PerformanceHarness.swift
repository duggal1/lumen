import Foundation
import Metal
import CoreVideo
import QuartzCore
import LumenCore
import LumenProject

// MARK: - Budget

/// Converts frame timings into a pass/fail gate. Pure, so CI can test the
/// policy without a GPU while the real harness supplies live samples.
public struct FrameBudget: Sendable, Equatable {
    public var fps: Double
    /// A frame may take this much longer than the vsync interval before it counts as dropped.
    public var latencyAllowance: Double
    /// Fraction of frames allowed to miss the deadline (startup/warm-up slack).
    public var allowedOverBudgetFraction: Double

    public init(fps: Double = 60, latencyAllowance: Double = 1.25, allowedOverBudgetFraction: Double = 0.02) {
        self.fps = max(fps, 1)
        self.latencyAllowance = max(latencyAllowance, 1)
        self.allowedOverBudgetFraction = min(max(allowedOverBudgetFraction, 0), 1)
    }

    public var budgetMilliseconds: Double { 1000 / fps }

    public func evaluate(_ samples: [Double]) -> FrameBudgetReport {
        guard !samples.isEmpty else {
            return FrameBudgetReport(frames: 0, averageMs: 0, p95Ms: 0, p99Ms: 0, worstMs: 0,
                                     overBudget: 0, passes: false, summary: "no frames measured")
        }
        let sorted = samples.sorted()
        let n = sorted.count
        let average = samples.reduce(0, +) / Double(n)
        let p95 = sorted[min(n - 1, Int(Double(n - 1) * 0.95))]
        let p99 = sorted[min(n - 1, Int(Double(n - 1) * 0.99))]
        let worst = sorted[n - 1]
        let deadline = budgetMilliseconds * latencyAllowance
        let over = samples.filter { $0 > deadline }.count
        let passes = p99 <= deadline && Double(over) / Double(n) <= allowedOverBudgetFraction
        let summary = String(format: "%d frames · avg %.2f ms · p95 %.2f · p99 %.2f · worst %.2f · over %d/%d · %@",
                             n, average, p95, p99, worst, over, n, passes ? "pass" : "FAIL")
        return FrameBudgetReport(frames: n, averageMs: average, p95Ms: p95, p99Ms: p99, worstMs: worst,
                                 overBudget: over, passes: passes, summary: summary)
    }
}

public struct FrameBudgetReport: Sendable, Equatable {
    public var frames: Int
    public var averageMs: Double
    public var p95Ms: Double
    public var p99Ms: Double
    public var worstMs: Double
    public var overBudget: Int
    public var passes: Bool
    public var summary: String
}

// MARK: - Live harness

public struct RenderBenchmarkResult: Sendable, Equatable {
    public var width: Int, height: Int, frames: Int, fps: Double
    public var report: FrameBudgetReport
}

/// Renders synthetic frames through the real Metal pipeline and waits for GPU
/// completion, so the numbers include the work an export actually does.
/// Run manually from `lumen-cli bench`; unit tests use a tiny canvas only as a
/// smoke check.
public enum RenderBenchmark {
    public static func run(frames: Int = 120, width: Int = 1920, height: Int = 1080,
                           fps: Double = 60, motionBlur: Bool = false) throws -> RenderBenchmarkResult {
        let count = max(frames, 1)
        let w = max(width, 16), h = max(height, 16)
        let renderer = try Renderer()

        var timeline = Timeline(duration: Double(count) / max(fps, 1) + 1)
        timeline.audio.speedRampsAuto = false
        if motionBlur { timeline.camera.maxSamples = max(timeline.camera.maxSamples, 4) }

        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        let screen = try syntheticFrame(device: device, width: w, height: h)
        guard let output = makeBuffer(w, h) else { throw RenderError.noDevice }

        let budget = FrameBudget(fps: fps)
        var samples: [Double] = []
        samples.reserveCapacity(count)

        // One warm-up frame keeps shader/pipeline creation out of the numbers.
        _ = try render(renderer: renderer, timeline: timeline, screen: screen, output: output,
                       t: 0, canvas: SIMD2(w, h), fps: fps)

        for i in 0..<count {
            let start = CACurrentMediaTime()
            _ = try render(renderer: renderer, timeline: timeline, screen: screen, output: output,
                           t: min(Double(i) / max(fps, 1), timeline.compositionDuration),
                           canvas: SIMD2(w, h), fps: fps)
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        return RenderBenchmarkResult(width: w, height: h, frames: count, fps: fps,
                                     report: budget.evaluate(samples))
    }

    private static func render(renderer: Renderer, timeline: Timeline, screen: SourceFrame,
                               output: CVPixelBuffer, t: Double, canvas: SIMD2<Int>, fps: Double) throws -> Bool {
        let request = RenderRequest(timeline: timeline, t: t, screen: screen, canvas: canvas, fps: fps,
                                    backingScale: 1, quality: .export)
        let latch = DispatchSemaphore(value: 0)
        guard renderer.render(request, into: output, completion: { latch.signal() }) else { return false }
        guard latch.wait(timeout: .now() + 30) == .success else { throw RenderError.pipeline("frame timeout") }
        return true
    }

    private static func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferMetalCompatibilityKey: true,
                             kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &pb)
        return pb
    }

    private static func syntheticFrame(device: MTLDevice, width: Int, height: Int) throws -> SourceFrame {
        guard let pb = makeBuffer(width, height) else { throw RenderError.noDevice }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let row = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let p = row.advanced(by: y * stride)
                for x in 0..<width {
                    p[x * 4 + 0] = UInt8((x &* 3) & 0xFF)
                    p[x * 4 + 1] = UInt8((y &* 2) & 0xFF)
                    p[x * 4 + 2] = UInt8(((x + y) &* 1) & 0xFF)
                    p[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { throw RenderError.noDevice }
        var cv: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                        width, height, 0, &cv) == kCVReturnSuccess,
              let cv, let texture = CVMetalTextureGetTexture(cv) else { throw RenderError.noDevice }
        return SourceFrame(id: 1, pts: 0, pixelBuffer: pb, texture: texture, cv: cv)
    }
}

