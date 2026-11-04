import Foundation
import AVFoundation
import CoreVideo
import os
import LumenProject

public enum ActivityAnalyzer {
    public static func analyze(url: URL, offset: Double = 0, fps: Double = 10) async throws -> [ActivityPoint] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let job = ActivityJob(asset: asset, track: track, offset: offset, fps: fps)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try job.run() }.value
        } onCancel: { job.cancel() }
    }
}

private final class ActivityJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let offset: Double
    private let fps: Double
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, offset: Double, fps: Double) {
        self.asset = asset; self.track = track; self.offset = offset; self.fps = fps
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
    }

    func run() throws -> [ActivityPoint] {
        let reader = try AVAssetReader(asset: asset)
        let handle = ReaderHandle(reader)
        readerLock.withLock { $0 = handle }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.readerConfiguration }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.readerStart }
        var next = 0.0
        var previous: [UInt8]?
        var results: [ActivityPoint] = []
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time + 0.0001 >= next, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            next = time + 1 / max(fps, 1)
            let current = try lumaGrid(buffer, columns: 80, rows: 50)
            if let previous, let centroid = changedCentroid(previous, current, width: 80, height: 50) {
                results.append(ActivityPoint(t: time + offset, x: centroid.x * Double(CVPixelBufferGetWidth(buffer)) / 80,
                                             y: centroid.y * Double(CVPixelBufferGetHeight(buffer)) / 50))
            }
            previous = current
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        return results
    }

    private func lumaGrid(_ buffer: CVPixelBuffer, columns: Int, rows: Int) throws -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AnalysisError.pixelBuffer }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { throw AnalysisError.pixelBuffer }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var grid = [UInt8](repeating: 0, count: columns * rows)
        for gy in 0..<rows {
            let y = min((gy * height) / rows, height - 1)
            for gx in 0..<columns {
                let x = min((gx * width) / columns, width - 1), i = y * stride + x * 4
                let b = Int(base[i]), g = Int(base[i + 1]), r = Int(base[i + 2])
                grid[gy * columns + gx] = UInt8((29 * b + 150 * g + 77 * r) >> 8)
            }
        }
        return grid
    }

    private func changedCentroid(_ old: [UInt8], _ new: [UInt8], width: Int, height: Int) -> SIMD2<Double>? {
        var weight = 0.0, sumX = 0.0, sumY = 0.0, count = 0
        for i in old.indices {
            let delta = abs(Int(new[i]) - Int(old[i]))
            guard delta >= 24 else { continue }
            let w = Double(delta - 23), x = Double(i % width), y = Double(i / width)
            weight += w; sumX += x * w; sumY += y * w; count += 1
        }
        guard count >= max(width * height / 1000, 3), weight > 0 else { return nil }
        return SIMD2(sumX / weight, sumY / weight)
    }
}
