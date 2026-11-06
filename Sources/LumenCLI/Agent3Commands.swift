import Foundation
import ArgumentParser
import LumenProject
import LumenRender
import LumenExport

/// `lumen-cli bench` — real Metal render loop with a frame-time gate.
struct Bench: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bench",
        abstract: "Render synthetic frames and fail when the frame budget is missed.")

    @Option var frames = 120
    @Option var width = 1920
    @Option var height = 1080
    @Option var fps = 60.0
    @Flag(name: .long) var motionBlur = false

    func run() throws {
        let result = try RenderBenchmark.run(frames: frames, width: width, height: height,
                                             fps: fps, motionBlur: motionBlur)
        print("\(result.width)x\(result.height) @ \(Int(result.fps)) fps")
        print(result.report.summary)
        if !result.report.passes { throw ExitCode(1) }
    }
}

/// `lumen-cli golden` — reference-image suite skeleton. First run with
/// `--update` to establish baselines; later runs fail on visual drift.
struct Golden: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "golden",
        abstract: "Compare rendered frames against reference PNGs.")

    @Argument var project: String
    @Option var reference = "Tests/Golden"
    @Option var times = "0,1,2"
    @Option var width = 1280
    @Flag(name: .long) var update = false

    func run() async throws {
        let (s, tl) = try await openProject(project)
        let renderer = try Renderer()
        renderer.setCustomCursors(s.cursors)
        let directory = URL(fileURLWithPath: reference)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamps = times.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !stamps.isEmpty else { throw ValidationError("Give at least one timestamp in --times") }
        let height = (Int((Double(width) / tl.style.aspectRatio).rounded()) + 1) & ~1
        var failed = false
        for (i, t) in stamps.enumerated() {
            let pb = try await FrameImage.render(renderer: renderer, session: s, timeline: tl, t: t,
                                                 canvas: SIMD2(width, height), fps: s.meta.source.fps)
            let url = directory.appendingPathComponent(String(format: "%02d.png", i))
            if update {
                try GoldenHarness.save(pixelBuffer: pb, to: url)
                print("wrote \(url.lastPathComponent)")
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("missing \(url.path)")
                failed = true
                continue
            }
            let (_, diff) = try GoldenHarness.capture(pixelBuffer: pb, reference: url)
            print("t=\(t)s \(diff.summary)")
            if !diff.passes() { failed = true }
        }
        if failed { throw ExitCode(1) }
    }
}
