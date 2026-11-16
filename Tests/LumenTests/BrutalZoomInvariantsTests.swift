import Foundation
import Testing
import LumenCore
import LumenProject
import LumenDirector

// MARK: - Deterministic randomness
//
// Every scenario is generated from a seed, so a failure names a seed that can be
// replayed. Nothing here depends on wall-clock time or the order tests run in.

struct BrutalRng {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func d(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * unit() }
    mutating func i(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(max(hi - lo + 1, 1))) }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
}

// MARK: - Scenario generation

enum BrutalScenario {
    static func source(_ w: Int, _ h: Int, _ scale: Double, _ dur: Double) -> SourceInfo {
        SourceInfo(width: w, height: h, fps: 60, duration: dur, backingScale: scale, originX: 0, originY: 0)
    }

    /// A mixed session: pointer motion, clicks (some with accessibility frames),
    /// typing bursts, drags, visual activity and marker beats. Deliberately
    /// includes near-duplicate clicks, clicks at the very start and end, and
    /// bursts that touch each other.
    static func make(seed: UInt64) -> (input: DirectorInput, duration: Double) {
        var r = BrutalRng(seed)
        let dur = r.d(2.0, 10.0)
        let w = [1280, 1600, 1920, 2560, 3840][r.i(0, 4)]
        let h = [720, 900, 1080, 1440, 2160][r.i(0, 4)]
        let scale = [1.0, 2.0, 3.0][r.i(0, 2)]
        let src = source(w, h, scale, dur)
        let W = Double(w), H = Double(h)

        var events: [InputEvent] = []
        var ax: [AXFrame] = []

        // Pointer motion.
        for _ in 0..<r.i(5, 60) {
            events.append(InputEvent(t: r.d(0, dur), kind: .move,
                                     x: Float(r.d(0, W)), y: Float(r.d(0, H))))
        }
        // Clicks, half of them carrying a resolved control frame.
        for _ in 0..<r.i(0, 5) {
            let cx = r.d(0, W), cy = r.d(0, H)
            var idx: UInt32 = 0
            if r.chance(0.5) {
                let fw = r.d(20, min(W * 0.5, 900)), fh = r.d(16, min(H * 0.4, 300))
                let fx = max(0, min(cx - fw / 2 + r.d(-30, 30), W - fw))
                let fy = max(0, min(cy - fh / 2 + r.d(-20, 20), H - fh))
                var frame = AXFrame(x: fx, y: fy, w: fw, h: fh,
                                    anchor: FocusAnchor(epoch: UInt32(r.i(0, 9)),
                                                        sampledAt: r.d(0, dur),
                                                        resolved: r.chance(0.85)))
                frame.sampledAt = r.d(0, dur)
                frame.caret = AXFrame.Rect(x: fx + r.d(2, max(fw - 4, 3)), y: fy + 4, w: 2, h: min(fh - 8, 24))
                ax.append(frame)
                idx = UInt32(ax.count)
            }
            events.append(InputEvent(t: r.d(0, dur), kind: .down, x: Float(cx), y: Float(cy),
                                     button: 0, axFrameIndex: idx))
            events.append(InputEvent(t: r.d(0, dur), kind: .up, x: Float(cx), y: Float(cy), button: 0))
        }
        // Drags.
        for _ in 0..<r.i(0, 2) {
            let t = r.d(0, max(dur - 0.4, 0.1))
            events.append(InputEvent(t: t, kind: .drag, x: Float(r.d(0, W)), y: Float(r.d(0, H))))
            events.append(InputEvent(t: t + 0.2, kind: .drag, x: Float(r.d(0, W)), y: Float(r.d(0, H))))
        }
        // Typing bursts, each on its own text field.
        var typing: [TypingTrace] = []
        for _ in 0..<r.i(0, 2) {
            let t0 = r.d(0.5, max(dur - 1.2, 0.6))
            let keys = r.i(3, 14)
            let fw = r.d(160, min(W * 0.8, 900)), fh = r.d(28, 120)
            let fx = r.d(0, W - fw), fy = r.d(0, H - fh)
            var frame = AXFrame(x: fx, y: fy, w: fw, h: fh,
                                anchor: FocusAnchor(epoch: 1, sampledAt: t0, resolved: true))
            frame.sampledAt = t0
            frame.caret = AXFrame.Rect(x: fx + r.d(2, fw - 4), y: fy + 4, w: 2, h: min(fh - 8, 24))
            ax.append(frame)
            var samples: [TypingTrace.Sample] = []
            for k in 0..<keys {
                let t = t0 + Double(k) * r.d(0.05, 0.4)
                events.append(InputEvent(t: t, kind: .keyDown, keyCode: UInt16(k % 40),
                                         axFrameIndex: UInt32(ax.count)))
                samples.append(TypingTrace.Sample(t: t, x: fx + r.d(2, fw - 2), y: fy + fh / 2,
                                                  confidence: Float(r.d(0.2, 0.99))))
            }
            typing.append(TypingTrace(t0: t0, t1: samples.last?.t ?? t0,
                                      rect: CGRect(x: fx, y: fy, width: fw, height: fh),
                                      samples: samples,
                                      line: CGRect(x: fx, y: fy + fh / 2 - 12, width: fw, height: 24)))
        }
        // Visual activity, sometimes with a region.
        var activity: [ActivityPoint] = []
        for _ in 0..<r.i(0, 20) {
            let hasRegion = r.chance(0.5)
            let region = hasRegion ? CGRect(x: r.d(0, W * 0.7), y: r.d(0, H * 0.7),
                                            width: r.d(20, W * 0.3), height: r.d(20, H * 0.3)) : nil
            activity.append(ActivityPoint(t: r.d(0, dur), x: r.d(0, W), y: r.d(0, H),
                                          region: region, coverage: r.d(0, 1)))
        }
        // Markers, some with a rect.
        var markers: [DirectorMarker] = []
        for _ in 0..<r.i(0, 3) {
            let t = r.d(0, max(dur - 0.3, 0.1))
            let rect: CGRect? = r.chance(0.7)
                ? CGRect(x: r.d(0, 0.6), y: r.d(0, 0.6), width: r.d(0.02, 0.35), height: r.d(0.02, 0.35))
                : nil
            markers.append(DirectorMarker(start: t, end: t + r.d(0.1, 0.8), rect: rect))
        }

        return (DirectorInput(events: events, source: src, ax: ax, activity: activity,
                              typing: typing, markers: markers), dur)
    }

