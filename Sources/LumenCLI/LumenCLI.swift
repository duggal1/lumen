import Foundation
import ArgumentParser
import Metal
import CoreGraphics
import ImageIO
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenAudio
import LumenExport
import LumenAnalysis
import AVFoundation
import LumenSpeech

@main
struct LumenCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lumen-cli", abstract: "Headless Lumen",
        subcommands: [Analyze.self, Render.self, Frame.self, Smoothness.self, SyncCheck.self, Probe.self, Transcribe.self, Bench.self, Golden.self, AudioCheckCmd.self])
}

func openProject(_ path: String) async throws -> (ProjectSession, Timeline) {
    guard let dev = MTLCreateSystemDefaultDevice() else { throw ValidationError("no Metal device") }
    let (s, tl) = try await ProjectSession.open(ProjectBundle(url: URL(fileURLWithPath: path)), device: dev)
    return (s, s.derive(tl, revision: 1))
}
func jsonOut(_ v: Any, to path: String?) throws {
    let d = try JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])
    if let path { try d.write(to: URL(fileURLWithPath: path)) } else { print(String(decoding: d, as: UTF8.self)) }
}

struct Analyze: AsyncParsableCommand {
    @Argument var project: String
    @Option var report: String?
    @Flag(name: .long) var runAnalyzers = false
    func run() async throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw ValidationError("no Metal device") }
        let (s, sourceTimeline) = try await ProjectSession.open(ProjectBundle(url: URL(fileURLWithPath: project)), device: dev)
        var analysisErrors: [String: String] = [:]
        if runAnalyzers { analysisErrors = await s.analyze(sourceTimeline).errors }
        let tl = s.derive(sourceTimeline, revision: 1)
        let ev = s.input.events
        let masks = (sourceTimeline.overlays.masks + (tl.derived?.autoMasks ?? [])).map { mask in
            ["category": mask.category ?? "", "origin": mask.origin.rawValue, "approved": mask.approved,
             "start": mask.start, "end": mask.end,
             "rects": mask.keys.map { ["t": $0.t, "x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] as [String: Double] }] as [String: Any]
        }
        let eventCounts: [String: Int] = [
            "total": ev.count,
            "moves": ev.filter { $0.kind == .move }.count,
            "clicks": ev.filter { $0.kind == .down }.count,
            "keys": ev.filter { $0.kind == .keyDown }.count,
            "scrolls": ev.filter { $0.kind == .scroll }.count
        ]
        let zoomItems: [[String: Any]] = tl.zoom.map { zoom in
            ["start": zoom.start, "end": zoom.end, "scale": zoom.scale, "origin": zoom.origin.rawValue]
        }
        let ramps: [[String: Double]] = tl.timeMap.ramps.map { ramp in
            ["start": ramp.start, "end": ramp.end, "speed": ramp.speed]
        }
        let eventTimes = ev.filter { $0.kind == .down }.map(\.t)
        let withinVideo = ev.filter { $0.t >= 0 && $0.t <= s.meta.source.duration }.count
        var summary: [String: Any] = [:]
        summary["name"] = s.meta.name
        summary["sourceSize"] = [s.meta.source.width, s.meta.source.height]
        summary["fps"] = s.meta.source.fps
        summary["sourceDuration"] = s.meta.source.duration
        summary["outputDuration"] = tl.timeMap.outputDuration
        summary["droppedFrames"] = s.meta.droppedFrames
        summary["eventTimeRange"] = [ev.first?.t ?? -1, ev.last?.t ?? -1]
        summary["eventsInsideVideo"] = withinVideo
        summary["clickTimes"] = eventTimes
        summary["events"] = eventCounts
        let accuracy = AccuracyReport.measure(tl, events: ev)
        summary["zoomAccuracy"] = [
            "clicks": accuracy.clicks,
            "zoomedClicks": accuracy.zoomedClicks,
            "insideMargin": accuracy.insideMargin,
            "medianExcessError": accuracy.medianExcessError,
            "maxExcessError": accuracy.maxExcessError,
            "medianArrival": accuracy.medianArrival
        ] as [String: Any]
        summary["zoomSegments"] = zoomItems
        summary["speedRamps"] = ramps
        summary["voiceRegions"] = s.input.vad.count
        summary["faceSamples"] = s.input.face.count
        summary["activityPoints"] = s.input.activity.count
        summary["transcriptWords"] = s.input.transcript?.words.count ?? 0
        summary["masks"] = masks
        summary["analysisErrors"] = analysisErrors
        try jsonOut(summary, to: report)
    }
}

struct Render: AsyncParsableCommand {
    @Argument var project: String
    @Option var preset = "1080p60-h264"
    @Option var out = "out.mp4"
    @Flag(name: .long) var benchmark = false
    func run() async throws {
        if benchmark { setenv("LUMEN_BENCHMARK", "1", 1) }
        guard let p = ExportPresets.parse(preset) else { throw ValidationError("unknown preset \(preset). Try `lumen-cli probe`.") }
        let (s, tl) = try await openProject(project)
        try await Exporter.run(session: s, timeline: tl, preset: p, to: URL(fileURLWithPath: out)) { pr in
            if let n = pr.notice, pr.frame == 1 { FileHandle.standardError.write(Data((n + "\n").utf8)) }
            if pr.frame % 30 == 0 || pr.frame == pr.total { print("\rframe \(pr.frame)/\(pr.total)", terminator: ""); fflush(stdout) }
        }
        print("\nwrote \(out)")
    }
}

struct Frame: AsyncParsableCommand {
    @Argument var project: String
    @Option var t = 0.0
    @Option var out = "frame.png"
    @Option var width = 1920
    func run() async throws {
        let (s, tl) = try await openProject(project)
        let h = (Int((Double(width) / tl.style.aspectRatio).rounded()) + 1) & ~1
        let r = try Renderer(); r.setCustomCursors(s.cursors)
        let pb = try await FrameImage.render(renderer: r, session: s, timeline: tl, t: t, canvas: SIMD2(width, h))
        try FrameImage.writePNG(pb, to: URL(fileURLWithPath: out)); print("wrote \(out)")
    }
}

struct Probe: ParsableCommand {
    func run() throws {
        for p in ExportPresets.all where p.codec != .prores { print(ExportCapabilityMatrix.shared.supports(p) ? "ok   " : "FAIL ", p.name) }
    }
}

struct SyncCheck: AsyncParsableCommand {
    @Argument var project: String
    func run() async throws {
        let b = ProjectBundle(url: URL(fileURLWithPath: project)), meta = try b.load().meta, o = meta.clock.originHostSeconds
        let ev = try b.events(origin: o)
        let raw = (try? Data(contentsOf: b.framesMetaURL)) ?? Data()
        var pts: [Double] = []
        raw.withUnsafeBytes { p in for i in 0..<(raw.count / 32) { pts.append(Double(bitPattern: UInt64(littleEndian: p.loadUnaligned(fromByteOffset: i * 32, as: UInt64.self))) - o) } }
        let gaps = zip(pts.dropFirst(), pts).map { $0 - $1 }
        print("clock unit            \(meta.clock.eventUnit.rawValue)")
        print("frames                \(pts.count)  avg \(String(format: "%.2f", (pts.last ?? 0) / Double(max(pts.count - 1, 1)) * 1000)) ms  max gap \(String(format: "%.1f", (gaps.max() ?? 0) * 1000)) ms")
        print("first frame           \(String(format: "%.4f", pts.first ?? 0)) s (should be ~0)")
        print("first event           \(String(format: "%.4f", ev.first?.t ?? 0)) s   last \(String(format: "%.2f", ev.last?.t ?? 0)) s vs duration \(String(format: "%.2f", meta.source.duration)) s")
        if let m = meta.mic { print("mic offset            \(String(format: "%.1f", (m.startHostSeconds - o) * 1000)) ms") }
        if let m = meta.system { print("system offset         \(String(format: "%.1f", (m.startHostSeconds - o) * 1000)) ms") }
        if let m = meta.webcam { print("webcam offset         \(String(format: "%.1f", (m.startHostSeconds - o) * 1000)) ms") }
        print("dropped (capture)     \(meta.droppedFrames)")
        print("note: the < 1 ms flash-and-click check (plan 13.1 SyncTests) needs a test app; this prints offsets only.")
    }
}

// MARK: smoothness (plan 8.1)

func fftHighFraction(_ x: [Double], fs: Double, above hz: Double) -> Double {
    var n = 1; while n < x.count { n <<= 1 }
    let mean = x.reduce(0, +) / Double(max(x.count, 1))
    var re = [Double](repeating: 0, count: n), im = re
    for i in 0..<x.count { re[i] = (x[i] - mean) * (0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(max(x.count - 1, 1)))) }
    var j = 0
    for i in 1..<n { var bit = n >> 1; while j & bit != 0 { j ^= bit; bit >>= 1 }; j ^= bit; if i < j { re.swapAt(i, j); im.swapAt(i, j) } }
    var len = 2
    while len <= n {
        let ang = -2 * Double.pi / Double(len)
        for s in stride(from: 0, to: n, by: len) { for k in 0..<(len / 2) {
            let wr = cos(ang * Double(k)), wi = sin(ang * Double(k)), a = s + k, b = a + len / 2
            let tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr
            re[b] = re[a] - tr; im[b] = im[a] - ti; re[a] += tr; im[a] += ti
        } }
        len <<= 1
    }
    var tot = 0.0, hi = 0.0
    for k in 1..<(n / 2) { let e = re[k] * re[k] + im[k] * im[k]; tot += e; if Double(k) * fs / Double(n) > hz { hi += e } }
    return tot > 0 ? hi / tot : 0
}

