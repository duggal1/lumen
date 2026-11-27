import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox

/// Validate encoded media before the agent can publish its staged file.
enum AgentExportProof {
    static func verify(_ url: URL, expectedDuration: Double, fps: Double, expectsAudio: Bool) async throws -> JSONValue {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first, duration.isFinite, duration > 0,
              expectedDuration.isFinite, expectedDuration > 0,
              abs(duration - expectedDuration) <= max(0.15, 2 / max(fps, 1)) else {
            throw ToolError(code: "EXPORT_VERIFICATION_FAILED", hint: "Encoded video track or duration is invalid.")
        }
        let size = try await track.load(.naturalSize)
        guard size.width > 0, size.height > 0 else {
            throw ToolError(code: "EXPORT_VERIFICATION_FAILED", hint: "Invalid encoded video dimensions.")
        }
        // Decode the first and last portions, not just container metadata.
        for time in [0.0, duration / 2, max(0, duration - max(0.25, 3 / max(fps, 1)))] {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 60000), duration: .positiveInfinity)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            guard reader.canAdd(output) else { throw ToolError.failed("Cannot decode exported video.") }
            reader.add(output)
            guard reader.startReading(), let sample = output.copyNextSampleBuffer(), CMSampleBufferGetImageBuffer(sample) != nil else {
                throw ToolError(code: "EXPORT_VERIFICATION_FAILED", hint: "Encoded frame failed to decode.")
            }
            reader.cancelReading()
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        if expectsAudio {
            guard let track = audio.first else {
                throw ToolError(code: "EXPORT_VERIFICATION_FAILED", hint: "Expected an audio track in the encoded output.")
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            guard reader.canAdd(output) else { throw ToolError.failed("Cannot decode exported audio.") }
            reader.add(output)
            guard reader.startReading(), let sample = output.copyNextSampleBuffer(), CMSampleBufferGetNumSamples(sample) > 0 else {
                throw ToolError(code: "EXPORT_VERIFICATION_FAILED", hint: "Encoded audio failed to decode.")
            }
            reader.cancelReading()
        }
        return .object(["duration": .number(duration), "width": .number(Double(size.width)),
                        "height": .number(Double(size.height)), "audio_tracks": .int(audio.count),
                        "boundary_frames_decoded": .bool(true), "midpoint_frame_decoded": .bool(true),
                        "required_audio_decoded": .bool(expectsAudio)])
    }
}
