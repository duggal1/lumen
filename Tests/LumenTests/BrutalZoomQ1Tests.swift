import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - Q1 brutal cache + hostile mixed fuzz (headless)
//
// Verifies the two claims that matter for browser crop and typing: label/appName
// changes invalidate a warm replan, and 500 hostile mixed sessions keep every
// camera/crop invariant under trims, cuts, ramps and NaN AX frames.

@Suite struct BrutalZoomQ1Tests {
    private let W = 1920.0, H = 1080.0

    private func source(_ dur: Double = 10, scale: Double = 2) -> SourceInfo {
        SourceInfo(width: Int(W), height: Int(H), fps: 60, duration: dur,
                   backingScale: scale, originX: 0, originY: 0)
    }

    private func browserAX(_ app: String) -> [AXFrame] {
        let resolved = { (sampled: Double) in FocusAnchor(epoch: 1, sampledAt: sampled,
                                                          appName: app, resolved: true) }
        return [
            AXFrame(x: 0, y: 0, w: W, h: H,
                    label: "window|AXWindow|AXStandardWindow|\(app)", anchor: resolved(0)),
            AXFrame(x: 0, y: 0, w: W, h: 36, label: "New Tab", anchor: resolved(0)),
            AXFrame(x: 300, y: 44, w: 800, h: 34,
                    label: app.lowercased().contains("safari")
                        ? "Search or enter website name" : "Address and search bar",
                    anchor: resolved(1.5)),
        ]
    }

