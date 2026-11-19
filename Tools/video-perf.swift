// Headless brutal perf/memory probe for Lumen's video-edit + derive stack.
// Mirrors Tools/perfprobe.swift instrumentation. Links against release module .o files.
// Usage: video-perf <mode>
//   derive60 | derive-scale | edits | edit-scale | redrive | eval | eval-scale
//   frame240 | export4k | all
import Foundation
import CoreGraphics
import Darwin
import LumenCore
import LumenProject
import LumenDirector

// MARK: - instrumentation (identical primitives to Tools/perfprobe.swift)

@inline(__always) func uptimeNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

struct Mem {
    var rss: UInt64 = 0
    var peak: UInt64 = 0
    var pageFaults: UInt64 = 0
    var blocks: Int = 0
    var sizeInUse: Int = 0
    var maxSizeInUse: Int = 0
}

func mem() -> Mem {
    var m = Mem()
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { p -> kern_return_t in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { q in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), q, &count)
        }
    }
    if r == KERN_SUCCESS {
        m.rss = UInt64(info.resident_size)
        m.peak = UInt64(info.resident_size_max)
    }
    var ev = task_events_info()
    var ec = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<integer_t>.size)
    let er = withUnsafeMutablePointer(to: &ev) { p -> kern_return_t in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(ec)) { q in
            task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), q, &ec)
        }
    }
    if er == KERN_SUCCESS { m.pageFaults = UInt64(ev.faults) }
    var st = malloc_statistics_t()
    malloc_zone_statistics(nil, &st)
    m.blocks = Int(st.blocks_in_use)
    m.sizeInUse = Int(st.size_in_use)
    m.maxSizeInUse = Int(st.max_size_in_use)
    return m
}

func mb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1_048_576.0) }
func mb(_ b: Int) -> String { String(format: "%.1f", Double(b) / 1_048_576.0) }
func udiff(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : 0 }
func f2(_ x: Double) -> String { String(format: "%.2f", x) }
func f3(_ x: Double) -> String { String(format: "%.3f", x) }

// MARK: - scenario builders

/// Deterministic event stream. `rate` = pointer moves per second; `clicks` = total clicks.
func makeInput(_ duration: Double, clicks: Int, moveRate: Double = 10) -> DirectorInput {
    var events: [InputEvent] = []
    events.reserveCapacity(Int(duration * moveRate) + clicks * 2 + 8)
    let moveCount = max(1, Int(duration * moveRate))
    for i in 0..<moveCount {
        let t = Double(i) / moveRate
        events.append(InputEvent(t: t, kind: .move,
                                 x: Float(200 + (i * 211) % 1400),
                                 y: Float(150 + (i * 97) % 760)))
    }
    if clicks > 0 {
        let span = max(duration - 1.0, 0.5)
        for i in 0..<clicks {
            let t = 0.3 + Double(i) * span / Double(clicks)
            let x = Float(300 + (i * 211) % 1200)
            let y = Float(200 + (i * 97) % 600)
            events.append(InputEvent(t: t, kind: .down, x: x, y: y, button: 0))
            events.append(InputEvent(t: t + 0.04, kind: .up, x: x, y: y, button: 0))
        }
    }
    events.sort { $0.t < $1.t }
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: duration,
                         backingScale: 2, originX: 0, originY: 0)
    return DirectorInput(events: events, source: src)
}

func makeTimeline(_ duration: Double) -> Timeline {
    var tl = Timeline(duration: duration)
    tl.audio.speedRampsAuto = false
    tl.camera.maxScale = 2.0
    tl.camera.autoZoom = true
    return tl
}

func deriveOnce(_ duration: Double, clicks: Int, moveRate: Double = 10) -> Timeline {
    var cache = DeriveCache()
    return Director.derive(makeTimeline(duration), input: makeInput(duration, clicks: clicks, moveRate: moveRate),
                           revision: 1, cache: &cache)
}

