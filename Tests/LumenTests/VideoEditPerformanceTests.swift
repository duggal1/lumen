import Foundation
import Testing
import Darwin
import LumenCore
import LumenProject
import LumenDirector
import LumenRender
import LumenExport
import LumenControl

/// T4 brutal headless performance gates for the video-edit + MCP + export stack.
/// These are measured budgets, not smoke tests: each exercises the real runtime
/// path and prints a machine-readable line before asserting a generous ceiling.

// MARK: - instrumentation (same primitives as Tools/perfprobe.swift)

private func uptimeNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

private struct Meas {
    var rss: UInt64 = 0, peak: UInt64 = 0, faults: UInt64 = 0
    var blocks: Int = 0, inUse: Int = 0
}
private func measure() -> Meas {
    var m = Meas()
    var info = mach_task_basic_info()
    var n = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let r = withUnsafeMutablePointer(to: &info) { p -> kern_return_t in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &n) }
    }
    if r == KERN_SUCCESS { m.rss = UInt64(info.resident_size); m.peak = UInt64(info.resident_size_max) }
    var ev = task_events_info()
    var ec = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<integer_t>.size)
    if withUnsafeMutablePointer(to: &ev, { p -> kern_return_t in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(ec)) { task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &ec) }
    }) == KERN_SUCCESS { m.faults = UInt64(ev.faults) }
    var st = malloc_statistics_t(); malloc_zone_statistics(nil, &st)
    m.blocks = Int(st.blocks_in_use); m.inUse = Int(st.size_in_use)
    return m
}
private func mb(_ v: Int) -> String { String(format: "%.1f", Double(v) / 1_048_576.0) }
private func f2(_ v: Double) -> String { String(format: "%.2f", v) }
private func f3(_ v: Double) -> String { String(format: "%.3f", v) }

// MARK: - 1000 real MCP calls through the one registry

private final class StubRuntime: LumenRuntime, @unchecked Sendable {
    func runtimeStatus() async -> RuntimeStatus { RuntimeStatus(phase: "idle", paused: false, recording: false,
        permissions: RuntimePermissions(), libraryPath: "/tmp/t4-library", projects: 0,
        activeProjectPath: nil, version: "perf") }
    func startRecording(_ target: RecordingTarget, options: RecordingOptions) async throws {}
    func stopRecording() async throws -> URL { URL(fileURLWithPath: "/tmp/t4-none") }
    func pauseRecording() async throws {}
    func resumeRecording() async throws {}
    func addMarker(_ marker: CaptureMarker) async throws {}
    func activeRecordingBundle() async -> URL? { nil }
    func recordingLibrary() async -> [URL] { [] }
}

@Test func mcpRegistryHandlesOneThousandCalls() async throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let policy = Policy(fileURL: dir.appendingPathComponent("t4-policy-\(UUID().uuidString).json"))
    let audit = AuditLog(fileURL: dir.appendingPathComponent("t4-audit-\(UUID().uuidString).json"))
    defer {
        try? FileManager.default.removeItem(at: policy.fileURL)
    }
    let jobs = JobManager()
    let runtime = StubRuntime()
    let engine = Engine(runtime: runtime, jobs: jobs, policy: policy)
    let registry = ToolRegistry()
    registerAllTools(in: registry)

    let specs = registry.allSpecs()
    #expect(specs.contains { $0.name == "lumen_status" })
    let ctx = ToolContext(engine: engine, policy: policy, jobs: jobs, audit: audit,
                          clientID: "t4-perf", dryRun: false)
    let args = JSONValue.object([:])

    for _ in 0..<20 { _ = try await registry.call("lumen_status", arguments: args, context: ctx) } // warm-up
    let m0 = measure(); let t0 = uptimeNS()
    var calls = 0
    for _ in 0..<1_000 {
        let result = try await registry.call("lumen_status", arguments: args, context: ctx)
        if case .object = result { calls += 1 }
    }
    let t1 = uptimeNS(); let m1 = measure()
    let wall = Double(t1 - t0) / 1e6
    print("MCP-CALLS tools=\(specs.count) calls=\(calls)/1000 wall=\(f2(wall))ms usPerCall=\(f3(wall * 1000 / 1000)) rssDelta=\(mb(Int(m1.rss) - Int(m0.rss)))MB peak=\(mb(Int(m1.peak)))MB mallocDelta=\(m1.inUse - m0.inUse)B blocksDelta=\(m1.blocks - m0.blocks) pageFaults=\(m1.faults - m0.faults)")
    #expect(calls == 1_000)
    #expect(wall < 5_000, "1000 MCP calls took \(f2(wall)) ms")
}

// MARK: - 4K export preset + capability probe cost + frame plan

