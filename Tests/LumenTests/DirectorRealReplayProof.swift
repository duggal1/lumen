import Foundation
import CoreGraphics
import Testing
import LumenCore
import LumenProject
@testable import LumenDirector
@testable import LumenRender
import LumenExport

/// Ground truth comes from an annotated actual capture, not from the detector
/// under test. Times are source seconds; rectangles are normalized to source.
private struct DirectorReplayTruth: Decodable {
    struct Sample: Decodable {
        let time: Double
        let rect: [Double] // x, y, width, height
        let minimumOutputHeight: Double
    }
    let submit: Double
    let click: Double
    let response: [Sample]
    let destination: [Sample]
    let hoverOnly: [[Double]] // disjoint intervals that must remain wide
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMEN_DIRECTOR_REPLAY_PROJECT"] != nil))
func actualDirectorReplayProof() async throws {
    let env = ProcessInfo.processInfo.environment
    let project = URL(fileURLWithPath: try #require(env["LUMEN_DIRECTOR_REPLAY_PROJECT"]))
    let annotations = URL(fileURLWithPath: try #require(env["LUMEN_DIRECTOR_REPLAY_TRUTH"]))
    let output = URL(fileURLWithPath: try #require(env["LUMEN_DIRECTOR_REPLAY_OUT"]))
    let truth = try JSONDecoder().decode(DirectorReplayTruth.self, from: Data(contentsOf: annotations))
    let fm = FileManager.default
    let scratch = fm.temporaryDirectory.appendingPathComponent("director-replay-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }
    let copy = scratch.appendingPathComponent("Replay.lumen", isDirectory: true)
    try fm.copyItem(at: project, to: copy)
    let bundle = ProjectBundle(url: copy)
    let renderer = try Renderer()
    let (session, original) = try await ProjectSession.openEditor(bundle, device: renderer.device, prepareAudio: false)
    // Test the original recorded intent, not a manually curated camera plan.
    try #require(original.camera.autoZoom && original.activity.enabled)
    try #require(original.zoom.allSatisfy { $0.origin == .auto } && original.suppressedAuto.isEmpty)
    try #require(original.timeMap.cuts.isEmpty && original.timeMap.trimStart == 0)
    try #require(truth.submit.isFinite && truth.click.isFinite && truth.submit >= 0 && truth.click > truth.submit)
    try #require(truth.response.count >= 2 && !truth.destination.isEmpty && !truth.hoverOnly.isEmpty)
    try #require(truth.response.allSatisfy { $0.time > truth.submit && $0.time < truth.click })
    try #require(truth.destination.allSatisfy { $0.time > truth.click })
    let analysis = await session.analyze(original)
    try #require(analysis.errors.isEmpty, "Analysis errors: \(analysis.errors)")
    let input = session.input
    let source = input.source
    let size = SIMD2<Double>(Double(source.width), Double(source.height))
    try #require(!input.activityGrids.isEmpty)
    try #require(input.events.contains { abs($0.t - truth.click) <= 0.03 && $0.kind == .down && $0.button == 0 })
    let activities = ActivityShotBuilder.build(grids: input.activityGrids,
        source: (size.x, size.y), inputs: ActivityInputs.make(events: input.events), settings: original.activity)
    let response = try #require(activities.shots.first {
        $0.sustained && abs(($0.actionTime ?? -100) - truth.submit) <= 0.03
    })
    let destination = try #require(activities.shots.first {
        abs(($0.actionTime ?? -100) - truth.click) <= 0.03
    })
    try #require(response.end <= truth.click + 0.03 && destination.start >= response.end)
    try #require(truth.response.allSatisfy { response.start <= $0.time && $0.time < response.end })
    try #require(truth.destination.allSatisfy { destination.start <= $0.time && $0.time < destination.end })
    for span in truth.hoverOnly {
        try #require(span.count == 2)
        try #require(span[0].isFinite && span[1].isFinite && span[0] >= 0 && span[1] > span[0] && span[1] <= source.duration)
        try #require(!activities.shots.contains { $0.start < span[1] && $0.end > span[0] },
                     "Unexpected camera subject in an annotated hover-only interval.")
    }
    var records: [[String: Any]] = []
    var exports: [[String: Any]] = []
    for aspect in [CanvasAspect.r16x9, .r9x16] {
        var intent = original
        intent.style.canvas = aspect
        intent.style.customAspect = nil
        // Do not time-compress the annotated source during verification.
        intent.audio.speedRampsAuto = false
        intent.timeMap.ramps = []
        let timeline = session.derive(intent, revision: aspect == .r16x9 ? 1 : 2)
        let first = try #require(timeline.zoom.first { $0.start <= truth.response[0].time && $0.end > truth.response[0].time })
        try #require(first.end <= truth.click + 0.03)
        let second = try #require(timeline.zoom.first { $0.start <= truth.destination[0].time && $0.end > truth.destination[0].time })
        try #require(second.id != first.id && second.start >= first.end)
        for span in truth.hoverOnly {
            try #require(!timeline.zoom.contains { $0.start < span[1] && $0.end > span[0] })
        }
        let canvas = aspect == .r16x9 ? SIMD2<Int>(1920, 1080) : SIMD2<Int>(1080, 1920)
        for (index, sample) in (truth.response + truth.destination).enumerated() {
            try #require(sample.time.isFinite && sample.time >= 0 && sample.time < source.duration)
            try #require(sample.rect.count == 4 && sample.rect.allSatisfy(\.isFinite))
            let r = sample.rect
            try #require(r[0] >= 0 && r[1] >= 0 && r[2] > 0 && r[3] > 0 && r[0] + r[2] <= 1 && r[1] + r[3] <= 1)
            try #require(sample.minimumOutputHeight.isFinite && sample.minimumOutputHeight > 0)
            let time = timeline.timeMap.output(atSource: sample.time)
            let state = timeline.evaluate(at: time)
            let transform = ZoomTransform(canvas: canvas, source: size, timeline: timeline, at: time)
            let points = [
                SIMD2(r[0], r[1]), SIMD2(r[0] + r[2], r[1]),
                SIMD2(r[0], r[1] + r[3]), SIMD2(r[0] + r[2], r[1] + r[3])
            ].map { transform.sourceToCanvas($0 * size) }
            let x0 = try #require(points.map(\.x).min()), x1 = try #require(points.map(\.x).max())
            let y0 = try #require(points.map(\.y).min()), y1 = try #require(points.map(\.y).max())
            let visible = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            let card = transform.videoRect
            let content = CGRect(x: card.x, y: card.y, width: card.z, height: card.w)
            try #require(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            try #require(content.insetBy(dx: -1, dy: -1).contains(visible))
            try #require(CGRect(x: 0, y: 0, width: canvas.x, height: canvas.y).contains(visible))
            try #require(visible.height >= sample.minimumOutputHeight, "Annotated text is too small.")
            let name = "\(aspect.rawValue)-\(index).png"
            let frame = try await FrameImage.render(renderer: renderer, session: session, timeline: timeline,
                                                    t: time, canvas: canvas)
            try FrameImage.writePNG(frame, to: output.appendingPathComponent(name))
            records.append(["file": name, "sourceTime": sample.time, "scale": Double(state.cameraScale),
                            "rect": [x0, y0, x1 - x0, y1 - y0]])
        }
        let preset = ExportPreset(name: "director-replay", codec: .hevc, height: canvas.y, fps: 60)
        let movieName = "\(aspect.rawValue)-replay.mov"
        let movie = output.appendingPathComponent(movieName)
        let clock = ContinuousClock()
        let start = clock.now
        try await Exporter.run(session: session, timeline: timeline, preset: preset, to: movie,
                               includeAudio: false) { _ in }
        let elapsed = (clock.now - start).components
        let expectedFrames = max(Int(ceil(timeline.compositionDuration * Double(preset.fps) - 1e-8)), 1)
        let frames = try await ExportBenchmark.validateVideo(at: movie, expectedFrames: expectedFrames, fps: preset.fps)
        exports.append(["file": movieName, "frames": frames, "fps": preset.fps,
                        "wallSeconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18])
    }
    let report: [String: Any] = [
        "commit": env["LUMEN_DIRECTOR_REPLAY_COMMIT"] ?? "unverified",
        "response": [response.start, response.end], "destination": [destination.start, destination.end],
        "frames": records, "exports": exports,
        "limits": "Annotated geometry, rendered samples and encoded timestamps. Semantic URL recognition, overlay occlusion, duplicate motion images and Studio presentation cadence require separate review."
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("report.json"), options: .atomic)
}
