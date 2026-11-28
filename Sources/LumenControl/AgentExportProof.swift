import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import AudioToolbox
import LumenExport

/// Validate encoded media before the agent can publish its staged file.
enum AgentExportProof {
    static func verify(_ url: URL, expectedDuration: Double, fps: Int, expectsAudio: Bool, expectedSize: CGSize? = nil) async throws -> JSONValue {
        do {
            let proof = try await ExportMediaProof.verify(url, expectedDuration: expectedDuration, fps: fps,
                                                         expectsAudio: expectsAudio, expectedSize: expectedSize)
            return json(proof)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolError(code: "EXPORT_VERIFICATION_FAILED", hint: error.localizedDescription)
        }
    }

    static func json(_ proof: ExportMediaProof) -> JSONValue {
        .object(["duration": .number(proof.duration), "width": .number(Double(proof.width)),
                 "height": .number(Double(proof.height)), "audio_tracks": .int(proof.audioTracks),
                 "video_frames": .int(proof.videoFrames), "presentation_timestamps_verified": .bool(true),
                 "boundary_frames_decoded": .bool(true), "midpoint_frame_decoded": .bool(true),
                 "required_audio_decoded": .bool(proof.requiredAudioDecoded)])
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