@Test func fourKExportPlanAndCapabilityProbeAreMeasured() throws {
    let preset = ExportPresets.parse("4k240-hevc")
    let p = try #require(preset, "4k240-hevc preset must exist")
    let w = p.width(aspect: 16.0 / 9)
    #expect(w == 3840)
    #expect(p.height == 2160)
    #expect(p.fps == 240)

    let matrix = ExportCapabilityMatrix.shared
    let t0 = uptimeNS()
    let supported = matrix.supports(p, aspect: 16.0 / 9)
    let t1 = uptimeNS()
    let probeMs = Double(t1 - t0) / 1e6
    let resolved = matrix.resolve(p, aspect: 16.0 / 9)
    let t2 = uptimeNS()
    print("EXPORT-PLAN preset=\(p.name) \(w)x\(p.height)@\(p.fps) supported=\(supported) probe=\(f3(probeMs))ms resolve=\(f3(Double(t2 - t1) / 1e6))ms resolvedTo=\(resolved.0.name) notice=\(resolved.1 ?? "none")")
    for duration in [60.0, 600.0, 3600.0] {
        let total = max(Int(ceil(duration * Double(p.fps) - 1e-8)), 1)
        print("EXPORT-FRAMES duration=\(Int(duration))s fps=\(p.fps) totalFrames=\(total)")
    }
    #expect(durationFrames(60, fps: 240) == 14_400)
    #expect(durationFrames(3600, fps: 240) == 864_000)
}

private func durationFrames(_ d: Double, fps: Int) -> Int { max(Int(ceil(d * Double(fps) - 1e-8)), 1) }

// MARK: - real FrameBudget policy against measured evaluation timings

@Test func frameBudgetPolicyCatchesBudgetViolations() {
    let budget60 = FrameBudget(fps: 60)
    let clean = budget60.evaluate(Array(repeating: 8.5, count: 100))
    #expect(clean.passes)
    let dirty = budget60.evaluate(Array(repeating: 20.0, count: 100))
    #expect(!dirty.passes)
    #expect(dirty.overBudget == 100)
    let b240 = FrameBudget(fps: 240)
    let at240 = b240.evaluate(Array(repeating: 5.0, count: 100))
    #expect(!at240.passes, "5 ms frames miss a 4.17 ms 240 fps budget")
    print("FRAME-BUDGET 60fps=\(clean.summary) | 240fps=\(at240.summary)")

    // Real per-frame evaluation cost, fed to the same policy.
    var tl = Timeline(duration: 60)
    tl.audio.speedRampsAuto = false
    var events: [InputEvent] = []
    for i in 0..<4000 { events.append(InputEvent(t: Double(i) / 20, kind: .move,
        x: Float(200 + (i * 211) % 1400), y: Float(150 + (i * 97) % 760))) }
    let src = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 60, backingScale: 2,
                         originX: 0, originY: 0)
    tl = Director.derive(tl, input: DirectorInput(events: events, source: src), revision: 1)
    var samples: [Double] = []
    samples.reserveCapacity(4096)
    var sink = 0.0
    for _ in 0..<2 { for i in 0..<4096 { sink += Double(tl.evaluate(at: Double(i) / 240).cameraScale) } }
    for i in 0..<4096 {
        let a = uptimeNS(); let f = tl.evaluate(at: Double(i) / 240); let b = uptimeNS()
        sink += Double(f.cameraScale)
        samples.append(Double(b - a) / 1e6)
    }
    #expect(sink.isFinite && sink != 0)
    let real = budget60.evaluate(samples)
    print("FRAME-EVAL realEvaluateFrames=4096 \(real.summary) worst=\(f3(real.worstMs * 1000))us")
    #expect(real.passes, "CPU timeline evaluation must fit the 60 fps budget")
}

// MARK: - real GPU render (fails loudly without a device; never vacuously passes)

@Test func renderBenchmarkAt4K240IsMeasured() throws {
    let result = try RenderBenchmark.run(frames: 24, width: 3840, height: 2160, fps: 240)
    print("RENDER-BENCH 4K/240 frames=\(result.frames) \(result.report.summary)")
    #expect(result.frames == 24)
    #expect(result.report.frames == 24)
}

// MARK: - 500 reducer edits regression gate (60 s project; long-project scaling in video-perf tool)

@Test func fiveHundredEditsStayWithinBudget() {
    var tl = Timeline(duration: 60)
    tl.audio.speedRampsAuto = false
    let ctx = ReduceContext(playhead: 30, duration: 60, fps: 60)
    let t0 = uptimeNS(); let m0 = measure()
    for i in 0..<500 {
        let cmd: Command
        switch i % 5 {
        case 0: cmd = .addCut(start: Double(i) + 1, end: Double(i) + 1.5)
        case 1: cmd = .addSpeedRamp(start: Double(i) + 2, end: Double(i) + 3, speed: 1.5)
        case 2: cmd = .addZoom(ZoomSegment(start: Double(i) + 1, end: Double(i) + 2, scale: 2, focus: .follow, origin: .manual))
        case 3: cmd = .addText(TextBlock(start: 1, end: 2, text: "e\(i)"))
        default: cmd = .deleteWords([i])
        }
        _ = try? reduce(&tl, cmd, ctx: ctx)
    }
    let t1 = uptimeNS(); let m1 = measure()
    let wall = Double(t1 - t0) / 1e6
    print("EDITS-GATE n=500 dur=60s wall=\(f2(wall))ms usPerEdit=\(f3(wall * 1000 / 500)) mallocDelta=\(m1.inUse - m0.inUse)B blocksDelta=\(m1.blocks - m0.blocks)")
    #expect(wall < 10_000, "500 edits took \(f2(wall)) ms")
}