// MARK: - 1. 60-minute project derive

func modeDerive60() {
    let duration = 3600.0
    let input = makeInput(duration, clicks: 600, moveRate: 10)   // 36,000 moves + 1,200 clicks
    var cache = DeriveCache()
    _ = Director.derive(makeTimeline(duration), input: input, revision: 1, cache: &cache) // warm-up

    let m0 = mem(); let t0 = uptimeNS()
    let out = Director.derive(makeTimeline(duration), input: input, revision: 1, cache: &cache)
    let t1 = uptimeNS(); let m1 = mem()
    let wall = Double(t1 - t0) / 1e6
    print("DERIVE60 dur=3600s events=\(input.events.count): wall=\(f2(wall))ms peakRSS=\(mb(m1.peak))MB rssDelta=\(mb(udiff(m1.rss, m0.rss)))MB pageFaultsDelta=\(udiff(m1.pageFaults, m0.pageFaults)) mallocSizeDelta=\(mb(m1.sizeInUse - m0.sizeInUse))MB blocksDelta=\(m1.blocks - m0.blocks) camSamples=\(out.derived?.camera.nx.count ?? -1) zooms=\(out.zoom.count)")
    let perEvent = wall / Double(input.events.count)
    print("DERIVE60 usPerEvent=\(f3(perEvent * 1000)) msPerSourceSecond=\(f3(wall / duration))")
}

// MARK: - 2. derive scaling / quadratic verdict

func modeDeriveScale() {
    print("mode,duration_s,events,wall_ms,ms_per_sec,peakRSS_MB,cam_samples,zoom_count")
    var prevWall = 0.0
    var prevD = 0.0
    for d in [10.0, 30.0, 60.0, 120.0, 300.0, 600.0, 3600.0] {
        let clicks = Int(d / 6)
        let input = makeInput(d, clicks: clicks, moveRate: 10)
        var cache = DeriveCache()
        _ = Director.derive(makeTimeline(d), input: input, revision: 1, cache: &cache)
        let t0 = uptimeNS()
        let out = Director.derive(makeTimeline(d), input: input, revision: 1, cache: &cache)
        let t1 = uptimeNS(); let m1 = mem()
        let wall = Double(t1 - t0) / 1e6
        let ratio = prevWall > 0 ? f2(wall / prevWall) : "-"
        let sizeRatio = prevD > 0 ? f2(d / prevD) : "-"
        print("DERIVE-SCALE,\(Int(d)),\(input.events.count),\(f2(wall)),\(f3(wall / d)),\(mb(m1.peak)),\(out.derived?.camera.nx.count ?? -1),\(out.zoom.count)  sizeRatio=\(sizeRatio) timeRatio=\(ratio)")
        prevWall = wall; prevD = d
    }
}

// MARK: - 3. 500 edits through the real reducer

/// Deterministic mix of real Commands. `addCut` appends to TimeMap.cuts, whose
/// didSet rebuilds the whole 240 Hz output table on every mutation — included
/// deliberately because that is a real per-edit cost on long projects.
func editCommands(_ n: Int, duration: Double) -> [Command] {
    var out: [Command] = []
    out.reserveCapacity(n)
    let span = max(duration - 2, 10)
    for i in 0..<n {
        switch i % 5 {
        case 0:
            let s = 1.0 + Double(i) * span / Double(max(n, 1))
            out.append(.addCut(start: s, end: s + 0.5))
        case 1:
            let s = 2.0 + Double(i) * span / Double(max(n, 1))
            out.append(.addSpeedRamp(start: s, end: s + 1.0, speed: 1.5))
        case 2:
            let s = 3.0 + Double(i) * span / Double(max(n, 1))
            out.append(.addZoom(ZoomSegment(start: s, end: s + 2.0, scale: 2.0, focus: .follow, origin: .manual)))
        case 3:
            out.append(.addText(TextBlock(start: 5, end: 6, text: "edit \(i)")))
        default:
            out.append(.deleteWords([i]))
        }
    }
    return out
}

