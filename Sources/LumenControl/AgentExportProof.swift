import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox
import LumenExport

/// Validate encoded media before the agent can publish its staged file.
enum AgentExportProof {
    static func verify(_ url: URL, expectedDuration: Double, fps: Int, expectsAudio: Bool, expectedSize: CGSize? = nil) async throws -> JSONValue {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first, duration.isFinite, duration > 0,
              expectedDuration.isFinite, expectedDuration > 0,
              abs(duration - expectedDuration) <= max(0.15, 2 / Double(max(fps, 1))) else {
            throw ToolError(code: "EXPORT_VERIFICATION_FAILED", hint: "Encoded video track or duration is invalid.")
        }
        let size = try await track.load(.naturalSize)
        guard size.width > 0, size.height > 0, expectedSize.map({ $0 == size }) ?? true else {
            throw ToolError(code: "EXPORT_VERIFICATION_FAILED", hint: "Invalid encoded video dimensions.")
        }
        let count = ceil(expectedDuration * Double(fps) - 1e-8)
        guard fps > 0, count.isFinite, count < Double(Int.max) else {
            throw ToolError(code: "EXPORT_VERIFICATION_FAILED", hint: "Invalid expected frame count.")
        }
        let frames: Int
        do {
            frames = try await ExportBenchmark.validateVideo(at: url, expectedFrames: max(Int(count), 1), fps: fps)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolError(code: "EXPORT_VERIFICATION_FAILED", hint: error.localizedDescription)
        }
        // Decode representative images in addition to checking compressed sample timing.
        for time in [0.0, duration / 2, max(0, duration - max(0.25, 3 / Double(max(fps, 1))))] {
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
                        "height": .number(Double(size.height)), "audio_tracks": .int(audio.count), "video_frames": .int(frames),
                        "presentation_timestamps_verified": .bool(true),
                        "boundary_frames_decoded": .bool(true), "midpoint_frame_decoded": .bool(true),
                        "required_audio_decoded": .bool(expectsAudio)])
    }

    /// The movie is published last. Existing stems must survive a failed delivery.
    static func publish(_ movie: URL, to output: URL, overwrite: Bool) throws -> [URL] {
        let files = FileManager.default
        let staging = movie.deletingLastPathComponent()
        let destination = output.deletingLastPathComponent()
        let stemNames = try files.contentsOfDirectory(atPath: staging.path)
            .filter { $0.hasPrefix(movie.deletingPathExtension().lastPathComponent + "-") && $0.hasSuffix(".wav") }
            .sorted()
        let stems = stemNames.map { destination.appendingPathComponent($0) }
        var installed: [(url: URL, backup: URL?)] = []
        do {
            for (name, target) in zip(stemNames, stems) {
                try Task.checkCancellation()
                let staged = staging.appendingPathComponent(name)
                if files.fileExists(atPath: target.path) {
                    try checkOverwrite(target, allowed: overwrite)
                    let backup = staging.appendingPathComponent(UUID().uuidString + ".backup")
                    try files.copyItem(at: target, to: backup)
                    installed.append((target, backup))
                    _ = try files.replaceItemAt(target, withItemAt: staged)
                } else {
                    try files.moveItem(at: staged, to: target)
                    installed.append((target, nil))
                }
            }
            try Task.checkCancellation()
            if files.fileExists(atPath: output.path) {
                try checkOverwrite(output, allowed: overwrite)
                _ = try files.replaceItemAt(output, withItemAt: movie)
            } else {
                try files.moveItem(at: movie, to: output)
            }
            return stems
        } catch {
            for (url, backup) in installed.reversed() {
                do {
                    if let backup {
                        if files.fileExists(atPath: url.path) {
                            _ = try files.replaceItemAt(url, withItemAt: backup)
                        } else {
                            try files.moveItem(at: backup, to: url)
                        }
                    } else {
                        try files.removeItem(at: url)
                    }
                } catch {
                    throw ToolError(code: "EXPORT_RECOVERY_REQUIRED",
                                    hint: "Could not restore \(url.path). Recovery files are in \(staging.path).")
                }
            }
            throw error
        }
    }

    private static func checkOverwrite(_ url: URL, allowed: Bool) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard allowed, values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ToolError(code: "EXPORT_OUTPUT_EXISTS",
                            hint: "Choose another output name or allow overwriting an existing regular file at \(url.path).")
        }
    }

}
