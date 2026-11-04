import Foundation
import AVFoundation
import Vision
import os
import LumenCore
import LumenProject

public enum FaceAnalyzer {
    public static func analyze(url: URL, startOffset: Double, fps: Double = 12) async throws -> [FaceSample] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let job = FaceJob(asset: asset, track: track, startOffset: startOffset, fps: fps)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try job.run() }.value
        } onCancel: { job.cancel() }
    }
}

private final class FaceJob: @unchecked Sendable {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let startOffset: Double
    private let fps: Double
    private let readerLock = OSAllocatedUnfairLock<ReaderHandle?>(uncheckedState: nil)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(asset: AVAsset, track: AVAssetTrack, startOffset: Double, fps: Double) {
        self.asset = asset; self.track = track; self.startOffset = startOffset; self.fps = fps
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        readerLock.withLock { $0?.reader.cancelReading() }
    }

    func run() throws -> [FaceSample] {
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
        let interval = 1 / max(fps, 1)
        var next = 0.0
        var faces: [FaceSample] = []
        while let sample = output.copyNextSampleBuffer() {
            if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard time + 0.0001 >= next, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            next = time + interval
            if let face = try Self.largestFace(in: buffer) {
                faces.append(FaceSample(t: time + startOffset, cx: Float(face.midX), cy: Float(1 - face.midY),
                                        h: Float(clamp(face.height, 0.02, 1))))
            }
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.readerFailed }
        return faces
    }

    private static func largestFace(in buffer: CVPixelBuffer) throws -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:]).perform([request])
        return request.results?.max { $0.boundingBox.height < $1.boundingBox.height }?.boundingBox
    }
}
