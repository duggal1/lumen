import Foundation
import AVFoundation
import Accelerate
import Vision
import os

public struct PersonMaskInfo: Codable, Sendable, Equatable {
    public var file: String
    public var width: Int
    public var height: Int
    public var fps: Double
    public var frames: Int
    public init(file: String, width: Int, height: Int, fps: Double, frames: Int) {
        self.file = file; self.width = width; self.height = height; self.fps = fps; self.frames = frames
    }
}

public enum PersonMaskAnalyzer {
    public static func analyze(url: URL, output: URL, fps: Double = 30, maxDimension: Int = 720) async throws -> PersonMaskInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AnalysisError.noVideoTrack }
        let job = PersonMaskJob(asset: asset, track: track, output: output, fps: fps, maxDimension: maxDimension)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try job.run() }.value
        } onCancel: { job.cancel() }
    }
}

private final class PersonMaskJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let outputURL: URL
    private let fps: Double
    private let maxDimension: Int
    private let readerLock = OSAllocatedUnfairLock<AVAssetReader?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, output: URL, fps: Double, maxDimension: Int) {
        self.asset = asset; self.track = track; self.outputURL = output
        self.fps = max(fps, 1); self.maxDimension = max(maxDimension, 64)
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.cancelReading() }
    }

    func run() throws -> PersonMaskInfo {
        let reader = try AVAssetReader(asset: asset)
        readerLock.withLock { $0 = reader }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalysisError.readerConfiguration }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.readerStart }
        let tempURL = outputURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).lmask")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: tempURL.path, contents: header()) else { throw AnalysisError.cacheWrite }
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let writer = try FileHandle(forWritingTo: tempURL)
        var writerClosed = false
        defer { if !writerClosed { try? writer.close() } }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        var next = 0.0, frameCount = 0, width = 0, height = 0
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time + 0.0001 >= next, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            next = time + 1 / fps
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:]).perform([request])
            guard let mask = request.results?.first?.pixelBuffer else { continue }
            let scaled = try grayscale(mask, maxDimension: maxDimension)
            if frameCount == 0 { width = scaled.width; height = scaled.height; try writer.write(contentsOf: dimensions(width, height)) }
            var timeBits = CMSampleBufferGetPresentationTimeStamp(sample).seconds.bitPattern.littleEndian
            var timeData = Data(bytes: &timeBits, count: MemoryLayout<UInt64>.size)
            timeData.append(scaled.data)
            try writer.write(contentsOf: timeData)
            frameCount += 1
        }
        if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        guard frameCount > 0 else { throw AnalysisError.noMaskFrames }
        try writer.synchronize()
        try writer.close()
        writerClosed = true
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: outputURL)
        }
        return PersonMaskInfo(file: outputURL.lastPathComponent, width: width, height: height, fps: fps, frames: frameCount)
    }

    private func header() -> Data { Data([0x4c, 0x55, 0x4d, 0x41, 0x53, 0x4b, 0x31, 0]) }

    private func dimensions(_ width: Int, _ height: Int) -> Data {
        var w = UInt32(width).littleEndian, h = UInt32(height).littleEndian
        var data = Data(bytes: &w, count: 4); data.append(Data(bytes: &h, count: 4)); return data
    }

    private func grayscale(_ buffer: CVPixelBuffer, maxDimension: Int) throws -> (width: Int, height: Int, data: Data) {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw AnalysisError.pixelBuffer }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(buffer) else { throw AnalysisError.pixelBuffer }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let scale = min(1, Double(maxDimension) / Double(max(width, height)))
        let targetWidth = max(Int((Double(width) * scale).rounded()), 1), targetHeight = max(Int((Double(height) * scale).rounded()), 1)
        let sourceBuffer = vImage_Buffer(data: source, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                         rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        var data = Data(count: targetWidth * targetHeight)
        let status = data.withUnsafeMutableBytes { bytes -> vImage_Error in
            guard let destination = bytes.baseAddress else { return kvImageMemoryAllocationError }
            var destinationBuffer = vImage_Buffer(data: destination, height: vImagePixelCount(targetHeight),
                                                  width: vImagePixelCount(targetWidth), rowBytes: targetWidth)
            return vImageScale_Planar8(sourceBuffer, &destinationBuffer, nil, vImage_Flags(kvImageNoFlags))
        }
        guard status == kvImageNoError else { throw AnalysisError.maskScale(status) }
        return (targetWidth, targetHeight, data)
    }
}