struct Smoothness: AsyncParsableCommand {
    @Argument var project: String
    @Option var fps = 60
    func run() async throws {
        let (s, tl) = try await openProject(project)
        guard let d = tl.derived else { throw ValidationError("no derived tracks") }
        let n = Int(d.outputDuration * Double(fps)), fsr = Double(fps), outW = 1920.0, k = outW / d.sourceSize.x
        var series: [String: [Double]] = ["camX": [], "camY": [], "logZoom": [], "cursorX": [], "cursorY": []]
        var boundsOK = 0
        for i in 0..<n {
            let st = tl.evaluate(at: Double(i) / fsr)
            series["camX"]!.append(Double(st.cameraCenter.x) * k * Double(st.cameraScale)); series["camY"]!.append(Double(st.cameraCenter.y) * k * Double(st.cameraScale))
            series["logZoom"]!.append(log(Double(st.cameraScale)) * outW / 2)
            series["cursorX"]!.append(Double(st.cursor.position.x) * k); series["cursorY"]!.append(Double(st.cursor.position.y) * k)
            let vw = d.sourceSize.x / Double(st.cameraScale), vh = d.sourceSize.y / Double(st.cameraScale)
            if Double(st.cameraCenter.x) - vw / 2 >= -0.5, Double(st.cameraCenter.x) + vw / 2 <= d.sourceSize.x + 0.5,
               Double(st.cameraCenter.y) - vh / 2 >= -0.5, Double(st.cameraCenter.y) + vh / 2 <= d.sourceSize.y + 0.5 { boundsOK += 1 }
        }
        let clickFrames = Set(d.clicks.map { Int($0.t * fsr) })
        var failed = false
        func diff(_ a: [Double]) -> [Double] { zip(a.dropFirst(), a).map { ($0 - $1) * fsr } }
        for (name, a) in series.sorted(by: { $0.key < $1.key }) {
            let v = diff(a), ac = diff(v), j = diff(ac)
            func mad(_ x: [Double]) -> Double { let m = x.sorted()[x.count / 2]; return x.map { abs($0 - m) }.sorted()[x.count / 2] }
            var flags = 0
            if name.hasPrefix("cam") || name == "logZoom" {
                for (lvl, x) in [("v", v), ("a", ac), ("j", j)] where x.count > 8 {
                    let thr = max(6 * mad(x), 0.05 * (x.map { $0 * $0 }.reduce(0, +) / Double(x.count)).squareRoot() + 1e-6)
                    for (i, e) in x.enumerated() where abs(e) > thr && !clickFrames.contains(i) { flags += 1; _ = lvl }
                }
            }
            let hf = name.hasPrefix("cam") || name == "logZoom" ? fftHighFraction(a, fs: fsr, above: 8) : 0
            if hf > 0.01 { failed = true }
            print(String(format: "%-8@ max|v| %9.1f  max|a| %11.1f  max|j| %13.1f  >8Hz %6.3f%%  flags %d", name as NSString,
                         v.map(abs).max() ?? 0, ac.map(abs).max() ?? 0, j.map(abs).max() ?? 0, hf * 100, flags))
        }
        print("bounds: \(boundsOK)/\(n) samples inside source (\(boundsOK == n ? "ok" : "FAIL"))")
        _ = s
        if boundsOK != n { failed = true }
        if failed { throw ExitCode(1) }
    }
}


