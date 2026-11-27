import Foundation
import AVFoundation
import Testing
import Darwin
import LumenCore
import LumenProject
import LumenRender
import LumenExport

/// Opt-in because normal CI has no authorized real recording and is not M1
/// target hardware. The wrapper requires the report; a skipped test is not proof.
@Test(.enabled(if: ProcessInfo.processInfo.environment["LUMEN_PART5_PROJECT"] != nil))
func targetHardwareRealProjectProof() async throws {
    let environment = ProcessInfo.processInfo.environment
    let original = URL(fileURLWithPath: try #require(environment["LUMEN_PART5_PROJECT"]))
    let output = URL(fileURLWithPath: try #require(environment["LUMEN_PART5_OUT"]))
    let fm = FileManager.default
    let scratch = fm.temporaryDirectory.appendingPathComponent("lumen-part5-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }
    let copy = scratch.appendingPathComponent("Proof.lumen", isDirectory: true)
    try fm.copyItem(at: original, to: copy)
    let bundle = ProjectBundle(url: copy)
    let originalProject = try bundle.load()
    // Only remove derived caches in the scratch copy. Source media and
    // the user's original project are never modified.
    if fm.fileExists(atPath: bundle.cacheURL.path) {
        try fm.removeItem(at: bundle.cacheURL)
    }
    try fm.createDirectory(at: bundle.cacheURL, withIntermediateDirectories: true)
    let renderer = try Renderer()
    let openStart = HostClock.now()
    let (session, intent) = try await ProjectSession.openEditor(bundle, device: renderer.device, prepareAudio: false)
    let openSeconds = HostClock.now() - openStart
    let analysisStart = HostClock.now()
    let analysis = await session.analyze(intent)
    if intent.overlays.privacy.enabled && intent.overlays.privacy.autoDetect {
        try #require(analysis.errors["ocr"] == nil && analysis.errors["cancelled"] == nil)
    }
    try #require(analysis.errors.isEmpty, "Analysis errors: \(analysis.errors)")
    let analysisSeconds = HostClock.now() - analysisStart
    let audioStart = HostClock.now()
    try #require(await session.prepareAudio())
    let audioSeconds = HostClock.now() - audioStart
    let deriveStart = HostClock.now()
    let timeline = session.derive(intent, revision: 1)
    let deriveSeconds = HostClock.now() - deriveStart
    let duration = timeline.compositionDuration
    try #require(duration >= 39 && duration <= 41,
                 "Supply an actual approximately 40-second edited project, not a short synthetic fixture.")
    try #require(abs(timeline.style.aspectRatio - 16.0 / 9) < 0.001, "Use a landscape 16:9 proof project.")
    let frameCount = Int(ceil(duration * 60 - 1e-8))
    var runs: [[String: Any]] = []
    for height in [1080, 2160] {
        for trial in 1...2 {
            let name = "\(height)p60-h264-trial-\(trial)"
            let preset = ExportPreset(name: name, codec: .h264, height: height, fps: 60)
            let file = output.appendingPathComponent(name + ".mp4")
            try #require(!fm.fileExists(atPath: file.path))
            let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
            let start = HostClock.now()
            try await Exporter.run(session: session, timeline: timeline, preset: preset, to: file,
                                   includeAudio: true) { _ in }
            let elapsed = HostClock.now() - start
            let validationStart = HostClock.now()
            let frames = try await ExportBenchmark.validateVideo(at: file, expectedFrames: frameCount, fps: 60)
            let asset = AVURLAsset(url: file)
            let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let size = try await video.load(.naturalSize)
            let videoDuration = try await video.load(.timeRange).duration.seconds
            try #require(Int(size.width) == preset.width(aspect: timeline.style.aspectRatio))
            try #require(Int(size.height) == height)
            try #require(abs(videoDuration - Double(frameCount) / 60) <= 1.0 / 60 + 0.001)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            if session.mixer.hasProgram(timeline) {
                let track = try #require(audio.first)
                let range = try await track.load(.timeRange)
                try #require(abs(range.start.seconds) <= 1.0 / 60 + 0.001)
                try #require(abs(range.duration.seconds - videoDuration) <= 1.0 / 60 + 0.001)
            }
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            runs.append([
                "file": file.lastPathComponent, "height": height, "fps": 60, "codec": "h264",
                "trial": trial, "frames": frames, "exportSeconds": elapsed,
                "validationSeconds": HostClock.now() - validationStart,
                "realtimeFactor": duration / elapsed,
                "outputBytes": try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                "peakProcessRSSBytes": Int64(usage.ru_maxrss),
                "thermalBefore": thermalBefore,
                "thermalAfter": ProcessInfo.processInfo.thermalState.rawValue,
                "audioTrackCount": audio.count,
                "stretchTargetMet": height == 1080 ? (elapsed <= 5 && abs(duration - 40) <= 0.05) : duration / elapsed >= 3
            ])
        }
    }
    let report: [String: Any] = [
        "source": ["width": originalProject.meta.source.width, "height": originalProject.meta.source.height,
                   "fps": originalProject.meta.source.fps],
        "duration": duration, "openSeconds": openSeconds, "analysisSeconds": analysisSeconds,
        "audioPreparationSeconds": audioSeconds, "deriveSeconds": deriveSeconds,
        "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
        "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
        "gpu": renderer.device.name,
        "commit": environment["LUMEN_PART5_COMMIT"] ?? "unverified",
        "runs": runs,
        "notes": "Audio track duration is checked, not waveform A/V sync. RSS is process-lifetime peak. Actual presented frame cadence, hardware encoder telemetry, fault injection and subjective review remain separate gates."
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("report.json"), options: .atomic)
}
