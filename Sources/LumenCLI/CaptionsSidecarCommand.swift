import Foundation
import ArgumentParser
import LumenExport

/// Independent plain-text delivery for the selected committed project.
/// Does not change caption enablement, transcribe, or re-encode the movie.
struct CaptionsSidecarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "captions-sidecar",
        abstract: "Export enabled edited captions as SRT or WebVTT without rendering video.")
    @Argument var project: String
    @Option(help: "Destination .srt or .vtt file.") var out: String
    @Flag(help: "Explicitly replace an existing regular subtitle file.") var overwrite = false

    func run() async throws {
        let output = URL(fileURLWithPath: out)
        guard let format = CaptionSidecarFormat(rawValue: output.pathExtension.lowercased()) else {
            throw ValidationError("Use an .srt or .vtt destination.")
        }
        let (_, timeline) = try await openProject(project)
        let delivery = try CaptionSidecars.serialize(timeline: timeline, format: format)
        try CaptionSidecars.write(delivery, format: format, to: output, overwrite: overwrite)
        try jsonOut(["output": output.path, "format": format.rawValue, "cues": delivery.cueCount], to: nil)
    }
}
