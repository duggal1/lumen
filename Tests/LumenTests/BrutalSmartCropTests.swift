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
    /// A resolved click in the address bar reveals chrome, arrives exactly one
    /// Trim and a 2x speed ramp must not shift the reveal off its frame. The
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

}