    static func derive(_ input: DirectorInput, _ dur: Double, cache: inout DeriveCache) -> Timeline {
        var tl = Timeline(duration: dur)
        tl.audio.speedRampsAuto = false
        return Director.derive(tl, input: input, revision: 1, cache: &cache)
    }

    static func derive(_ input: DirectorInput, _ dur: Double) -> Timeline {
        var c = DeriveCache()
        return derive(input, dur, cache: &c)
    }
}

// MARK: - Invariants every derived camera must satisfy

enum BrutalCheck {
    /// Returns human-readable failures. Empty means the track is clean.
    static func camera(_ tl: Timeline, maxScale: Double, label: String) -> [String] {
        var bad: [String] = []
        guard let cam = tl.derived?.camera else { return ["\(label): no camera track"] }
        let n = cam.lz.count
        guard n >= 1 else { return ["\(label): empty camera track"] }
        guard cam.nx.count == n, cam.ny.count == n, cam.vx.count == n, cam.ax.count == n else {
            return ["\(label): channel length mismatch"]
        }
        let tol = 2e-6

        for i in 0..<n {
            let z = Double(cam.lz[i])
            let x = Double(cam.nx[i]), y = Double(cam.ny[i])
            if !z.isFinite || !x.isFinite || !y.isFinite {
                bad.append("\(label): non-finite camera at \(i) (z=\(z) x=\(x) y=\(y))")
                break
            }
            // Scale never drops below 1x and never exceeds the configured cap.
            if z < -1e-6 { bad.append("\(label): scale below 1x at \(i): lz=\(z)"); break }
            if Foundation.exp(z) > maxScale * 1.001 {
                bad.append("\(label): scale \(Foundation.exp(z)) exceeds cap \(maxScale) at \(i)"); break
            }
            // The frame never shows empty canvas.
            let half = 0.5 / Foundation.exp(max(z, 0))
            if x < half - tol || x > 1 - half + tol || y < half - tol || y > 1 - half + tol {
                bad.append("\(label): centre (\(x), \(y)) outside feasible box \(half) at \(i)")
                break
            }
        }

        // The recording must end on the full frame, centred.
        let last = n - 1
        if Double(cam.lz[last]) > 1e-5 {
            bad.append("\(label): ends zoomed at \(Foundation.exp(Double(cam.lz[last])))x")
        }
        if abs(Double(cam.nx[last]) - 0.5) > 1e-5 || abs(Double(cam.ny[last]) - 0.5) > 1e-5 {
            bad.append("\(label): ends off-centre at (\(cam.nx[last]), \(cam.ny[last]))")
        }

        // One camera, one target: two shots may never claim the same instant.
        // An overlap is not a cosmetic detail — the solver writes the track in a
        // single ordered pass, so two shots covering the same frame means one of
        // them is silently overwritten mid-curve.
        let shots = tl.zoom.sorted { $0.start < $1.start }
        for k in 1..<max(shots.count, 1) {
            guard shots[k].start < shots[k - 1].end - 1e-6 else { continue }
            bad.append(String(format: "%@: overlapping shots [%.2f-%.2f] and [%.2f-%.2f]",
                              label, shots[k - 1].start, shots[k - 1].end, shots[k].start, shots[k].end))
            break
        }

        // No per-tick teleports. 0.02 normalized in one 1/480 s tick is ~10
        // screen-widths per second, far above any legitimate pan.
        for i in 1..<n {
            let dx = abs(Double(cam.nx[i]) - Double(cam.nx[i - 1]))
            let dy = abs(Double(cam.ny[i]) - Double(cam.ny[i - 1]))
            if dx > 0.02 || dy > 0.02 {
                bad.append("\(label): teleport at \(i) (dx=\(dx) dy=\(dy))"); break
            }
        }
        return bad
    }
}

