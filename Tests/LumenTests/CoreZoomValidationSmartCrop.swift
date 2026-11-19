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
    /// Every generated keyframe rect — idle ROI, arrival, hold and restore —
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
}
