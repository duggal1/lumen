import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
import LumenCapture
@testable import LumenDirector

/// A4 — auto-crop fixtures: crop rect computation from fixture window
/// geometries. Pure CropPlanner + ChromeDetector assertions; no wall clock.
@Suite struct AutoCropFixtureTests {
    static let source = PxRect(x: 0, y: 0, w: 1920, h: 1080)

    static func makeSamples(_ t0: Double, _ t1: Double, web: PxRect?, window: PxRect,
                            front: Bool = true) -> [ViewportSample] {
        var out: [ViewportSample] = []
        var t = t0
        while t <= t1 + 1e-9 {
            var flags: ViewportRecord.Flags = [.browserFront]
            let w = web ?? PxRect(x: 0, y: 0, w: 0, h: 0)
            if w.w > 0 && w.h > 0 { flags.insert(.webValid) }
            out.append(ViewportSample(ViewportRecord(t: t, flags: flags, window: window, web: w)))
            t += 0.1
        }
        return out
    }

    static func plan(_ samples: [ViewportSample], _ settings: CropSettings = CropSettings(),
                     source: PxRect = AutoCropFixtureTests.source) -> ViewportCropPlan {
        CropPlanner.plan(samples: samples, inputs: CropInputs(keys: [], uiClicks: []),
                         duration: 10, source: source, settings: settings)
    }

    /// Chrome detected = dense (≥ 0.75) rows/cols; page = sparse (0.05).
    /// Fixture grid: top chrome rows 0–1, bottom rows 8–9, left cols 0–2, right cols 7–9.
    @Test func detectorFindsContentBandsInEdgeGrid() {
        var edges = [Float](repeating: 0.05, count: 100)
        for c in 0..<10 {
            edges[0 * 10 + c] = 0.9; edges[1 * 10 + c] = 0.9
            edges[8 * 10 + c] = 0.9; edges[9 * 10 + c] = 0.9
        }
        for r in 0..<10 {
            for c in [0, 1, 2, 7, 8, 9] { edges[r * 10 + c] = 0.9 }
        }
        let r = ChromeDetector.contentRect(edges: edges, gridW: 10, gridH: 10,
                                           window: PxRect(x: 0, y: 0, w: 100, h: 50),
                                           s: ChromeDetector.Settings(chromeThreshold: 0.75, minExtent: 1))
        #expect(r == PxRect(x: 30, y: 10, w: 40, h: 30), "\(String(describing: r))")
    }

    @Test func detectorReturnsNilWhenGridIsAllChrome() {
        let dense = [Float](repeating: 0.9, count: 100)
        let r = ChromeDetector.contentRect(edges: dense, gridW: 10, gridH: 10,
                                           window: PxRect(x: 0, y: 0, w: 100, h: 50),
                                           s: ChromeDetector.Settings(chromeThreshold: 0.75, minExtent: 1))
        #expect(r == nil, "\(String(describing: r))")
    }

    @Test func widePageExcludesChromeAndPreservesBothSidebars() {
        let web = PxRect(x: 100, y: 100, w: 800, h: 300)
        let samples = Self.makeSamples(0, 10, web: web, window: Self.source)
        let actual = Self.plan(samples).track.rect(at: 5)
        #expect(actual == PxRect(x: 102, y: 102, w: 796, h: 296))
    }