func applyEdits(_ n: Int, duration: Double) -> (wall: Double, mallocDelta: Int, blocksDelta: Int) {
    var tl = makeTimeline(duration)
    let cmds = editCommands(n, duration: duration)
    let ctx = ReduceContext(playhead: duration / 2, duration: duration, fps: 60)
    let m0 = mem(); let t0 = uptimeNS()
    for c in cmds { _ = try? reduce(&tl, c, ctx: ctx) }
    let t1 = uptimeNS(); let m1 = mem()
    withExtendedLifetime(tl) {}
    return (Double(t1 - t0) / 1e6, m1.sizeInUse - m0.sizeInUse, m1.blocks - m0.blocks)
}

func modeEdits() {
    print("mode,edits,duration_s,wall_ms,us_per_edit,mallocDelta_MB,blocksDelta")
    for (n, d) in [(100, 3600.0), (250, 3600.0), (500, 3600.0), (500, 60.0)] {
        // warm-up on a small batch so the allocator is primed
        _ = applyEdits(10, duration: d)
        let r = applyEdits(n, duration: d)
        print("EDITS,\(n),\(Int(d)),\(f2(r.wall)),\(f3(r.wall * 1000 / Double(n))),\(mb(r.mallocDelta)),\(r.blocksDelta)")
    }
}

/// Same edit count on increasing project lengths isolates the TimeMap.rebuild
/// per-edit cost: if a cut on a 3600 s project costs ~60x a cut on a 60 s one,
/// the cost is O(duration) per edit (Models.swift TimeMap.didSet/rebuild).
func modeEditScale() {
    print("mode,duration_s,edits,wall_ms,us_per_edit,mallocDelta_MB")
    var prevWall = 0.0; var prevD = 0.0
    for d in [60.0, 300.0, 600.0, 1800.0, 3600.0] {
        _ = applyEdits(20, duration: d)
        let r = applyEdits(100, duration: d)
        let ratio = prevWall > 0 ? f2(r.wall / prevWall) : "-"
        let sizeRatio = prevD > 0 ? f2(d / prevD) : "-"
        print("EDIT-SCALE,\(Int(d)),100,\(f2(r.wall)),\(f3(r.wall * 1000 / 100)),\(mb(r.mallocDelta))  sizeRatio=\(sizeRatio) timeRatio=\(ratio)")
        prevWall = r.wall; prevD = d
    }
}

// MARK: - 4. repeated derives (leak / malloc growth over N cycles)

func modeRedrive() {
    let d = 60.0
    let input = makeInput(d, clicks: 200, moveRate: 20)
    var cache = DeriveCache()
    _ = Director.derive(makeTimeline(d), input: input, revision: 1, cache: &cache)
    let n = 30
    let m0 = mem(); let t0 = uptimeNS()
    var firstWall = 0.0
    for i in 1...n {
        let a = uptimeNS()
        let out = Director.derive(makeTimeline(d), input: input, revision: i + 1, cache: &cache)
        let b = uptimeNS()
        if i == 1 { firstWall = Double(b - a) / 1e6 }
        precondition(out.derived != nil)
    }
    let t1 = uptimeNS(); let m1 = mem()
    let total = Double(t1 - t0) / 1e6
    print("REDRIVE n=\(n) dur=60s events=\(input.events.count): total=\(f2(total))ms first=\(f3(firstWall))ms avg=\(f3(total / Double(n)))ms rssDelta=\(mb(udiff(m1.rss, m0.rss)))MB peak=\(mb(m1.peak))MB mallocSizeDelta=\(m1.sizeInUse - m0.sizeInUse)B blocksDelta=\(m1.blocks - m0.blocks) perCycleBytes=\((m1.sizeInUse - m0.sizeInUse) / n)")
}

// MARK: - 5. per-frame evaluation cost / frame budget (policy mirror of FrameBudget)

