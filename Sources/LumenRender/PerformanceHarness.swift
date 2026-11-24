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
        // A corrupt clock sample must fail the gate, never be silently folded
        // into a percentile where NaN can sort to the front and "pass".
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            return FrameBudgetReport(frames: 0, averageMs: 0, p50Ms: 0, p95Ms: 0, p99Ms: 0, worstMs: 0,
                                     overBudget: 0, passes: false, summary: "no valid frames measured")
        }
        let sorted = samples.sorted()
        let n = sorted.count
        let average = samples.reduce(0, +) / Double(n)
        let p50 = sorted[n / 2]
        let p95 = sorted[min(n - 1, Int(Double(n - 1) * 0.95))]
        let p99 = sorted[min(n - 1, Int(Double(n - 1) * 0.99))]
        let worst = sorted[n - 1]
        let deadline = clickScenario ? budgetMilliseconds : budgetMilliseconds * latencyAllowance
        let over = samples.filter { $0 > deadline }.count
        // A click must land within one vsync with no outlier at all; steady
        // playback tolerates the configured fraction of late frames.
        let passes = clickScenario
            ? p99 < 16.6 && worst <= 33 && over == 0
            : p99 <= deadline && Double(over) / Double(n) <= allowedOverBudgetFraction
        let summary = String(format: "%d frames · avg %.2f ms · p50 %.2f · p95 %.2f · p99 %.2f · worst %.2f · over %d/%d · %@",
                             n, average, p50, p95, p99, worst, over, n, passes ? "pass" : "FAIL")
        return FrameBudgetReport(frames: n, averageMs: average, p50Ms: p50, p95Ms: p95, p99Ms: p99, worstMs: worst,
                                 overBudget: over, passes: passes, summary: summary)
    }
}

public struct FrameBudgetReport: Sendable, Equatable {
    public var frames: Int
    public var averageMs: Double
    public var p50Ms: Double
    public var p95Ms: Double
    public var p99Ms: Double
    public var worstMs: Double
    public var overBudget: Int
    public var passes: Bool
    public var summary: String
}

// MARK: - Adaptive preview quality

/// Preview-only quality governor. Export never scales — exported frames are
/// always full resolution with deterministic cadence — but live preview must
/// never drop a frame. When the GPU misses the vsync deadline the render scale
/// steps down until it fits, and climbs back only after sustained headroom.
/// Pure and deterministic so the policy is unit-testable without a GPU; the
/// preview owner wires `level.renderScale` / `level.sampleBudget` into the
/// `RenderRequest` and the resulting canvas via `scaled(canvas:)`.
public struct AdaptiveQualityController: Sendable, Equatable {
    public enum Level: Int, Sendable, CaseIterable, Comparable {
        case low = 0, medium, high, full

        /// Fraction of the native canvas rendered at this level.
        public var renderScale: Double {
            switch self {
            case .low: return 0.55
            case .medium: return 0.70
            case .high: return 0.85
            case .full: return 1.0
            }
        }
        /// Motion-blur sub-frame budget at this level (1 = no blur).
        public var sampleBudget: Int {
            switch self {
            case .low: return 1
            case .medium: return 2
            case .high: return 3
            case .full: return 4
            }
        }
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public var level: Level
    public var fps: Double
    /// Consecutive over-deadline frames before stepping down (~0.2s at 60fps).
    public var downFrames: Int
    /// Consecutive comfortable frames before stepping up (~2s at 60fps).
    /// The asymmetry is deliberate: degrade fast, recover slowly, never flap.
    public var upFrames: Int
    private var slow: Int
    private var fast: Int

    public init(fps: Double = 60, level: Level = .full, downFrames: Int = 12, upFrames: Int = 120) {
        self.fps = max(fps, 1)
        self.level = level
        self.downFrames = max(downFrames, 1)
        self.upFrames = max(upFrames, 1)
        self.slow = 0; self.fast = 0
    }

    /// Feeds one measured frame time in milliseconds and returns the current
    /// level. Non-finite or non-positive samples are ignored — a corrupt clock
    /// must never degrade a healthy preview or, worse, mask a slow one.
    @discardableResult
    public mutating func sample(frameTimeMs ms: Double) -> Level {
        guard ms.isFinite, ms > 0 else { return level }
        let deadline = 1000 / max(fps, 1)
        if ms > deadline * 1.05 {
            slow += 1; fast = 0
        } else if ms < deadline * 0.65 {
            fast += 1; slow = 0
        } else {
            slow = 0; fast = 0
        }
        if slow >= downFrames, level > .low {
            level = Level(rawValue: level.rawValue - 1) ?? .low
            slow = 0; fast = 0
        } else if fast >= upFrames, level < .full {
            level = Level(rawValue: level.rawValue + 1) ?? .full
            slow = 0; fast = 0
        }
        return level
    }

    /// Native canvas scaled to the current level, snapped to even pixels so
    /// YCbCr subsampling and the Metal blit stay aligned.
    public func scaled(canvas: SIMD2<Int>) -> SIMD2<Int> {
        let s = level.renderScale
        func dim(_ v: Int) -> Int { max(16, (Int((Double(v) * s).rounded()) + 1) & ~1) }
        return SIMD2(dim(canvas.x), dim(canvas.y))
    }

    /// Restores full quality with no history — call when the source or canvas
    /// changes so an old stall cannot linger into a new clip.
    public mutating func reset() { slow = 0; fast = 0; level = .full }
}

// MARK: - Live harness

public struct RenderBenchmarkResult: Sendable, Equatable {
    public var width: Int, height: Int, frames: Int, fps: Double
    public var report: FrameBudgetReport
}

/// Renders synthetic frames through the real Metal pipeline and waits for GPU
/// completion. Defaults to `.preview` quality — that is the path that must hold
/// 60 fps interactively; `.export` (up to 12 motion-blur subframes) is measured
/// separately by `ExportBenchmark`, which gates throughput, not frame latency.
/// Run manually from `lumen-cli bench`.
public enum RenderBenchmark {
    public static func run(frames: Int = 120, width: Int = 1920, height: Int = 1080,
                           fps: Double = 60, motionBlur: Bool = false,
                           quality: RenderQuality = .preview) throws -> RenderBenchmarkResult {
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

        // Warm up the pipeline, caches and GPU scheduler. One frame is not
        // enough: the first few 4K resolves can incur lazy texture allocation,
        // which is startup cost, not steady-state frame latency.
        for k in 0..<min(8, count) {
            _ = try render(renderer: renderer, timeline: timeline, screen: screen, output: output,
                           t: 0, canvas: SIMD2(w, h), fps: fps, quality: quality)
        }

        for i in 0..<count {
            let start = CACurrentMediaTime()
            _ = try render(renderer: renderer, timeline: timeline, screen: screen, output: output,
                           t: min(Double(i) / max(fps, 1), timeline.compositionDuration),
                           canvas: SIMD2(w, h), fps: fps, quality: quality)
            samples.append((CACurrentMediaTime() - start) * 1000)
        }
        return RenderBenchmarkResult(width: w, height: h, frames: count, fps: fps,
                                     report: budget.evaluate(samples))
    }

    private static func render(renderer: Renderer, timeline: Timeline, screen: SourceFrame,
                               output: CVPixelBuffer, t: Double, canvas: SIMD2<Int>, fps: Double,
                               quality: RenderQuality) throws -> Bool {
        let request = RenderRequest(timeline: timeline, t: t, screen: screen, canvas: canvas, fps: fps,
                                    backingScale: 1, quality: quality)
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