// MARK: - Tests

@Suite struct BrutalZoomInvariantsTests {
    /// 200 seeded sessions, every invariant checked on each. A failure prints the
    /// seed, which reproduces the exact scenario.
    @Test func fuzzInvariantsHold() {
        var failures: [String] = []
        for seed in 1...200 {
            let (input, dur) = BrutalScenario.make(seed: UInt64(seed))
            let tl = BrutalScenario.derive(input, dur)
            let maxScale = tl.camera.maxScale
            failures += BrutalCheck.camera(tl, maxScale: maxScale, label: "seed \(seed)")
            if failures.count > 8 { break }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) invariant failures:\n" + failures.joined(separator: "\n")))
    }

    /// Deriving twice must be byte-identical. Determinism is the contract that
    /// makes the cache legal at all.
    @Test func derivationIsDeterministic() {
        for seed in 1...20 {
            let (input, dur) = BrutalScenario.make(seed: UInt64(seed))
            let a = BrutalScenario.derive(input, dur)
            let b = BrutalScenario.derive(input, dur)
            #expect(a.derived?.camera == b.derived?.camera, "seed \(seed): camera differs between runs")
            #expect(a.zoom == b.zoom, "seed \(seed): zoom differs between runs")
        }
    }

    /// A warm cache must never be observably different from a cold derive.
    /// This is the single test that catches any field missing from the digest:
    /// mutate something the planner reads, derive warm, derive cold, compare.
    @Test func cacheNeverServesAStalePlan() {
        var failures: [String] = []
        for seed in 1...60 {
            let (base, dur) = BrutalScenario.make(seed: UInt64(seed))
            guard !base.ax.isEmpty || !base.events.isEmpty else { continue }

            var cache = DeriveCache()
            _ = BrutalScenario.derive(base, dur, cache: &cache)

            for (name, mutated) in BrutalMutation.all(base, seed: UInt64(seed)) {
                let warm = BrutalScenario.derive(mutated, dur, cache: &cache)
                let cold = BrutalScenario.derive(mutated, dur)
                if warm.derived?.camera != cold.derived?.camera || warm.zoom.map(\.start) != cold.zoom.map(\.start) {
                    failures.append("seed \(seed) mutation \(name): warm plan != cold plan")
                }
                // Warm the cache with the mutated input for the next mutation.
                cache = DeriveCache()
                _ = BrutalScenario.derive(mutated, dur, cache: &cache)
            }
            if failures.count > 5 { break }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
}

/// Mutations of exactly the fields the planner is supposed to read. If the
/// digest misses one, the warm derive returns the old plan and differs from the
/// cold derive.
enum BrutalMutation {
    static func all(_ base: DirectorInput, seed: UInt64) -> [(String, DirectorInput)] {
        var r = BrutalRng(seed &* 31)
        var out: [(String, DirectorInput)] = []
        func add(_ name: String, _ mutate: (inout DirectorInput) -> Void) {
            var copy = base
            mutate(&copy)
            out.append((name, copy))
        }
        add("event-x") { if !$0.events.isEmpty { $0.events[0].x += Float(r.d(40, 400)) } }
        add("event-t") { if !$0.events.isEmpty { $0.events[0].t += r.d(0.1, 1.0) } }
        add("ax-frame") { if !$0.ax.isEmpty { $0.ax[0].x += r.d(30, 300); $0.ax[0].w += r.d(-10, 60) } }
        add("ax-caret") { if !$0.ax.isEmpty {
            let f = $0.ax[0]
            $0.ax[0].caret = AXFrame.Rect(x: f.x + r.d(1, max(f.w - 2, 2)), y: f.y + 4, w: 2, h: 20)
        } }
        add("ax-anchor") { if !$0.ax.isEmpty {
            $0.ax[0].anchor = FocusAnchor(epoch: 7, sampledAt: r.d(0, 5), resolved: true)
        } }
        add("typing-rect") { if !$0.typing.isEmpty, var rect = $0.typing[0].rect {
            rect.size.height = r.d(20, 90); $0.typing[0].rect = rect
        } }
        add("typing-line") { if !$0.typing.isEmpty, var line = $0.typing[0].line {
            line.origin.y += r.d(10, 120); $0.typing[0].line = line
        } }
        add("typing-confidence") { if !$0.typing.isEmpty, !$0.typing[0].samples.isEmpty {
            $0.typing[0].samples[0].confidence = 0.05
        } }
        add("typing-samples") { if !$0.typing.isEmpty {
            $0.typing[0].samples.append(TypingTrace.Sample(t: ($0.typing[0].samples.last?.t ?? 1) + 0.1,
                                                           x: r.d(0, 900), y: r.d(0, 600), confidence: 0.9))
        } }
        add("activity") { if !$0.activity.isEmpty {
            $0.activity[0].coverage = 1 - ($0.activity[0].coverage ?? 0.5)
            $0.activity[0].x += r.d(10, 200)
        } }
        add("marker") { if !$0.markers.isEmpty {
            $0.markers[0].rect = CGRect(x: r.d(0, 0.5), y: r.d(0, 0.5),
                                        width: r.d(0.05, 0.3), height: r.d(0.05, 0.3))
        } }
        add("source-scale") { $0.source.backingScale = $0.source.backingScale == 2 ? 3 : 2 }
        return out
    }
}
