import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
import LumenDirector

// MARK: - Headless intelligent-crop verification
//
// Everything here drives `Timeline.evaluate(at:)`, the same call preview and
// export use. No window, no render, no interaction.

enum CropProbe {
    static func source(_ w: Int, _ h: Int, _ dur: Double, scale: Double = 2) -> SourceInfo {
        SourceInfo(width: w, height: h, fps: 60, duration: dur, backingScale: scale,
                   originX: 0, originY: 0)
    }

    /// The page content region; the browser's tabs and address bar live above it.
    static let content = CGRect(x: 200, y: 120, width: 1400, height: 850)
    /// The address bar: a resolved AX element just above the content.
    static let chrome = CGRect(x: 520, y: 24, width: 700, height: 34)
    static let sourceBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    static let expectedContent = SmartCropPlanner.aspectFit(content, source: sourceBounds)

    static func normalized(_ r: CGRect, _ src: SourceInfo) -> CGRect {
        CGRect(x: r.minX / Double(src.width), y: r.minY / Double(src.height),
               width: r.width / Double(src.width), height: r.height / Double(src.height))
    }

    static func click(_ t: Double, in rect: CGRect, _ ax: inout [AXFrame]) -> [InputEvent] {
        ax.append(AXFrame(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height,
                          anchor: FocusAnchor(epoch: 1, sampledAt: t, resolved: true)))
        let idx = UInt32(ax.count)
        return [InputEvent(t: t, kind: .down, x: Float(rect.midX), y: Float(rect.midY), button: 0, axFrameIndex: idx),
                InputEvent(t: t + 0.04, kind: .up, x: Float(rect.midX), y: Float(rect.midY), button: 0)]
    }

    static func derive(duration: Double, w: Int = 1920, h: Int = 1080, scale: Double = 2,
                       roi: CGRect? = content, events: [InputEvent] = [], ax: [AXFrame] = [],
                       typing: [TypingTrace] = [], trimStart: Double = 0,
                       ramp: SpeedRamp? = nil, enabled: Bool = true,
                       margin: Double = 24, ret: Double = 0.45) -> Timeline {
        let src = source(w, h, duration, scale: scale)
        var tl = Timeline(duration: duration)
        tl.audio.speedRampsAuto = false
        if trimStart > 0 || ramp != nil {
            tl.timeMap = TimeMap(sourceDuration: duration, trimStart: trimStart,
                                 trimEnd: duration, ramps: ramp.map { [$0] } ?? [])
        }
        if let roi {
            tl.smartCrop = SmartCropConfig(enabled: enabled, roi: normalized(roi, src),
                                           revealMarginPt: margin, returnSeconds: ret)
        }
        let input = DirectorInput(events: events.sorted { $0.t < $1.t }, source: src,
                                  ax: ax, typing: typing)
        return Director.derive(tl, input: input, revision: 1)
    }

    static func crop(_ tl: Timeline, at t: Double) -> CGRect { tl.evaluate(at: t).cropRect }
    static func near(_ a: CGRect, _ b: CGRect, tol: CGFloat = 0.05) -> Bool {
        abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol &&
        abs(a.width - b.width) < tol && abs(a.height - b.height) < tol
    }
}

@Suite struct BrutalSmartCropTests {

    /// Default state is the tight content crop. This is the whole point of the
    /// feature: no tabs, no address bar, no browser chrome in the exported frame.
    @Test func defaultIsTheContentCropAndEndsThere() {
        var ax: [AXFrame] = []
        let tl = CropProbe.derive(duration: 6, events: CropProbe.click(2, in: CropProbe.chrome, &ax), ax: ax)
        let before = CropProbe.crop(tl, at: 1.0)
        let after = CropProbe.crop(tl, at: 5.9)
        #expect(CropProbe.near(before, CropProbe.expectedContent), "before: \(before)")
        #expect(CropProbe.near(after, CropProbe.expectedContent), "after: \(after)")
        // Chrome must not be visible in the default crop.
        #expect(before.intersection(CropProbe.chrome).isNull)
    }

