import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import os

public enum ActivityError: Error, LocalizedError, Sendable {
    case noVideoTrack
    case metal(String)
    case readFailed
    case readerConfiguration
    case readerStart

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "No video track is available for activity analysis."
        case .metal(let detail): "Activity analysis Metal setup failed: \(detail)."
        case .readFailed: "Activity analysis could not decode the recording."
        case .readerConfiguration: "Activity analysis reader could not be configured."
        case .readerStart: "Activity analysis reader could not start."
        }
    }
}

/// GPU activity analyzer. Owns its Metal objects and must be used from ONE task
/// at a time; `analyze` hops to a detached utility task and blocks only there.
/// Created per analysis, cancellable, and never touches the UI or event tap.
public final class ActivityAnalyzer: @unchecked Sendable {
    public static let analyzerID = "activity"
    public static let analyzerVersion = 1

    static let lumaW = 192, lumaH = 108
    static let gridW = 48, gridH = 27

    private let queue: MTLCommandQueue
    private let lumaPSO: MTLComputePipelineState
    private let diffPSO: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private let ring: [MTLTexture]
    private let out: MTLBuffer
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)

    public init() throws {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue(),
              let lib = dev.makeDefaultLibrary(bundle: .module) ?? dev.makeDefaultLibrary(),
              let f1 = lib.makeFunction(name: "lumen_luma_down"),
              let f2 = lib.makeFunction(name: "lumen_activity_diff"),
              let p1 = try? dev.makeComputePipelineState(function: f1),
              let p2 = try? dev.makeComputePipelineState(function: f2)
        else { throw ActivityError.metal("device/library/pipelines — add Shaders resource to LumenAnalysis") }

        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, dev, nil, &textureCache) == kCVReturnSuccess,
              let textureCache else { throw ActivityError.metal("texture cache") }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: Self.lumaW, height: Self.lumaH, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let textures = (0..<5).compactMap { _ in dev.makeTexture(descriptor: descriptor) }
        guard textures.count == 5,
              let buffer = dev.makeBuffer(length: Self.gridW * Self.gridH,
                                          options: .storageModeShared)
        else { throw ActivityError.metal("resources") }

        queue = q; lumaPSO = p1; diffPSO = p2; cache = textureCache
        ring = textures; out = buffer
    }

    /// Cancels decoding and GPU submission. Safe to call from any task.
    public func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
    }

    /// Sample-and-hold at `hz`: each sample time uses the newest frame with
    /// pts <= t. Idle stretches yield zero-energy grids. Runs for every screen
    /// (desktop) recording; callers do filtering, not this analyzer.
    public func analyze(screen url: URL, hz: Double = 10,
                        cancelled check: @escaping @Sendable () -> Bool = { false }) async throws -> ActivityCache {
        let signpost = OSLog(subsystem: "app.lumen", category: "activity")
        os_signpost(.begin, log: signpost, name: "activity.analyze")
        defer { os_signpost(.end, log: signpost, name: "activity.analyze") }
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try await self.run(url: url, hz: hz, externalCancel: check)
            }.value
        } onCancel: { self.cancel() }
    }

    private var isCancelled: Bool { cancelled.withLock { $0 } }

    private func run(url: URL, hz: Double, externalCancel: @Sendable () -> Bool) async throws -> ActivityCache {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ActivityError.noVideoTrack
        }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        readerLock.withLock { $0 = ReaderHandle(reader) }
        defer { readerLock.withLock { $0 = nil } }
        guard !isCancelled, !externalCancel() else {
            reader.cancelReading(); throw CancellationError()
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ActivityError.readerConfiguration }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ActivityError.readerStart }

        let dt = 1.0 / max(hz, 1)
        var grids: [ActivityGridPayload] = []
        var next = 0.0, head = 0
        var seeded = false
        var pending: CVPixelBuffer?
        var size = (0, 0)

        while let sample = output.copyNextSampleBuffer() {
            guard !isCancelled, !externalCancel() else {
                reader.cancelReading(); throw CancellationError()
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            while next < pts - 1e-6 {
                if let held = pending {
                    grids.append(try grid(held, t: next, seeded: &seeded, head: &head))
                }
                next += dt
            }
            pending = buffer
            size = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        }
        while next <= duration, let held = pending {
            grids.append(try grid(held, t: next, seeded: &seeded, head: &head))
            next += dt
        }
        if reader.status == .failed { throw reader.error ?? ActivityError.readFailed }
        return ActivityCache(grids: grids, width: size.0, height: size.1)
    }

    /// Downsampling + two-lag max-absolute-difference, all on the GPU.
    private func grid(_ buffer: CVPixelBuffer, t: Double,
                      seeded: inout Bool, head: inout Int) throws -> ActivityGridPayload {
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture
        ) == kCVReturnSuccess,
              let cvTexture,
              let source = CVMetalTextureGetTexture(cvTexture),
              let commandBuffer = queue.makeCommandBuffer()
        else { throw ActivityError.metal("frame texture") }

        func luma(into destination: MTLTexture) {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(lumaPSO)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.dispatchThreads(MTLSize(width: Self.lumaW, height: Self.lumaH, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
            encoder.endEncoding()
        }

        if !seeded {
            for texture in ring { luma(into: texture) }
            seeded = true
        } else { luma(into: ring[head % ring.count]) }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(diffPSO)
            encoder.setTexture(ring[head % ring.count], index: 0)
            encoder.setTexture(ring[(head + ring.count - 1) % ring.count], index: 1)
            encoder.setTexture(ring[(head + 1) % ring.count], index: 2)
            encoder.setBuffer(out, offset: 0, index: 0)
            encoder.dispatchThreads(MTLSize(width: Self.gridW, height: Self.gridH, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 9, depth: 1))
            encoder.endEncoding()
        }
        head += 1
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let cells = Array(UnsafeBufferPointer(
            start: out.contents().assumingMemoryBound(to: UInt8.self),
            count: Self.gridW * Self.gridH))
        withExtendedLifetime(cvTexture) {}
        return ActivityGridPayload(t: t, cells: cells)
    }
}