struct Transcribe: AsyncParsableCommand {
    @Argument var project: String
    @Option var size = "tiny"
    @Flag var save = false
    func run() async throws {
        guard let s = MoonshineSize(rawValue: size) else { throw ValidationError("size must be tiny, small or medium") }
        guard MoonshineRuntime.isAvailable, ModelStore.isInstalled(s) else { throw ValidationError("Moonshine \(s.rawValue) is not installed.") }
        let b = ProjectBundle(url: URL(fileURLWithPath: project))
        let f = try AVAudioFile(forReading: b.micURL), audioSec = Double(f.length) / f.processingFormat.sampleRate
        let t0 = HostClock.now()
        let r = await FileTranscriber.run(url: b.micURL, size: s) { p in FileHandle.standardError.write(Data("\r\(Int(p * 100))%".utf8)) }
        let wall = HostClock.now() - t0
        switch r {
        case .failure(let e): throw ValidationError(e.description)
        case .success(let tr):
            if save { try b.saveTranscript(TranscriptFile(engine: "moonshine-streaming-\(s.rawValue)", complete: true, transcript: tr)) }
            try jsonOut(["engine": "moonshine-streaming-\(s.rawValue)", "audioSeconds": audioSec, "wallSeconds": wall, "realtimeFactor": audioSec / max(wall, 1e-6),
                         "words": tr.words.count, "text": tr.words.map(\.text).joined(separator: " ")] as [String: Any], to: nil)
        }
    }
}

