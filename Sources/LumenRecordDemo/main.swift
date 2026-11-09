// LumenRecordDemo — headless Lumen recording for the zoom scripted demo.
// Records the main display + full input event stream for N seconds, then
// prints the .lumen bundle path. Drive the fixture with Tools/Verify/drive
// while this runs. No HUD, no countdown: timed by the caller.
import Foundation
import CoreGraphics
import LumenCapture

@main struct RecordDemo {
    static func main() async {
        var seconds = 62.0
        var library = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumen", isDirectory: true)
        let args = CommandLine.arguments
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--seconds": i += 1; seconds = Double(args[i]) ?? seconds
            case "--library": i += 1; library = URL(fileURLWithPath: args[i])
            default: break
            }
            i += 1
        }
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var cfg = RecordingConfig(source: .display(CGMainDisplayID()))
        cfg.fps = 60
        cfg.mic = false
        cfg.systemAudio = false
        cfg.resolution = .native
        cfg.quality = .high
        let session = RecordingSession()
        do {
            try await session.prepare(cfg, library: library)
            try await session.start()
            print("RECORDING for \(seconds)s")
            try await Task.sleep(for: .seconds(seconds))
            let bundle = try await session.stop()
            print("BUNDLE \(bundle.url.path)")
        } catch {
            fputs("record failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
