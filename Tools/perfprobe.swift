// Headless perf/memory probe for Lumen. Links against the built module .o files.
// Usage: perfprobe <mode>   (derive | derive-scale | eval | eval-scale | eval-overlays | leak | cli-like)
import Foundation
import CoreGraphics
import Darwin
import LumenCore
import LumenProject
import LumenDirector

// MARK: - instrumentation

func uptimeNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

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
func udiff(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : 0 }

// MARK: - scenario builders (mirror Tests/LumenTests/PerformanceTests.swift + BrutalZoomSweepTests.swift)

func makeInput(_ duration: Double, _ clicks: Int) -> DirectorInput {
    var events: [InputEvent] = []
    if clicks > 0 {
        let span = max(duration - 1.0, 0.5)
        for i in 0..<clicks {
            let t = 0.3 + Double(i) * span / Double(clicks)
            let x = 300.0 + Double((i * 211) % 1200)
            let y = 200.0 + Double((i * 97) % 600)
            events.append(InputEvent(t: t, kind: .move, x: Float(x), y: Float(y)))
            events.append(InputEvent(t: t, kind: .down, x: Float(x), y: Float(y), button: 0))
            events.append(InputEvent(t: t + 0.04, kind: .up, x: Float(x), y: Float(y), button: 0))
        }
    }
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: duration,
                         backingScale: 2, originX: 0, originY: 0)
    return DirectorInput(events: events.sorted { $0.t < $1.t }, source: src)
}

func makeTimeline(_ duration: Double) -> Timeline {
    var tl = Timeline(duration: duration)
    tl.audio.speedRampsAuto = false
    tl.camera.maxScale = 2.0
    tl.camera.autoZoom = true
    return tl
}

func deriveOnce(_ duration: Double, _ clicks: Int) -> Timeline {
    var cache = DeriveCache()
    return Director.derive(makeTimeline(duration), input: makeInput(duration, clicks), revision: 1, cache: &cache)
}

// MARK: - modes

func modeDerive() {
    let d = 60.0, c = 200
    _ = deriveOnce(d, c) // warm up
    let m0 = mem()
    let t0 = uptimeNS()
    let out = deriveOnce(d, c)
    let t1 = uptimeNS()
    let m1 = mem()
    print("DERIVE 60s/200click: wall=\(Double(t1 - t0) / 1e6)ms peakRSS=\(mb(m1.peak))MB rssDelta=\(mb(udiff(m1.rss, m0.rss)))MB pageFaultsDelta=\(udiff(m1.pageFaults, m0.pageFaults)) blocksDelta=\(Int(m1.blocks) - Int(m0.blocks)) sizeInUseDelta=\(Int(m1.sizeInUse) - Int(m0.sizeInUse))B camSamples=\(out.derived?.camera.nx.count ?? -1) zooms=\(out.zoom.count)")
}

func modeDeriveScale() {
    for (d, c) in [(10.0, 33), (30.0, 100), (60.0, 200), (120.0, 400), (300.0, 1000)] {
        _ = deriveOnce(d, c)
        let m0 = mem(); let t0 = uptimeNS()
        let out = deriveOnce(d, c)
        let t1 = uptimeNS(); let m1 = mem()
        let ms = Double(t1 - t0) / 1e6
        print("DERIVE-SCALE dur=\(Int(d))s clicks=\(c): \(String(format: "%.2f", ms))ms  msPerSec=\(String(format: "%.3f", ms / d))  peakRSS=\(mb(m1.peak))MB  camSamples=\(out.derived?.camera.nx.count ?? -1)")
    }
}

func evalBatch(_ tl: Timeline, _ n: Int) -> (Double, UInt64, UInt64, Int, Int) {
    let m0 = mem(); let t0 = uptimeNS()
    var sink = 0.0
    for i in 0..<n {
        let f = tl.evaluate(at: Double(i % 960) / 60.0)
        sink += Double(f.cameraScale) + Double(f.cameraCenter.x)
    }
    let t1 = uptimeNS(); let m1 = mem()
    if !sink.isFinite || sink == 0 { print("BAD sink=\(sink) finite=\(sink.isFinite)") }
    let per = Double(t1 - t0) / Double(n) / 1000.0  // nanoseconds -> microseconds per call
    return (per, udiff(m1.pageFaults, m0.pageFaults), udiff(m1.rss, m0.rss), Int(m1.blocks) - Int(m0.blocks), Int(m1.sizeInUse) - Int(m0.sizeInUse))
}

func modeEval() {
    let tl = deriveOnce(60.0, 200)
    for _ in 0..<2 { _ = evalBatch(tl, 5000) } // warm up
    let (per, rec, rss, blocks, size) = evalBatch(tl, 40_000)
    print("EVAL 40k calls (60s/200click timeline): \(String(format: "%.3f", per))us/call  total=\(String(format: "%.1f", per * 40_000 / 1000))ms  pageFaults=\(rec)  rssDelta=\(mb(rss))MB  blocksDelta=\(blocks)  sizeInUseDelta=\(size)B")
}