struct AudioCheckCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "audio-check", abstract: "Measure cracks, clips, loudness")
    @Argument var target: String
    @Option var report: String?
    @Option var spectrogram: String?
    func run() async throws {
        let url = URL(fileURLWithPath: target)
        var fileURLs: [URL] = []
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let b = ProjectBundle(url: url)
            for u in [b.micURL, b.systemURL] where FileManager.default.fileExists(atPath: u.path) { fileURLs.append(u) }
            if fileURLs.isEmpty { fileURLs = [url.appendingPathComponent("mic.caf"), url.appendingPathComponent("system.caf")].filter { FileManager.default.fileExists(atPath: $0.path) } }
            if fileURLs.isEmpty { throw ValidationError("no audio tracks in \(target)") }
        } else {
            fileURLs = [url]
        }
        var reports: [String: Any] = [:]
        for fileURL in fileURLs {
            let f = try AVAudioFile(forReading: fileURL)
            let fmt = f.processingFormat
            let total = Int(f.length)
            guard total > 0 else { reports[fileURL.lastPathComponent] = ["error": "empty"]; continue }
            let cap: AVAudioFrameCount = 1 << 16
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { throw ValidationError("buffer") }
            var chans = [[Float]](repeating: [], count: Int(fmt.channelCount))
            while f.framePosition < f.length {
                try f.read(into: buf, frameCount: cap)
                let n = Int(buf.frameLength)
                if n == 0 { break }
                guard let d = buf.floatChannelData else { throw ValidationError("not float PCM: \(fileURL.path)") }
                for c in 0..<Int(fmt.channelCount) { chans[c].append(contentsOf: UnsafeBufferPointer(start: d[c], count: n)) }
            }
            let rep = AudioCheck.analyze(channels: chans, sampleRate: fmt.sampleRate,
                                         format: "pcmF32_\(Int(fmt.sampleRate))Hz_\((fmt.isInterleaved ? "interleaved" : "nonInterleaved"))_ch\(fmt.channelCount)")
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let dict = try JSONSerialization.jsonObject(with: enc.encode(rep)) as! [String: Any]
            reports[fileURL.lastPathComponent] = dict
            if let spec = spectrogram {
                let (w, h, rows) = AudioCheck.renderSpectrogram(channels: chans, sampleRate: fmt.sampleRate)
                var pixels = [UInt8](repeating: 0, count: w * h * 4)
                for y in 0..<h {
                    for x in 0..<w {
                        pixels[(y * w + x) * 4] = rows[y][x * 4]
                        pixels[(y * w + x) * 4 + 1] = rows[y][x * 4 + 1]
                        pixels[(y * w + x) * 4 + 2] = rows[y][x * 4 + 2]
                        pixels[(y * w + x) * 4 + 3] = 255
                    }
                }
                guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                      let img = ctx.makeImage(),
                      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: spec) as CFURL,
                                                                 "public.png" as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
        }
        try jsonOut(reports, to: report)
    }
}
