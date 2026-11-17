import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
import LumenDirector

// MARK: - Core-feature validation: Smart Framing / reveal geometry
//
// Every assertion here is headless and drives the same planner + track the
// preview and export use. No window, no GPU, no interaction.

@Suite struct CoreZoomValidationSmartCropTests {
    private func source(_ w: Int, _ h: Int, _ dur: Double, scale: Double = 1) -> SourceInfo {
        SourceInfo(width: w, height: h, fps: 60, duration: dur, backingScale: scale,
                   originX: 0, originY: 0)
    }
    private func norm(_ r: CGRect, _ s: SourceInfo) -> CGRect {
        CGRect(x: r.minX / Double(s.width), y: r.minY / Double(s.height),
               width: r.width / Double(s.width), height: r.height / Double(s.height))
    }

    /// Two chrome reveals that merge into one window must still carry the
    /// source aspect ratio. A raw union of two same-aspect rects at different
    /// positions does NOT keep the aspect — it stretches the exported picture.
    /// This is the regression guard for that exact bug.
    @Test func mergedRevealsKeepSourceAspect() {
        let src = source(1920, 1080, 6)
        let roiPx = CGRect(x: 860, y: 490, width: 200, height: 112.5) // already 16:9
        let config = SmartCropConfig(enabled: true, roi: norm(roiPx, src),
                                     revealMarginPt: 0, returnSeconds: 0.45)
        let intents = [
            SmartCropIntent(t: 2.0, tEnd: 2.12, rect: CGRect(x: 100, y: 500, width: 50, height: 30)),
            SmartCropIntent(t: 2.1, tEnd: 2.22, rect: CGRect(x: 1700, y: 500, width: 50, height: 30)),
        ]
        let track = SmartCropPlanner.plan(config: config, source: src,
                                          tm: TimeMap(sourceDuration: 6), intents: intents)
        let merged = track.evaluate(at: 2.15)
        let want = Double(src.width) / Double(src.height)
        let got = merged.width / merged.height
        #expect(abs(got - want) < 0.01,
                Comment(rawValue: "merged reveal aspect \(got) != source \(want): \(merged)"))
        // The merged window must still actually reveal both chrome elements.
        #expect(merged.contains(CGRect(x: 100, y: 500, width: 50, height: 30)))
        #expect(merged.contains(CGRect(x: 1700, y: 500, width: 50, height: 30)))
    }

    /// Every generated keyframe rect — idle ROI, arrival, hold and restore —
    /// must carry the source aspect ratio, or the compositor stretches it.
    @Test func everyKeyframeCarriesSourceAspect() {
        let src = source(1920, 1080, 8, scale: 2)
        let content = CGRect(x: 200, y: 120, width: 1400, height: 850)
        let chrome1 = CGRect(x: 520, y: 24, width: 700, height: 34)
        let chrome2 = CGRect(x: 100, y: 300, width: 60, height: 400)
        let config = SmartCropConfig(enabled: true, roi: norm(content, src),
                                     revealMarginPt: 24, returnSeconds: 0.4)
        let intents = [
            SmartCropIntent(t: 2.0, tEnd: 2.12, rect: chrome1),
            SmartCropIntent(t: 2.15, tEnd: 2.27, rect: chrome2),
            SmartCropIntent(t: 5.0, tEnd: 5.12, rect: chrome1),
        ]
        let track = SmartCropPlanner.plan(config: config, source: src,
                                          tm: TimeMap(sourceDuration: 8), intents: intents)
        let want = Double(src.width) / Double(src.height)
        for k in track.keys {
            let got = k.rect.width / k.rect.height
            #expect(abs(got - want) < 0.01,
                    Comment(rawValue: "keyframe t=\(k.t) aspect \(got) != \(want): \(k.rect)"))
            #expect(k.rect.minX >= -0.5 && k.rect.minY >= -0.5 &&
                    k.rect.maxX <= Double(src.width) + 0.5 &&
                    k.rect.maxY <= Double(src.height) + 0.5,
                    Comment(rawValue: "keyframe outside source: \(k.rect)"))
        }
    }

    /// revealRect geometry is exact: union of the content ROI and the target,
    /// grown by margin converted from points with the backing scale.
    @Test func revealRectGeometryIsExact() {
        let roi = CGRect(x: 200, y: 120, width: 1400, height: 850)
        let target = CGRect(x: 520, y: 24, width: 700, height: 34)
        let config = SmartCropConfig(enabled: true, roi: .zero,
                                     revealMarginPt: 24, returnSeconds: 0.4)
        let got = SmartCropPlanner.revealRect(for: target, roi: roi, config: config, backingScale: 2)
        let expected = roi.union(target).insetBy(dx: -48, dy: -48)
        #expect(abs(got.minX - expected.minX) < 1e-6 &&
                abs(got.minY - expected.minY) < 1e-6 &&
                abs(got.width - expected.width) < 1e-6 &&
                abs(got.height - expected.height) < 1e-6,
                Comment(rawValue: "revealRect \(got) != \(expected)"))
    }

    /// aspectFit is idempotent and always lands inside the source. Feeding a
    /// rect that is already source-aspect back in must not change it.
    @Test func aspectFitIsIdempotentAndBounded() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let samples = [
            CGRect(x: 100, y: 50, width: 400, height: 900),   // too tall
            CGRect(x: 0, y: 0, width: 1700, height: 100),     // too wide
            CGRect(x: 300, y: 200, width: 800, height: 450),  // exact 16:9
            CGRect(x: -100, y: -50, width: 2400, height: 2000), // overflows source
        ]
        for r in samples {
            let once = SmartCropPlanner.aspectFit(r, source: bounds)
            let twice = SmartCropPlanner.aspectFit(once, source: bounds)
            #expect(abs(once.width / once.height - 1920.0 / 1080.0) < 1e-6, "aspect \(once)")
            #expect(once.minX >= -0.5 && once.minY >= -0.5 &&
                    once.maxX <= 1920.5 && once.maxY <= 1080.5, "bounds \(once)")
            #expect(abs(once.minX - twice.minX) < 1e-6 &&
                    abs(once.minY - twice.minY) < 1e-6 &&
                    abs(once.width - twice.width) < 1e-6 &&
                    abs(once.height - twice.height) < 1e-6, "not idempotent: \(once) vs \(twice)")
        }
    }

    /// Crop keyframes are in OUTPUT seconds. A trim plus a speed ramp must
    /// not shift the reveal off its source frame.
    @Test func outputTimeConversionSurvivesTrimAndRamp() {
        let src = source(1920, 1080, 10, scale: 2)
        let content = CGRect(x: 200, y: 120, width: 1400, height: 850)
        let chrome = CGRect(x: 520, y: 24, width: 700, height: 34)
        let tm = TimeMap(sourceDuration: 10, trimStart: 2, trimEnd: 10,
                         ramps: [SpeedRamp(start: 4, end: 6, speed: 2)])
        let config = SmartCropConfig(enabled: true, roi: norm(content, src),
                                     revealMarginPt: 24, returnSeconds: 0.4)
        let intents = [
            SmartCropIntent(t: 5.0, tEnd: 5.12, rect: chrome),
            SmartCropIntent(t: 9.0, tEnd: 9.12, rect: chrome),
        ]
        let track = SmartCropPlanner.plan(config: config, source: src, tm: tm, intents: intents)
        // At the output time of each source click, the reveal must contain chrome.
        for i in intents {
            let out = tm.output(atSource: i.t)
            let c = track.evaluate(at: out)
            #expect(c.contains(chrome), Comment(rawValue: "source \(i.t) -> output \(out): \(c)"))
        }
        // Well before the first reveal and well after the last, the crop is the ROI.
        let roi = SmartCropPlanner.aspectFit(content, source: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let early = track.evaluate(at: tm.output(atSource: 2.5))
        let late = track.evaluate(at: tm.output(atSource: 9.9))
        #expect(abs(early.minX - roi.minX) < 0.5 && abs(early.width - roi.width) < 0.5)
        #expect(abs(late.minX - roi.minX) < 0.5 && abs(late.width - roi.width) < 0.5)
    }
}