func evalBatch(_ tl: Timeline, _ n: Int, grid: Double) -> (usPerCall: Double, worstUs: Double, over60: Int, over240: Int, pageFaults: UInt64) {
    let m0 = mem(); let t0 = uptimeNS()
    var sink = 0.0
    var worst: UInt64 = 0
    var over60 = 0, over240 = 0
    for i in 0..<n {
        let a = uptimeNS()
        let f = tl.evaluate(at: Double(i % Int(grid * 16)) / grid)
        let b = uptimeNS()
        let ns = b - a
        if ns > worst { worst = ns }
        let ms = Double(ns) / 1e6
        if ms > 16.6 { over60 += 1 }
        if ms > 1000.0 / 240.0 { over240 += 1 }
        sink += Double(f.cameraScale) + Double(f.cameraCenter.x)
    }
    let t1 = uptimeNS(); let m1 = mem()
    precondition(sink.isFinite && sink != 0)
    let per = Double(t1 - t0) / Double(n) / 1000.0
    return (per, Double(worst) / 1000.0, over60, over240, udiff(m1.pageFaults, m0.pageFaults))
}

func modeEval() {
    let tl = deriveOnce(60.0, clicks: 200, moveRate: 20)
    for _ in 0..<2 { _ = evalBatch(tl, 5000, grid: 240) }
    let r = evalBatch(tl, 40_000, grid: 240)
    print("EVAL 40k calls @240fps grid (60s/200click timeline): \(f3(r.usPerCall))us/call total=\(f2(r.usPerCall * 40_000 / 1000))ms worst=\(f3(r.worstUs))us over60fps=\(r.over60) over240fps=\(r.over240) pageFaults=\(r.pageFaults)")
}

func makeOverlayTimeline(_ base: Timeline) -> Timeline {
    var with = base
    for i in 0..<4 {
        let s = Double(i) * 0.5, e = 30.0
        with.overlays.masks.append(Mask(start: s, end: e, keys: [MaskKey(t: s, x: 100, y: 100, w: 400, h: 200), MaskKey(t: e, x: 120, y: 110, w: 400, h: 200)]))
        with.overlays.highlights.append(Highlight(start: s, end: e, x: 200, y: 200, w: 500, h: 300))
        with.overlays.loupes.append(Loupe(start: s, end: e))
        with.overlays.texts.append(TextBlock(start: s, end: e, text: "hello"))
    }
    return with
}

func modeEvalScale() {
    for (d, c) in [(10.0, 33), (60.0, 200), (300.0, 1000)] {
        let base = deriveOnce(d, clicks: c)
        let with = makeOverlayTimeline(base)
        for _ in 0..<2 { _ = evalBatch(base, 3000, grid: 240); _ = evalBatch(with, 3000, grid: 240) }
        let a = evalBatch(base, 20_000, grid: 240)
        let b = evalBatch(with, 20_000, grid: 240)
        print("EVAL-SCALE dur=\(Int(d))s clicks=\(c) camSamples=\(base.derived?.camera.nx.count ?? -1): none=\(f3(a.usPerCall))us 4x4overlays=\(f3(b.usPerCall))us delta=\(f3(b.usPerCall - a.usPerCall))us over60none=\(a.over60) over60overlays=\(b.over60)")
    }
}