    /// The parent fix claimed AX labels and appName are hashed into the derive
    /// digest. Verify it by changing ONLY those strings: a warm cache must not
    /// serve the browser crop from the previous input.
    @Test func changingOnlyAXLabelOrAppNameInvalidatesCachedCrop() {
        let base = browserAX("Google Chrome")
        var plain: [AXFrame] = []
        for f in base {
            var g = f
            g.label = f.label?.replacingOccurrences(of: "Google Chrome", with: "TextEdit")
            g.anchor = FocusAnchor(epoch: 1, sampledAt: f.anchor?.sampledAt ?? 0,
                                   appName: "TextEdit", resolved: true)
            plain.append(g)
        }
        let inputA = DirectorInput(events: [], source: source(), ax: base)
        let inputB = DirectorInput(events: [], source: source(), ax: plain)
        var tl = Timeline(duration: 10)
        tl.audio.speedRampsAuto = false

        let coldA = Director.derive(tl, input: inputA, revision: 1)
        let coldB = Director.derive(tl, input: inputB, revision: 1)
        #expect((coldA.derived?.crop.keys.isEmpty ?? true) == false, "precondition: browser crop missing")
        #expect((coldB.derived?.crop.keys.isEmpty ?? true) == true, "precondition: non-browser crop exists")

        var cache = DeriveCache()
        _ = Director.derive(tl, input: inputA, revision: 1, cache: &cache)
        let warmB = Director.derive(tl, input: inputB, revision: 1, cache: &cache)
        #expect(warmB.derived?.crop == coldB.derived?.crop,
                "warm cache served a stale browser crop after a label/appName-only change")
    }

    /// One scenario per seed: clean browser chrome, hostile AX frames, typing
    /// into chrome and into a page field, a dialog, passive activity, plus a
    /// random trim/cut/ramp time map. Every documented invariant is checked.
    @Test func fiveHundredSeedHostileMixedSessionsHoldEveryInvariant() {
        var failures: [String] = []
        for seed in UInt64(1)...500 {
            let s = Q1Scenario.make(seed: seed)
            let tl = Q1Scenario.derive(s)
            guard let cam = tl.derived?.camera else {
                failures.append("seed \(seed): no camera"); continue
            }
            let maxScale = min(max(s.tl.camera.maxScale, 1.001), 6.0)
            let n = cam.lz.count
            var bad = false
            for k in cam.lz.indices {
                let z = Double(cam.lz[k]), x = Double(cam.nx[k]), y = Double(cam.ny[k])
                if !z.isFinite || !x.isFinite || !y.isFinite {
                    failures.append("seed \(seed): non-finite camera at \(k)"); bad = true; break
                }
                if z < -1e-6 || exp(z) > maxScale * 1.001 {
                    failures.append("seed \(seed): scale cap at \(k): \(z)"); bad = true; break
                }
                let half = 0.5 / exp(max(z, 0))
                if x < half - 2e-5 || x > 1 - half + 2e-5 ||
                   y < half - 2e-5 || y > 1 - half + 2e-5 {
                    failures.append("seed \(seed): infeasible centre at \(k)"); bad = true; break
                }
            }
            if bad { continue }
            for k in 1..<n {
                if abs(Double(cam.nx[k]) - Double(cam.nx[k - 1])) > 0.02 ||
                   abs(Double(cam.ny[k]) - Double(cam.ny[k - 1])) > 0.02 {
                    failures.append("seed \(seed): camera teleport at \(k)"); break
                }
            }
            if abs(Double(cam.lz[n - 1])) > 1e-4 {
                failures.append("seed \(seed): ends zoomed")
            }
            let shots = tl.zoom.sorted { $0.start < $1.start }
            for k in 1..<max(shots.count, 1) where shots[k].start < shots[k - 1].end - 1e-6 {
                failures.append("seed \(seed): overlapping shots")
            }
            for sh in shots where sh.end - sh.start > 4.0 {
                if sh.end - sh.start > 6.7 {
                    failures.append("seed \(seed): shot > 6.5s")
                } else if case .element = sh.focus {} else {
                    failures.append("seed \(seed): >4s shot without a subject")
                }
            }
            // Crop: finite, inside source, source aspect, continuous.
            let bounds = CGRect(x: 0, y: 0, width: W, height: H)
            let aspect = W / H
            for key in tl.derived!.crop.keys {
                if !key.rect.origin.x.isFinite || !key.rect.size.width.isFinite ||
                   key.rect.width / max(key.rect.height, 1) - aspect > 0.02 ||
                   key.rect.minX < -0.5 || key.rect.minY < -0.5 ||
                   key.rect.maxX > W + 0.5 || key.rect.maxY > H + 0.5 {
                    failures.append("seed \(seed): bad crop key \(key.rect)"); break
                }
                _ = bounds
            }
            // Sample near the track's native rate. A 0.18 s reveal can cross the
            // whole frame; at 60 Hz that legitimate quintic is indistinguishable
            // from a jump. At 240 Hz a real discontinuity is still unmistakable.
            var prev = tl.evaluate(at: 0).cropRect
            for k in 1..<Int(Double(s.dur - 0.2) * 240) {
                let c = tl.evaluate(at: Double(k) / 240).cropRect
                guard c.origin.x.isFinite, c.width.isFinite else {
                    failures.append("seed \(seed): non-finite crop at \(k)"); break
                }
                if c.minX < -0.5 || c.minY < -0.5 || c.maxX > W + 0.5 || c.maxY > H + 0.5 {
                    failures.append("seed \(seed): crop outside source at \(k)"); break
                }
                let jump = max(abs(c.minX - prev.minX), abs(c.minY - prev.minY),
                               abs(c.width - prev.width), abs(c.height - prev.height)) / W
                if jump > 0.05 {
                    failures.append("seed \(seed): crop jump \(jump) at \(k)"); break
                }
                prev = c
            }
            if seed % 10 == 0 {
                let again = Q1Scenario.derive(s)
                if again.derived?.camera != cam || again.zoom != tl.zoom {
                    failures.append("seed \(seed): replay differs")
                }
            }
            if failures.count > 12 { break }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
}

// MARK: - Scenario generator

enum Q1Scenario {
    struct Scenario: Sendable {
        let dur: Double
        let tl: Timeline
        let input: DirectorInput
    }

    static func make(seed: UInt64) -> Scenario {
        var r = BrutalRng(seed &* 0x9E3779B97F4A7C15)
        let dur = r.d(6.0, 12.0)
        var tl = Timeline(duration: dur)
        tl.audio.speedRampsAuto = false
        tl.camera.autoZoom = true
        tl.camera.maxScale = r.d(1.5, 3.0)
        var tm = TimeMap(sourceDuration: dur)
        tm.trimStart = r.d(0, 0.8)
        tm.trimEnd = dur - r.d(0, 0.6)
        if r.chance(0.6) {
            let a = r.d(1.0, dur - 2.0)
            tm.cuts = [CutRange(start: a, end: a + r.d(0.2, 0.8))]
        }
        if r.chance(0.6) {
            let a = r.d(1.0, dur - 2.0)
            tm.ramps = [SpeedRamp(start: a, end: a + r.d(0.6, 1.6), speed: r.d(1.6, 3.0))]
        }
        tl.timeMap = tm

        let app = r.chance(0.5) ? "Google Chrome" : "Safari"
        var ax = [
            AXFrame(x: 0, y: 0, w: 1920, h: 1080,
                    label: "window|AXWindow|AXStandardWindow|\(app)",
                    anchor: FocusAnchor(epoch: 1, sampledAt: 0, appName: app, resolved: true)),
            AXFrame(x: 0, y: 0, w: 1920, h: 36, label: "New Tab",
                    anchor: FocusAnchor(epoch: 1, sampledAt: 0, appName: app, resolved: true)),
            AXFrame(x: 300, y: 44, w: 800, h: 34,
                    label: app == "Safari" ? "Search or enter website name" : "Address and search bar",
                    anchor: FocusAnchor(epoch: 2, sampledAt: 1.5, appName: app, resolved: true)),
        ]
        // Hostile AX: unknown provenance, NaN, negative, huge, stale and windows.
        for _ in 0..<r.i(0, 3) {
            ax.append(AXFrame(x: r.d(-5000, 5000), y: r.d(-5000, 5000),
                              w: r.d(-40, 1e4), h: r.d(-40, 1e4),
                              label: r.chance(0.5) ? "Address and search bar" : nil,
                              anchor: FocusAnchor(epoch: UInt32(r.i(0, 9)),
                                                  sampledAt: r.chance(0.3) ? .nan : r.d(0, dur),
                                                  appName: r.chance(0.5) ? app : nil,
                                                  resolved: r.chance(0.5))))
        }
        var events: [InputEvent] = []
        var activity: [ActivityPoint] = []
        var markers: [DirectorMarker] = []
        var t = 1.0
        while t < dur - 1.0 {
            switch r.i(0, 5) {
            case 0:  // typing into the address bar (chrome interaction)
                let n = r.i(3, 12)
                for k in 0..<n {
                    events.append(InputEvent(t: t + Double(k) * 0.11, kind: .keyDown,
                                             keyCode: UInt16(k % 40), axFrameIndex: 3))
                }
                t += r.d(1.3, 2.2)
            case 1:  // typing into a page field
                let rect = CGRect(x: r.d(200, 1200), y: r.d(150, 800),
                                  width: r.d(200, 500), height: r.d(28, 90))
                var f = AXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height,
                                anchor: FocusAnchor(epoch: 3, sampledAt: t, resolved: true))
                f.caret = AXFrame.Rect(x: rect.minX + 6, y: rect.minY + 6, w: 2, h: 20)
                ax.append(f)
                let idx = UInt32(ax.count)
                for k in 0..<r.i(3, 9) {
                    events.append(InputEvent(t: t + Double(k) * 0.12, kind: .keyDown,
                                             keyCode: UInt16(k % 40), axFrameIndex: idx))
                }
                t += r.d(1.2, 2.0)
            case 2:  // chrome click (tab strip / address bar)
                events.append(InputEvent(t: t, kind: .down,
                                         x: Float(r.d(200, 1600)), y: Float(r.d(0, 70)),
                                         button: 0, axFrameIndex: r.chance(0.5) ? 2 : 3))
                t += r.d(0.4, 1.0)
            case 3:  // dialog appears
                let rect = CGRect(x: r.d(400, 800), y: r.d(220, 420),
                                  width: r.d(400, 700), height: r.d(300, 500))
                var d = AXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height,
                                label: "window|AXSheet|dialog",
                                anchor: FocusAnchor(epoch: 4, sampledAt: t, appName: app, resolved: true))
                d.sampledAt = t
                ax.append(d)
                events.append(InputEvent(t: t, kind: .down, axFrameIndex: UInt32(ax.count)))
                markers.append(DirectorMarker(start: t, end: t + 0.5))
                t += r.d(1.0, 1.7)
            default:  // visual activity plus an ordinary page click
                activity.append(ActivityPoint(t: t, x: r.d(200, 1700), y: r.d(150, 1000),
                                              region: CGRect(x: r.d(200, 1200), y: r.d(150, 700),
                                                             width: r.d(80, 400), height: r.d(80, 300)),
                                              coverage: r.d(0, 0.4)))
                events.append(InputEvent(t: t, kind: .down,
                                         x: Float(r.d(200, 1700)), y: Float(r.d(150, 1000)), button: 0))
                t += r.d(0.5, 1.2)
            }
        }
        let input = DirectorInput(events: events.sorted { $0.t < $1.t },
                                  source: SourceInfo(width: 1920, height: 1080, fps: 60,
                                                     duration: dur, backingScale: 2,
                                                     originX: 0, originY: 0),
                                  ax: ax, activity: activity, markers: markers)
        return Scenario(dur: dur, tl: tl, input: input)
    }

    static func derive(_ s: Scenario) -> Timeline {
        Director.derive(s.tl, input: s.input, revision: 1)
    }
}