    /// A web area already within 0.5% of the source aspect passes through
    /// unchanged — the historical AXWebArea geometry stays the crop.
    @Test func aspectFitKeepsNearSourceAspectRectsUnchanged() {
        let web = PxRect(x: 0, y: 0, w: 1920, h: 1080)
        let samples = Self.makeSamples(0, 10, web: web, window: PxRect(x: 0, y: 0, w: 1920, h: 1080))
        let p = Self.plan(samples)
        let r = p.track.rect(at: 5)
        let expected = PxRect(x: 2, y: 2, w: 1916, h: 1076)
        #expect(abs(r.x - expected.x) < 0.5 && abs(r.y - expected.y) < 0.5 &&
                abs(r.w - expected.w) < 0.5 && abs(r.h - expected.h) < 0.5,
                "\(r) != \(expected)")
    }

    /// A full-display web area crops to the full source.
    @Test func fullDisplayWebCropsToFullSource() {
        let samples = Self.makeSamples(0, 10, web: PxRect(x: 0, y: 0, w: 1920, h: 1080),
                                       window: PxRect(x: 0, y: 0, w: 1920, h: 1080))
        let r = Self.plan(samples).track.rect(at: 5)
        #expect(abs(r.x - 2) < 1 && abs(r.y - 2) < 1 &&
                abs(r.w - 1916) < 1 && abs(r.h - 1076) < 1, "\(r)")
    }

    @Test func wideWebContentIsClampedIntoSource() {
        let web = PxRect(x: 0, y: 0, w: 2400, h: 900)
        let samples = Self.makeSamples(0, 10, web: web, window: Self.source)
        #expect(Self.plan(samples).track.rect(at: 5) == PxRect(x: 2, y: 2, w: 1918, h: 896))
    }

    @Test func missingViewportObservationsExpireAndRecover() {
        let page = PxRect(x: 0, y: 90, w: 1920, h: 990)
        let initial = Self.makeSamples(0, 1, web: page, window: Self.source)
        let resumed = Self.makeSamples(5, 7, web: page, window: Self.source)
        let crop = Self.plan(initial + resumed).track
        #expect(crop.rect(at: 0.5).y > 89)
        #expect(crop.rect(at: 4) == Self.source)
        #expect(crop.rect(at: 6.5).y > 89)
        #expect(crop.rect(at: 9) == Self.source)
    }

    @Test func singleAddressBarKeyRevealsChromeUnderDefaultPolicy() {
        let page = PxRect(x: 0, y: 90, w: 1920, h: 990)
        var samples = Self.makeSamples(0, 8, web: page, window: Self.source)
        for i in samples.indices { samples[i].ui = (2...2.5).contains(samples[i].t) }
        let plan = CropPlanner.plan(samples: samples, inputs: CropInputs(keys: [2.1], uiClicks: []),
                                    duration: 8, source: Self.source, settings: CropSettings())
        #expect(plan.track.rect(at: 1).y > 89)
        #expect(plan.track.rect(at: 2.6).y < 1)
        #expect(plan.track.rect(at: 6).y > 89)
    }

    /// Manual override: `CropSettings.overrides` produce `.window` spans in the
    /// plan's change list during [start, end).
    @Test func manualOverrideIsHonored() {
        let web = PxRect(x: 100, y: 100, w: 800, h: 300)
        var settings = CropSettings()
        settings.overrides = [CropOverride(start: 2.0, end: 3.0, mode: .window)]
        let samples = Self.makeSamples(0, 10, web: web, window: PxRect(x: 0, y: 0, w: 1920, h: 1080))
        let p = Self.plan(samples, settings)
        #expect(p.changes.contains { $0.mode == .window }, "\(p.changes)")
        if let wc = p.changes.first(where: { $0.mode == .window }) {
            #expect(abs(wc.start - 2.0) < 0.01, "\(wc)")
        }
    }

    /// Multi-display: crops computed for a display whose coords are the source
    /// origin preserve the visible page bounds.
    @Test func multiDisplayCropsStayInSource() {
        let window = PxRect(x: 60, y: 30, w: 1200, h: 800)
        let web = PxRect(x: 100, y: 50, w: 1000, h: 400)
        let samples = Self.makeSamples(0, 10, web: web, window: window)
        let r = Self.plan(samples, source: Self.source).track.rect(at: 5)
        #expect(r.isValid, "\(r)")
        #expect(r.x >= -0.5 && r.y >= -0.5 && r.maxX <= 1920.5 && r.maxY <= 1080.5, "\(r)")
        #expect(abs(r.aspect - 996.0 / 396.0) < 0.001, "\(r.aspect)")
    }

    /// Jitter on the web rect must not produce jumping crops: the track is
    /// smoothed (CropPlanner series), and consecutive tick rects move little.
    @Test func jitterySamplesProduceStableTrack() {
        let window = PxRect(x: 0, y: 0, w: 1920, h: 1080)
        var samples: [ViewportSample] = []
        for k in 0...50 {
            let jx = 3 * sin(Double(k) * 0.9), jy = 3 * cos(Double(k) * 1.4)
            let web = PxRect(x: 500 + jx, y: 400 + jy, w: 800, h: 450)
            samples.append(ViewportSample(ViewportRecord(t: Double(k) / 10,
                                                         flags: [.browserFront, .webValid],
                                                         window: window, web: web)))
        }
        let p = Self.plan(samples)
        var prev: PxRect?
        var maxJump = 0.0
        for k in 0...49 {
            let r = p.track.rect(at: Double(k) / 10 + 0.01)
            if let pv = prev {
                maxJump = max(maxJump, abs(r.x - pv.x), abs(r.y - pv.y),
                              abs(r.w - pv.w), abs(r.h - pv.h))
            }
            prev = r
        }
        let r = p.track.rect(at: 2.5)
        #expect(maxJump < 30, "max jump \(maxJump)")
        #expect(r.isValid, "\(r)")
        #expect(abs(r.aspect - 1920 / 1080) < 0.03, "\(r.aspect)")
    }

    /// Benchmark for the 480 Hz bake on a 30 s session. Signposts
    /// `crop.plan` (CropPlanner) and `chrome.detect.grid` (ChromeDetector) are
    /// emitted by production code; this pins the wall-clock envelope so a
    /// future change cannot quietly make the crop bake expensive.
    @Test func cropBakeStaysUnderBudget() {
        var samples: [ViewportSample] = []
        for k in 0..<300 {
            let jx = 2 * sin(Double(k) * 0.17)
            samples.append(ViewportSample(ViewportRecord(
                t: Double(k) / 10, flags: [.browserFront, .webValid],
                window: PxRect(x: 0, y: 0, w: 1920, h: 1080),
                web: PxRect(x: 120 + jx, y: 80, w: 1100, h: 700))))
        }
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<5 {
            _ = CropPlanner.plan(samples: samples,
                                 inputs: CropInputs(keys: [1, 1.2, 1.4, 5, 5.2, 5.4], uiClicks: [8]),
                                 duration: 30, source: Self.source, settings: CropSettings())
        }
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        print("A4 crop bake benchmark: 5 x (30 s @ 480 Hz) = \(String(format: "%.1f", ms)) ms")
        #expect(ms < 3000, "crop bake took \(ms) ms")
    }

    /// A4 follow-up: the vision fallback is selected ONLY when AX yields no
    /// content rect, and its result is a true source-pixel crop (aspect-fitted,
    /// inside the source) that the planner consumes as ordinary viewport
    /// evidence — never a camera zoom factor.
    @Test func visionFallbackIsTrueSourcePixelCropNotZoom() {
        // Selection gate.
        #expect(CaptureVisionFallback.shouldUseVision(axContent: nil))
        let ax = WindowContent.ResolvedContent(
            rect: CGRect(x: 0, y: 78, width: 1920, height: 1002), source: .axWebArea)
        #expect(!CaptureVisionFallback.shouldUseVision(axContent: ax))

        // Browser-like edge grid: chrome on the top two rows and the outer
        // two columns; the page body is the sparse centre band.
        let gridW = 12, gridH = 8
        var edges = [Float](repeating: 0.05, count: gridW * gridH)
        for r in 0..<gridH {
            for c in 0..<gridW {
                edges[r * gridW + c] = (r < 2 || c < 2 || c >= 10) ? 0.9 : 0.05
            }
        }
        let source = PxRect(x: 0, y: 0, w: 1920, h: 1080)
        guard let crop = CaptureVisionFallback.cropRect(edges: edges, gridW: gridW,
                                                        gridH: gridH, source: source) else {
            Issue.record("vision fallback produced no crop"); return
        }
        #expect(crop.isValid)
        #expect(crop.x >= 0 && crop.y >= 0 && crop.maxX <= 1920 && crop.maxY <= 1080)
        #expect(crop.h < source.h && crop.w < source.w, "fallback must crop: \(crop)")
        #expect(abs(crop.aspect - source.aspect) < 0.02, "\(crop.aspect)")

        // The detector's raw band is inset, aspect-fitted source geometry.
        let band = ChromeDetector.contentRect(edges: edges, gridW: gridW,
                                              gridH: gridH, window: source)
        #expect(band != nil)
        #expect(abs(crop.y - 270) < 1 && abs(crop.h - 810) < 1, "\(crop)")

        // Feed the SAME rect through the planner: the 480 Hz track stays in
        // source pixels and matches the detected crop.
        var settings = CropSettings(); settings.insetPx = 0
        let samples = Self.makeSamples(0, 8, web: crop, window: source)
        let plan = Self.plan(samples, settings)
        let tracked = plan.track.rect(at: 4)
        #expect(abs(tracked.x - crop.x) < 2 && abs(tracked.y - crop.y) < 2 &&
                abs(tracked.w - crop.w) < 2 && abs(tracked.h - crop.h) < 2, "\(tracked) != \(crop)")

        // No zoom intent → camera stays at 1x; the framing change is the crop.
        var tl = Timeline(duration: 8)
        tl.audio.speedRampsAuto = false
        let info = SourceInfo(width: 1920, height: 1080, fps: 60, duration: 8,
                              backingScale: 1, originX: 0, originY: 0)
        let derived = Director.derive(tl, input: DirectorInput(events: [], source: info, ax: []),
                                      revision: 1)
        #expect(abs(Double(derived.evaluate(at: 4).cameraScale) - 1.0) < 1e-6,
                "vision fallback must not induce a camera zoom")
    }
}