func modeEvalScale() {
    for (d, c) in [(10.0, 33), (60.0, 200), (300.0, 1000)] {
        let tl = deriveOnce(d, c)
        for _ in 0..<2 { _ = evalBatch(tl, 3000) }
        let (per, rec, _, _, _) = evalBatch(tl, 40_000)
        print("EVAL-SCALE dur=\(Int(d))s clicks=\(c) camSamples=\(tl.derived?.camera.nx.count ?? -1): \(String(format: "%.3f", per))us/call  pageFaults=\(rec)")
    }
}

func modeEvalOverlays() {
    let base = deriveOnce(60.0, 200)
    var with = base
    // 4 masks + 4 highlights + 4 loupes + 4 texts, each active across the sampled window
    for i in 0..<4 {
        let s = Double(i) * 0.5, e = 30.0
        with.overlays.masks.append(Mask(start: s, end: e, keys: [MaskKey(t: s, x: 100, y: 100, w: 400, h: 200), MaskKey(t: e, x: 120, y: 110, w: 400, h: 200)]))
        with.overlays.highlights.append(Highlight(start: s, end: e, x: 200, y: 200, w: 500, h: 300))
        with.overlays.loupes.append(Loupe(start: s, end: e))
        with.overlays.texts.append(TextBlock(start: s, end: e, text: "hello"))
    }
    for _ in 0..<2 { _ = evalBatch(base, 5000); _ = evalBatch(with, 5000) }
    let a = evalBatch(base, 40_000)
    let b = evalBatch(with, 40_000)
    print("EVAL-OVERLAYS none: \(String(format: "%.3f", a.0))us/call pageFaults=\(a.1)")
    print("EVAL-OVERLAYS 4x(mask/highlight/loupe/text): \(String(format: "%.3f", b.0))us/call pageFaults=\(b.1)  delta=\(String(format: "%.3f", b.0 - a.0))us/call")
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

func modeAlloc() {
    let base = deriveOnce(60.0, 200)
    let with = makeOverlayTimeline(base)
    let n = 5_000
    for (label, tl) in [("none", base), ("4x4 overlays", with)] {
        let m0 = mem()
        var held: [FrameState] = []
        held.reserveCapacity(n)
        var sink = 0.0
        for i in 0..<n {
            let f = tl.evaluate(at: Double(i % 960) / 60.0)
            held.append(f)
            sink += Double(f.cameraScale)
        }
        let m1 = mem()
        let bytesPerCall = Double(m1.sizeInUse - m0.sizeInUse) / Double(n)
        let blocksPerCall = Double(m1.blocks - m0.blocks) / Double(n)
        print("ALLOC \(label): retained=\(n) sizeInUseDelta=\(m1.sizeInUse - m0.sizeInUse)B blocksDelta=\(m1.blocks - m0.blocks) => \(String(format: "%.1f", bytesPerCall)) bytes/call, \(String(format: "%.2f", blocksPerCall)) blocks/call  (sink=\(String(format: "%.1f", sink)))")
        withExtendedLifetime(held) {}
    }
}

func modeLeak() {
    let n = 120
    let m0 = mem()
    print("LEAK start rss=\(mb(m0.rss))MB peak=\(mb(m0.peak))MB blocks=\(m0.blocks) sizeInUse=\(m0.sizeInUse)")
    for i in 1...n {
        autoreleasepool {
            let tl = deriveOnce(60.0, 200)
            var sink = 0.0
            for k in 0..<5000 { sink += Double(tl.evaluate(at: Double(k % 960) / 60.0).cameraScale) }
            precondition(sink.isFinite)
        }
        if i % 10 == 0 {
            let m = mem()
            print("LEAK iter=\(i) rss=\(mb(m.rss))MB peak=\(mb(m.peak))MB blocks=\(m.blocks) sizeInUse=\(m.sizeInUse) pageFaults=\(m.pageFaults)")
        }
    }
    let m1 = mem()
    print("LEAK end rss=\(mb(m1.rss))MB delta=\(mb(udiff(m1.rss, m0.rss)))MB blocksDelta=\(Int(m1.blocks) - Int(m0.blocks)) sizeInUseDelta=\(Int(m1.sizeInUse) - Int(m0.sizeInUse))B perIterBytes=\((m1.sizeInUse - m0.sizeInUse) / n)")
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
switch mode {
case "derive": modeDerive()
case "derive-scale": modeDeriveScale()
case "eval": modeEval()
case "eval-scale": modeEvalScale()
case "eval-overlays": modeEvalOverlays()
case "alloc": modeAlloc()
case "leak": modeLeak()
default:
    modeDerive(); modeDeriveScale(); modeEval(); modeEvalScale(); modeEvalOverlays()
}
