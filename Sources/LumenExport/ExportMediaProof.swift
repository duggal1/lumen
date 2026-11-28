import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox

/// Common delivery proof for native Studio, CLI and agent exports.
/// It validates compressed sample cadence and decodes representative pictures.
public struct ExportMediaProof: Sendable, Equatable {
    public let duration: Double
    public let width: Int
    public let height: Int
    public let audioTracks: Int
    public let videoFrames: Int
    public let requiredAudioDecoded: Bool

    public static func verify(_ url: URL, expectedDuration: Double, fps: Int, expectsAudio: Bool, expectedSize: CGSize? = nil) async throws -> ExportMediaProof {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first, duration.isFinite, duration > 0,
              expectedDuration.isFinite, expectedDuration > 0,
              abs(duration - expectedDuration) <= max(0.15, 2 / Double(max(fps, 1))) else {
            throw ExportStageFailure(stage: .validate, reason: .proofFailed, detail: "Encoded video track or duration is invalid.")
        }
        let size = try await track.load(.naturalSize)
        guard size.width > 0, size.height > 0, expectedSize.map({ $0 == size }) ?? true else {
            throw ExportStageFailure(stage: .validate, reason: .proofFailed, detail: "Invalid encoded video dimensions.")
        }
        let count = ceil(expectedDuration * Double(fps) - 1e-8)
        guard fps > 0, count.isFinite, count < Double(Int.max) else {
            throw ExportStageFailure(stage: .validate, reason: .proofFailed, detail: "Invalid expected frame count.")
        }
        let frames: Int
        do {
            frames = try await ExportBenchmark.validateVideo(at: url, expectedFrames: max(Int(count), 1), fps: fps)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportStageFailure(stage: .validate, reason: .proofFailed, detail: error.localizedDescription)
        }
        // Decode representative images in addition to checking compressed sample timing.
        for time in [0.0, duration / 2, max(0, duration - max(0.25, 3 / Double(max(fps, 1))))] {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 60000), duration: .positiveInfinity)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            guard reader.canAdd(output) else { throw ExportStageFailure(stage: .validate, reason: .proofFailed, detail: "Cannot decode exported video.") }
            reader.add(output)
            guard reader.startReading(), let sample = output.copyNextSampleBuffer(), CMSampleBufferGetImageBuffer(sample) != nil else {
                throw ExportStageFailure(stage: .validate, reason: .proofFailed, detail: "Encoded frame failed to decode.")
            }
            reader.cancelReading()
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        if expectsAudio {
            guard let track = audio.first else {
                throw ExportStageFailure(stage: .validate, reason: .proofFailed, detail: "Expected an audio track in the encoded output.")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            guard reader.canAdd(output) else { throw ExportStageFailure(stage: .validate, reason: .proofFailed, detail: "Cannot decode exported audio.") }
            reader.add(output)
            guard reader.startReading(), let sample = output.copyNextSampleBuffer(), CMSampleBufferGetNumSamples(sample) > 0 else {
                throw ExportStageFailure(stage: .validate, reason: .proofFailed, detail: "Encoded audio failed to decode.")
            }
            reader.cancelReading()
        }
        return ExportMediaProof(duration: duration, width: Int(size.width), height: Int(size.height),
                                audioTracks: audio.count, videoFrames: frames, requiredAudioDecoded: expectsAudio)
    }

}