    /// A resolved click in the address bar reveals chrome, arrives exactly one
    /// frame after the settle, holds, and returns to the content crop.
    @Test(arguments: [60.0, 120.0, 240.0])
    func chromeClickRevealsThenRecrops(fps: Double) {
        var ax: [AXFrame] = []
        let tl = CropProbe.derive(duration: 6, events: CropProbe.click(2, in: CropProbe.chrome, &ax), ax: ax)
        let src = CropProbe.source(1920, 1080, 6)
        let wanted = SmartCropPlanner.aspectFit(
            SmartCropPlanner.revealRect(for: CropProbe.chrome, roi: CropProbe.expectedContent,
                                        config: SmartCropConfig(enabled: true,
                                                                roi: CropProbe.normalized(CropProbe.content, src),
                                                                revealMarginPt: 24),
                                        backingScale: 2).intersection(CropProbe.sourceBounds),
            source: CropProbe.sourceBounds)
        let arrived = CropProbe.crop(tl, at: 2 + 1 / fps)
        for (lhs, rhs) in [(arrived.minX, wanted.minX), (arrived.minY, wanted.minY),
                           (arrived.width, wanted.width), (arrived.height, wanted.height)] {
            #expect(abs(lhs - rhs) < 0.75, "arrival \(lhs) != \(rhs)")
        }
        #expect(arrived.contains(CropProbe.chrome))
        #expect(arrived.contains(CropProbe.content))
        // Held still through the interaction.
        for t in stride(from: 2.02, through: 2.10, by: 1 / fps) {
            let c = CropProbe.crop(tl, at: t)
            #expect(abs(c.minX - arrived.minX) < 0.5 && abs(c.width - arrived.width) < 0.5,
                    Comment(rawValue: "drift at \(t): \(c)"))
        }
        // Back to exactly the content crop after the return window.
        let restored = CropProbe.crop(tl, at: 3.2)
        #expect(CropProbe.near(restored, CropProbe.expectedContent), "restored: \(restored)")
    }

    /// Clicking inside the page must never reveal chrome.
    @Test func contentClickDoesNotReveal() {
        var ax: [AXFrame] = []
        let inside = CGRect(x: 600, y: 400, width: 200, height: 60)
        let tl = CropProbe.derive(duration: 5, events: CropProbe.click(2, in: inside, &ax), ax: ax)
        for t in stride(from: 1.5, through: 3.0, by: 1 / 60) {
            #expect(CropProbe.near(CropProbe.crop(tl, at: t), CropProbe.expectedContent), Comment(rawValue: "revealed at \(t)"))
        }
    }

    /// Trim and a 2x speed ramp must not shift the reveal off its frame. The
    /// crop keyframes are in output seconds and are converted at plan time.
    @Test func trimAndRampKeepTheRevealOnItsFrame() {
        var ax: [AXFrame] = []
        let tl = CropProbe.derive(duration: 10, events: CropProbe.click(5, in: CropProbe.chrome, &ax),
                                  ax: ax, trimStart: 2, ramp: SpeedRamp(start: 4, end: 6, speed: 2))
        let atClick = tl.timeMap.output(atSource: 5)
        let c = CropProbe.crop(tl, at: atClick)
        #expect(c.contains(CropProbe.chrome), Comment(rawValue: "at \(atClick): \(c)"))
        #expect(CropProbe.near(CropProbe.crop(tl, at: tl.timeMap.output(atSource: 9)), CropProbe.expectedContent))
    }

    /// Rapid chrome interactions are one continuous widened shot, not a pump.
    @Test func overlappingRevealsMergeIntoOneWindow() {
        var ax: [AXFrame] = []
        var events: [InputEvent] = []
        for t in [1.5, 1.8, 2.1] { events += CropProbe.click(t, in: CropProbe.chrome, &ax) }
        let tl = CropProbe.derive(duration: 6, events: events, ax: ax)
        var returns = 0
        var previous = CropProbe.crop(tl, at: 1.4)
        for t in stride(from: 1.5, through: 3.4, by: 1 / 120) {
            let c = CropProbe.crop(tl, at: t)
            if CropProbe.near(c, CropProbe.content), !CropProbe.near(previous, CropProbe.content) { returns += 1 }
            previous = c
        }
        #expect(returns <= 1, "crop pumped \(returns) times")
        #expect(CropProbe.near(CropProbe.crop(tl, at: 3.4), CropProbe.expectedContent))
    }

    /// No teleports, and the crop never shows canvas outside the source.
    @Test func cropIsContinuousAndInsideSource() {
        var rng = BrutalRng(99)
        for seed in 1...60 {
            var ax: [AXFrame] = []
            var events: [InputEvent] = []
            for _ in 0..<rng.i(1, 5) {
                let t = rng.d(0.5, 7)
                let r = CGRect(x: rng.d(0, 1400), y: rng.chance(0.5) ? rng.d(0, 100) : rng.d(200, 800),
                               width: rng.d(80, 300), height: rng.d(20, 80))
                events += CropProbe.click(t, in: r, &ax)
            }
            let tl = CropProbe.derive(duration: 8, events: events, ax: ax)
            let cam = tl.derived?.camera
            let rate = cam?.rate ?? 480
            var previous = CropProbe.crop(tl, at: 0)
            for k in 1...Int(7.9 * rate) {
                let t = Double(k) / rate
                let c = CropProbe.crop(tl, at: t)
                if c.minX < -0.5 || c.minY < -0.5 || c.maxX > 1920.5 || c.maxY > 1080.5 {
                    #expect(Bool(false), Comment(rawValue: "seed \(seed): crop outside source at \(t): \(c)"))
                    break
                }
                let jump = max(abs(c.minX - previous.minX), abs(c.minY - previous.minY),
                               abs(c.width - previous.width), abs(c.height - previous.height)) / 1920
                if jump > 0.02 {
                    #expect(Bool(false), Comment(rawValue: "seed \(seed): jump \(jump) at \(t)"))
                    break
                }
                previous = c
            }
        }
    }

    /// Warm and cold derives must agree on crop VALUES. DerivedTracks.==
    /// compares only revision, so equality on the tracks would be vacuous.
    @Test func cacheNeverServesAStaleCrop() {
        var ax: [AXFrame] = []
        let events = CropProbe.click(2, in: CropProbe.chrome, &ax)
        let src = CropProbe.source(1920, 1080, 6)
        func make(_ config: SmartCropConfig, _ cache: inout DeriveCache) -> Timeline {
            var tl = Timeline(duration: 6)
            tl.audio.speedRampsAuto = false
            tl.smartCrop = config
            return Director.derive(tl, input: DirectorInput(events: events, source: src, ax: ax),
                                   revision: 1, cache: &cache)
        }
        let config = SmartCropConfig(enabled: true, roi: CropProbe.normalized(CropProbe.content, src),
                                     revealMarginPt: 24, returnSeconds: 0.45)
        var warm = DeriveCache()
        let a = make(config, &warm)
        let b = make(config, &warm)
        let times = stride(from: 0.0, through: 5.0, by: 0.1).map { $0 }
        for t in times {
            #expect(CropProbe.near(CropProbe.crop(a, at: t), CropProbe.crop(b, at: t)), Comment(rawValue: "warm/cold differ at \(t)"))
        }
        var other = config
        other.roi = CropProbe.normalized(CGRect(x: 300, y: 200, width: 1000, height: 600), src)
        let c = make(other, &warm)
        #expect(!CropProbe.near(CropProbe.crop(a, at: 2.1), CropProbe.crop(c, at: 2.1)), "ROI-only change was ignored")
    }

    /// Degenerate evidence must degrade to a clean full-frame crop, never NaN.
    @Test func degenerateInputsStayFinite() {
        let src = CropProbe.source(1920, 1080, 5)
        func check(_ name: String, _ tl: Timeline) {
            for t in stride(from: 0.0, through: 4.9, by: 0.1) {
                let c = CropProbe.crop(tl, at: t)
                guard c.origin.x.isFinite, c.origin.y.isFinite,
                      c.width.isFinite, c.height.isFinite, c.width >= 0, c.height >= 0 else {
                    #expect(Bool(false), Comment(rawValue: "\(name): bad crop at \(t): \(c)")); return
                }
            }
        }
        check("nil-roi", CropProbe.derive(duration: 5, roi: nil))
        check("disabled", CropProbe.derive(duration: 5, enabled: false))
        check("1x1-source", CropProbe.derive(duration: 5, w: 1, h: 1, roi: CGRect(x: 0, y: 0, width: 1, height: 1)))
        var nanAx: [AXFrame] = []
        let nanEvents = CropProbe.click(1.5, in: CGRect(x: CGFloat.nan, y: 20, width: CGFloat.nan, height: 30), &nanAx)
        check("nan-rect", CropProbe.derive(duration: 5, events: nanEvents, ax: nanAx))
        var lateAx: [AXFrame] = []
        check("click-at-trim-end", CropProbe.derive(duration: 5, events: CropProbe.click(4.9, in: CropProbe.chrome, &lateAx), ax: lateAx))
    }

    @Test func cropPlanIsCheap() {
        var ax: [AXFrame] = []
        var events: [InputEvent] = []
        for i in 0..<200 {
            let t = 0.2 + Double(i) * 0.29
            events += CropProbe.click(t, in: i % 2 == 0 ? CropProbe.chrome : CropProbe.content, &ax)
        }
        let start = Date()
        let tl = CropProbe.derive(duration: 60, events: events, ax: ax)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 20, "derive took \(elapsed)s")
        var sink: CGFloat = 0
        let t0 = Date()
        for i in 0..<40_000 { sink += CropProbe.crop(tl, at: Double(i % 3600) / 60).minX }
        let per = Date().timeIntervalSince(t0) / 40_000 * 1e6
        #expect(sink.isFinite)
        #expect(per < 400, "evaluate took \(per)µs")
    }

    /// The live preview is causal: it cannot know a reveal is coming, but once
    /// the chrome interaction is observed it must settle to the offline rect.
    @Test func livePreviewConvergesToThePlannedCrop() {
        let src = CropProbe.source(1920, 1080, 6)
        // Zero margin keeps the live (point-scale) and offline (backing-scale)
        // reveal rectangles identical so the test measures convergence only.
        let config = SmartCropConfig(enabled: true, roi: CropProbe.normalized(CropProbe.content, src),
                                     revealMarginPt: 0, returnSeconds: 1.0)
        var live = LiveCamera(source: SIMD2<Double>(Double(src.width), Double(src.height)), smartCrop: config)
        let frame = AXFrame(x: CropProbe.chrome.minX, y: CropProbe.chrome.minY,
                            w: CropProbe.chrome.width, h: CropProbe.chrome.height,
                            anchor: FocusAnchor(epoch: 1, sampledAt: 2, resolved: true))
        let key = InputEvent(t: 2, kind: .keyDown, keyCode: 0, axFrameIndex: 1)
        live.ingest(key, focus: frame)
        var state = live.step(to: 2)
        for t in stride(from: 2.004, through: 2.8, by: 1 / 240) { state = live.step(to: t) }
        let tm = TimeMap(sourceDuration: 6)
        let track = SmartCropPlanner.plan(config: config, source: src, tm: tm,
                                          intents: [SmartCropIntent(t: 2, tEnd: 2.12, rect: CropProbe.chrome)])
        let offline = track.evaluate(at: 2.1)
        #expect(CropProbe.near(state.cropRect, offline, tol: 1.0),
                Comment(rawValue: "live \(state.cropRect) != offline \(offline)"))
    }
}