/// O(overlays) per-frame cost: 500 text edits leave 100 text blocks, and
/// Timeline.evaluate -> Emphasis.evaluate linearly scans every block every
/// frame and allocates four result arrays. Measure the growth directly.
func modeEvalOverlayScale() {
    let base = deriveOnce(60.0, clicks: 200, moveRate: 20)
    print("mode,textBlocks,usPerCall,mallocDelta_bytes,blocksDelta,over60")
    for count in [0, 25, 50, 100, 200] {
        var tl = base
        for i in 0..<count {
            tl.overlays.texts.append(TextBlock(start: 0, end: 60, text: "block-\(i)"))
        }
        for _ in 0..<2 { _ = evalBatch(tl, 2000, grid: 240) }
        let m0 = mem(); let t0 = uptimeNS()
        var sink = 0.0
        let n = 12_000
        for i in 0..<n { sink += Double(tl.evaluate(at: Double(i % 3840) / 240.0).cameraScale) }
        let t1 = uptimeNS(); let m1 = mem()
        precondition(sink.isFinite)
        let per = Double(t1 - t0) / Double(n) / 1000.0
        print("EVAL-OVERLAY-SCALE,\(count),\(f3(per)),\(m1.sizeInUse - m0.sizeInUse),\(m1.blocks - m0.blocks),0")
    }
}

/// 240 fps render-grid budget for a 60-minute project: 3600*240 = 864,000 frames.
/// We sample the evaluation cost and extrapolate, and report the time to walk
/// the entire 240 fps frame index without rendering pixels (CPU-only lower bound).
func modeFrame240() {
    let tl = deriveOnce(60.0, clicks: 200, moveRate: 20)
    let frames = 60 * 240
    let t0 = uptimeNS()
    var sink = 0.0
    for i in 0..<frames { sink += Double(tl.evaluate(at: Double(i) / 240.0).cameraScale) }
    let t1 = uptimeNS()
    precondition(sink.isFinite)
    let ms = Double(t1 - t0) / 1e6
    let usPerFrame = ms * 1000 / Double(frames)
    print("FRAME240 evaluate-only frames=\(frames) wall=\(f2(ms))ms usPerFrame=\(f3(usPerFrame)) budget60fps=16600us budget240fps=\(f2(1000.0/240.0*1000))us verdict=\(usPerFrame > 1000.0/240.0*1000 ? "OVER_240_BUDGET" : "CPU_WITHIN_BUDGET")")
    let full60min = frames * 60
    print("FRAME240 full60min_frames=\(full60min) extrapolatedEvaluateSeconds=\(f2(ms * 60 / 1000)) (CPU timeline evaluation only; excludes GPU/encode)")
}

// MARK: - 6. 4K export frame-plan math (real ExportPreset/capability measured in the test target)

func modeExport4k() {
    // Mirror of ExportPreset.width(aspect:) + Exporter.run total-frame math.
    let height = 2160, fps = 240, aspect = 16.0 / 9
    let width = ((Int((Double(height) * aspect).rounded()) + 1) & ~1)
    print("EXPORT4K preset=4k240-\(height)p width=\(width) height=\(height) fps=\(fps)")
    for duration in [60.0, 600.0, 3600.0] {
        let total = max(Int(ceil(duration * Double(fps) - 1e-8)), 1)
        let bytesPerFrame = width * height * 4
        print("EXPORT4K duration=\(Int(duration))s totalFrames=\(total) rawRGBA_GB=\(f2(Double(total * bytesPerFrame) / 1e9)) bitrateAtBpp006_Mbps=\(f2(Double(width * height * fps) * 0.06 / 1e6))")
    }
    print("EXPORT4K NOTE real AVAssetWriter encode + capability probe measured in VideoEditPerformanceTests (LumenExport linked there); standalone tool links Core/Project/Director only.")
}

// MARK: - dispatch

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
switch mode {
case "derive60": modeDerive60()
case "derive-scale": modeDeriveScale()
case "edits": modeEdits()
case "edit-scale": modeEditScale()
case "redrive": modeRedrive()
case "eval": modeEval()
case "eval-scale": modeEvalScale()
case "eval-overlay-scale": modeEvalOverlayScale()
case "frame240": modeFrame240()
case "export4k": modeExport4k()
case "all":
    modeDerive60(); modeDeriveScale(); modeEdits(); modeEditScale()
    modeRedrive(); modeEval(); modeEvalScale(); modeEvalOverlayScale(); modeFrame240(); modeExport4k()
default:
    print("unknown mode \(mode)")
}
