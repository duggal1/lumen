import Foundation
import Metal
import CoreVideo
import QuartzCore
import os
import LumenCore
import LumenProject
import LumenDirector

// MARK: - Budget

/// Converts frame timings into a pass/fail gate. Pure, so CI can test the
/// policy without a GPU while the real harness supplies live samples.
public struct FrameBudget: Sendable, Equatable {
    public var fps: Double
    /// Tolerance over the vsync interval before a frame counts as dropped.
    /// 5% absorbs clock quantisation without hiding a real budget violation.
    public var latencyAllowance: Double
    /// Fraction of frames allowed to miss the deadline (startup/warm-up slack).
    public var allowedOverBudgetFraction: Double

    public init(fps: Double = 60, latencyAllowance: Double = 1.05, allowedOverBudgetFraction: Double = 0.02) {
        self.fps = max(fps, 1)
        self.latencyAllowance = max(latencyAllowance, 1)
        self.allowedOverBudgetFraction = min(max(allowedOverBudgetFraction, 0), 1)
    }

    public var budgetMilliseconds: Double { 1000 / fps }

    public func evaluate(_ samples: [Double], clickScenario: Bool = false) -> FrameBudgetReport {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return FrameBudgetReport(frames: 0, averageMs: 0, p95Ms: 0, p99Ms: 0, worstMs: 0,
                                     overBudget: 0, passes: false, summary: "no frames measured")
        }
        let sorted = samples.sorted()
        let n = sorted.count
        let average = samples.reduce(0, +) / Double(n)
        let p95 = sorted[min(n - 1, Int(Double(n - 1) * 0.95))]
        let p99 = sorted[min(n - 1, Int(Double(n - 1) * 0.99))]
        let worst = sorted[n - 1]
        let deadline = clickScenario ? budgetMilliseconds : budgetMilliseconds * latencyAllowance
        let over = samples.filter { $0 > deadline }.count
        let passes = clickScenario
            ? p99 < 16.6 && worst <= 33 && over == 0
            : p99 <= deadline && Double(over) / Double(n) <= allowedOverBudgetFraction
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
                           fps: Double = 60, motionBlur: Bool = false, clicks: Bool = false,
                           upscale: Bool = true, blur: Bool = true) throws -> RenderBenchmarkResult {
        let count = max(frames, 1)
        let w = max(width, 16), h = max(height, 16)
        let renderer = try Renderer()

        var timeline = Timeline(duration: Double(count) / max(fps, 1) + 1)
        timeline.audio.speedRampsAuto = false
        timeline.camera.upscaleEnabled = upscale
        if !blur { timeline.camera.shutter = 0 }
        if motionBlur { timeline.camera.maxSamples = max(timeline.camera.maxSamples, 4) }
        if clicks {
            let events = stride(from: 60, to: count, by: 120).enumerated().map { index, frame in
                InputEvent(t: Double(frame) / fps, kind: .down,
                           x: Float(w) * (index.isMultiple(of: 2) ? 0.28 : 0.72),
                           y: Float(h) * (index.isMultiple(of: 2) ? 0.35 : 0.65), button: 0)
            }
            let source = SourceInfo(width: w, height: h, fps: fps, duration: timeline.compositionDuration,
                                    backingScale: 1, originX: 0, originY: 0)
            timeline = Director.derive(timeline, input: DirectorInput(events: events, source: source), revision: 1)
        }

        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        let screen = try syntheticFrame(device: device, width: w, height: h)
        guard let output = makeBuffer(w, h) else { throw RenderError.noDevice }

        let budget = FrameBudget(fps: fps)
        var samples: [Double] = []
        samples.reserveCapacity(count)

        // Warm up across the whole timeline, not just t=0: zoom-specific
        // pipelines, upscaler textures and mip levels are created lazily on
        // first use. A single static warm-up lets those allocations land in
        // the measured frames and masquerade as click-time freezes.
        var warmTimes: [Double] = []
        for warm in 0..<24 {
            warmTimes.append(min(Double(warm) / 24.0 * timeline.compositionDuration,
                                 timeline.compositionDuration))
        }
        if clicks {
            // Each click starts an eased zoom. Exercise the whole transition,
            // not just the settled endpoints, so every quantized upscaler crop
            // and mip level is allocated before the measured loop begins.
            for frame in stride(from: 60, to: count, by: 120) {
                for offset in [-0.10, -0.04, 0.0, 0.06, 0.16, 0.32, 0.6, 1.0] {
                    let t = Double(frame) / max(fps, 1) + offset
                    if t >= 0, t <= timeline.compositionDuration { warmTimes.append(t) }
                }
            }
        }
        for t in warmTimes {
            try render(renderer: renderer, timeline: timeline, screen: screen, output: output,
                       t: t, canvas: SIMD2(w, h), fps: fps)
        }

        let log = OSLog(subsystem: "com.lumen.studio", category: "render-benchmark")
        var worstFrame = -1
        var worstMs = -1.0
        for i in 0..<count {
            if clicks, i % 120 == 60 { os_signpost(.event, log: log, name: "Click", "%d", i) }
            let start = CACurrentMediaTime()
            try render(renderer: renderer, timeline: timeline, screen: screen, output: output,
                           t: min(Double(i) / max(fps, 1), timeline.compositionDuration),
                           canvas: SIMD2(w, h), fps: fps)
            let ms = (CACurrentMediaTime() - start) * 1000
            if ms > worstMs { worstMs = ms; worstFrame = i }
            samples.append(ms)
        }
        if clicks {
            print("BENCH-WORST frame=\(worstFrame) ms=\(String(format: "%.2f", worstMs)) sinceClick=\(worstFrame % 120)")
        }
        return RenderBenchmarkResult(width: w, height: h, frames: count, fps: fps,
                                     report: budget.evaluate(samples, clickScenario: clicks))
    }

    private static func render(renderer: Renderer, timeline: Timeline, screen: SourceFrame,
                               output: CVPixelBuffer, t: Double, canvas: SIMD2<Int>, fps: Double) throws {
        // P2 is a PLAYBACK requirement: live preview uses .preview quality,
        // which caps motion-blur sub-frames to the frame budget. .export can
        // legitimately spend 12 passes per moving frame and is not the 60 fps
        // path the gate is about.
        let request = RenderRequest(timeline: timeline, t: t, screen: screen, canvas: canvas, fps: fps,
                                    backingScale: 1, quality: .preview)
        let latch = DispatchSemaphore(value: 0)
        guard renderer.render(request, into: output, completion: { latch.signal() }) else {
            throw RenderError.pipeline("frame rejected at \(t) s")
        }
        guard latch.wait(timeout: .now() + 30) == .success else { throw RenderError.pipeline("frame timeout") }
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

