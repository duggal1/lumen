import Foundation
import AVFoundation
import CoreMedia
import Vision
import os
import LumenDirector

public enum FaceAnalyzer {
    /// Largest face per sampled frame (default 12 fps). `startOffset` maps webcam file time to recording time.
    /// Samples are raw (cx, cy top-left origin, h = face height, all normalized to the webcam image);
    /// the Director pushes them through the same spring cascade as the camera.
    /// Decoding + Vision run on a utility queue (never blocks the Swift concurrency pool). Throws CancellationError if cancelled.
    public static func analyze(url: URL, startOffset: Double, fps: Double = 12) async throws -> [FaceSample] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let job = Job(asset: asset, track: track, startOffset: startOffset, fps: fps)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[FaceSample], Error>) in
                DispatchQueue(label: "lumen.face-analyzer", qos: .utility).async {
                    do { c.resume(returning: try job.run()) } catch { c.resume(throwing: error) }
                }
            }
        } onCancel: { job.cancel() }
    }

    private final class Job: @unchecked Sendable {
        private let asset: AVAsset, track: AVAssetTrack, startOffset: Double, fps: Double
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        init(asset: AVAsset, track: AVAssetTrack, startOffset: Double, fps: Double) {
            self.asset = asset; self.track = track; self.startOffset = startOffset; self.fps = fps
        }
        func cancel() { cancelled.withLock { $0 = true } }

        func run() throws -> [FaceSample] {
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { return [] }
            reader.add(out)
            guard reader.startReading() else {
                throw reader.error ?? NSError(domain: "FaceAnalyzer", code: 1, userInfo: [NSLocalizedDescriptionKey: "startReading failed"])
            }
            let step = 1 / max(fps, 1)
            var samples: [FaceSample] = [], next = -Double.infinity
            while let sb = out.copyNextSampleBuffer() {
                if cancelled.withLock({ $0 }) { reader.cancelReading(); throw CancellationError() }
                let t = sb.presentationTimeStamp.seconds
                guard t >= next, let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                next = t + step
                guard let b = Self.largestFace(in: pb) else { continue }       // bounding box: normalized, bottom-left origin
                samples.append(FaceSample(t: t + startOffset, cx: Float(b.midX), cy: Float(1 - b.midY),
                                          h: Float(min(max(b.height, 0.02), 1))))
            }
            if reader.status == .failed, samples.isEmpty {
                throw reader.error ?? NSError(domain: "FaceAnalyzer", code: 2, userInfo: [NSLocalizedDescriptionKey: "read failed"])
            }
            return samples
        }

        private static func largestFace(in pb: CVPixelBuffer) -> CGRect? {
            autoreleasepool {
                let req = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
                guard (try? handler.perform([req])) != nil else { return nil }
                return req.results?.max { $0.boundingBox.height < $1.boundingBox.height }?.boundingBox
            }
        }
    }
}