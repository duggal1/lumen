import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - Core-feature validation: Focus & Zoom planner
//
// Headless assertions on the exact planner the editor and export use. The
// brutal fuzz suites cover general invariants; these pin the specific promises
// made in CORE-FEATURES.MD §1.

@Suite struct CoreZoomValidationPlannerTests {
    private func source(_ w: Int = 1920, _ h: Int = 1080, _ dur: Double = 8, scale: Double = 2) -> SourceInfo {
        SourceInfo(width: w, height: h, fps: 60, duration: dur, backingScale: scale,
                   originX: 0, originY: 0)
    }

    private func click(_ t: Double, _ x: Double, _ y: Double, fw: Double = 260, fh: Double = 110,
                       _ ax: inout [AXFrame]) -> [InputEvent] {
        ax.append(AXFrame(x: x - fw / 2, y: y - fh / 2, w: fw, h: fh,
                          anchor: FocusAnchor(epoch: 1, sampledAt: t, resolved: true)))
        let idx = UInt32(ax.count)
        return [InputEvent(t: t, kind: .down, x: Float(x), y: Float(y), button: 0, axFrameIndex: idx),
                InputEvent(t: t + 0.04, kind: .up, x: Float(x), y: Float(y), button: 0)]
    }

    private func params(cap: Double) -> CameraParams {
        var p = CameraParams()
        p.maxScale = cap
        p.minScale = min(1.25, cap)
        p.baseScale = 3.0            // deliberately above every cap
        p.sensitivity = 1.0
        p.zoomOutGap = 1.2
        p.hold = 0.6
        return p
    }

    /// maxScale is a HARD cap: no auto segment may exceed it, for any cap the
    /// Inspector exposes, even when baseScale / element fitting would ask for
    /// more. Deterministic input, no randomness.
    @Test func autoSegmentsRespectHardMaxScale() {
        for cap in [1.2, 1.3, 1.5, 1.75, 2.0, 2.4] {
            var ax: [AXFrame] = []
            var events: [InputEvent] = []
            for (i, p) in [(400.0, 300.0), (1500.0, 800.0), (900.0, 500.0)].enumerated() {
                // Vary element size from tiny to large; huge elements should
                // earn a gentle zoom, tiny ones a close look — but never past cap.
                let f = 60.0 + Double(i) * 320.0
                events += click(1.0 + Double(i) * 1.6, p.0, p.1, fw: f, fh: f / 2, &ax)
            }
            let plan = ZoomPlanner.plan(events: events, ax: ax, typing: [], activity: [],
                                        src: source(), p: params(cap: cap),
                                        tm: TimeMap(sourceDuration: 8), avoid: [], markers: [])
            #expect(!plan.segments.isEmpty, "cap \(cap): no auto segments to check")
            for s in plan.segments {
                #expect(s.scale <= cap + 1e-9,
                        Comment(rawValue: "cap \(cap): segment scale \(s.scale) exceeds cap"))
                #expect(s.scale >= 1 - 1e-9, "cap \(cap): segment scale \(s.scale) below 1x")
            }
        }
    }

    /// The fixed-camera preset is still a zoom: its magnification must also
    /// respect the hard cap (the Zoom-amount slider can exceed Max-zoom).
    @Test func fixedPresetRespectsHardMaxScale() {
        for cap in [1.2, 1.5, 2.0] {
            var p = params(cap: cap)
            p.preset = .fixed
            p.baseScale = 3.0
            let plan = ZoomPlanner.plan(events: [], ax: [], typing: [], activity: [],
                                        src: source(), p: p,
                                        tm: TimeMap(sourceDuration: 8), avoid: [], markers: [])
            #expect(plan.segments.count == 1, "cap \(cap): expected one fixed segment")
            if let s = plan.segments.first {
                #expect(s.scale <= cap + 1e-9,
                        Comment(rawValue: "cap \(cap): fixed scale \(s.scale) exceeds cap"))
                #expect(s.scale >= 1 - 1e-9, "fixed scale \(s.scale) below 1x")
            }
        }
    }

    /// The cap also holds on the baked camera track, not just on the plan.
    @Test func bakedCameraNeverExceedsMaxScale() {
        for cap in [1.2, 1.5, 2.0] {
            var ax: [AXFrame] = []
            var events: [InputEvent] = []
            events += click(1.5, 500, 400, fw: 80, fh: 40, &ax)
            events += click(3.5, 1400, 700, fw: 120, fh: 60, &ax)
            var tl = Timeline(duration: 6)
            tl.audio.speedRampsAuto = false
            tl.camera.autoZoom = true
            tl.camera.maxScale = cap
            tl.camera.minScale = min(1.25, cap)
            tl.camera.baseScale = 4.0
            let out = Director.derive(tl, input: DirectorInput(events: events, source: source(1920, 1080, 6),
                                                               ax: ax), revision: 1)
            guard let cam = out.derived?.camera else { Issue.record("no camera"); continue }
            let peak = cam.lz.map { Foundation.exp(Double($0)) }.max() ?? 1
            #expect(peak <= cap + 1e-6, Comment(rawValue: "cap \(cap): baked camera peaked at \(peak)x"))
        }
    }

    /// Same input -> byte-identical plan, including stable IDs (which are the
    /// keys suppression relies on) and follow paths.
    @Test func autoPlanIsDeterministic() {
        func make() -> ZoomPlanner.ZoomPlan {
            var ax: [AXFrame] = []
            var events: [InputEvent] = []
            events += click(1.0, 400, 300, &ax)
            events += click(2.2, 1500, 800, &ax)
            events += click(4.0, 900, 500, &ax)
            return ZoomPlanner.plan(events: events, ax: ax, typing: [], activity: [],
                                    src: source(), p: params(cap: 2.0),
                                    tm: TimeMap(sourceDuration: 8), avoid: [], markers: [])
        }
        let a = make(), b = make()
        #expect(a.segments == b.segments)
        #expect(Set(a.follow.keys) == Set(b.follow.keys))
        for (k, va) in a.follow {
            guard let vb = b.follow[k] else { Issue.record("missing path \(k)"); continue }
            let pa = va.map { ($0.t, $0.p.x, $0.p.y) }
            let pb = vb.map { ($0.t, $0.p.x, $0.p.y) }
            #expect(pa.count == pb.count && zip(pa, pb).allSatisfy { x, y in
                x.0 == y.0 && x.1 == y.1 && x.2 == y.2
            }, "follow path differs for \(k)")
        }
    }

    /// One camera, one target: auto segments are pairwise disjoint.
    @Test func autoSegmentsNeverOverlap() {
        var ax: [AXFrame] = []
        var events: [InputEvent] = []
        for i in 0..<6 {
            let x = 200.0 + Double((i * 307) % 1500)
            let y = 150.0 + Double((i * 173) % 750)
            events += click(0.8 + Double(i) * 0.9, x, y, &ax)
        }
        let plan = ZoomPlanner.plan(events: events, ax: ax, typing: [], activity: [],
                                    src: source(), p: params(cap: 2.0),
                                    tm: TimeMap(sourceDuration: 8), avoid: [], markers: [])
        let segs = plan.segments.sorted { $0.start < $1.start }
        for i in 1..<max(segs.count, 1) {
            #expect(segs[i].start >= segs[i - 1].end - 1e-6,
                    Comment(rawValue: "overlap: [\(segs[i - 1].start),\(segs[i - 1].end)] vs [\(segs[i].start),\(segs[i].end)]"))
        }
    }

    /// A zoom always resolves back to the full, centred frame — before the
    /// first shot and after the last one.
    @Test func recordingStartsAndEndsOnTheFullFrame() {
        var ax: [AXFrame] = []
        var events: [InputEvent] = []
        for i in 0..<3 { events += click(1.0 + Double(i) * 1.5, 500 + Double(i) * 400, 400, &ax) }
        var tl = Timeline(duration: 8)
        tl.audio.speedRampsAuto = false
        tl.camera.autoZoom = true
        let out = Director.derive(tl, input: DirectorInput(events: events, source: source(1920, 1080, 8),
                                                           ax: ax), revision: 1)
        // cameraCenter is in source pixels (Director.FrameState contract).
        for (name, t) in [("start", 0.1), ("end", 7.99)] {
            let f = out.evaluate(at: t)
            #expect(abs(Double(f.cameraScale) - 1) < 1e-5, "\(name): scale \(f.cameraScale)")
            #expect(abs(Double(f.cameraCenter.x) - 960) < 0.01, "\(name): x \(f.cameraCenter.x)")
            #expect(abs(Double(f.cameraCenter.y) - 540) < 0.01, "\(name): y \(f.cameraCenter.y)")
        }
    }

    /// Typing frames the FIELD, never the caret: the shot carries a fixed
    /// element rect and no follow path at all.
    @Test func typingFramesTheFieldAndNeverFollowsTheCaret() {
        let W = 1920.0, H = 1080.0
        var ax: [AXFrame] = []
        var frame = AXFrame(x: 300, y: 300, w: 800, h: 120,
                            anchor: FocusAnchor(epoch: 1, sampledAt: 1.0, resolved: true))
        frame.caret = AXFrame.Rect(x: 304, y: 304, w: 2, h: 22)
        ax.append(frame)
        var keys: [InputEvent] = []
        for k in 0..<12 { keys.append(InputEvent(t: 1.0 + Double(k) * 0.12, kind: .keyDown,
                                                keyCode: UInt16(k), axFrameIndex: 1)) }
        let plan = ZoomPlanner.plan(events: keys, ax: ax, typing: [], activity: [],
                                    src: source(), p: params(cap: 2.0),
                                    tm: TimeMap(sourceDuration: 8), avoid: [], markers: [])
        guard let seg = plan.segments.first else { Issue.record("no typing segment"); return }
        guard case .element(let x, let y, let w, let h) = seg.focus else {
            Issue.record("typing focus is \(seg.focus), expected the field element rect"); return
        }
        #expect(abs(x - 300 / W) < 1e-6 && abs(y - 300 / H) < 1e-6 &&
                abs(w - 800 / W) < 1e-6 && abs(h - 120 / H) < 1e-6,
                Comment(rawValue: "field rect wrong: (\(x),\(y),\(w),\(h))"))
        #expect(plan.follow[seg.id] == nil, "typing must not carry a caret follow path")
    }

    /// Manual segments survive every replan; auto planning avoids them; and
    /// an explicitly suppressed auto segment stays suppressed across derives.
    @Test func manualSegmentsSurviveReplanAndSuppression() {
        let src = source(1920, 1080, 8)
        var ax: [AXFrame] = []
        var events: [InputEvent] = []
        events += click(2.5, 400, 300, &ax)
        events += click(4.5, 1400, 700, &ax)

        var tl = Timeline(duration: 8)
        tl.audio.speedRampsAuto = false
        tl.camera.autoZoom = true
        let manual = ZoomSegment(start: 0.5, end: 1.5, scale: 1.7,
                                 focus: .fixed(x: 0.5, y: 0.5), origin: .manual)
        tl.zoom = [manual]
        let input = DirectorInput(events: events, source: src, ax: ax)

        let first = Director.derive(tl, input: input, revision: 1)
        #expect(first.zoom.contains { $0.id == manual.id && $0.scale == manual.scale },
                "manual segment was dropped on first derive")
        let autos = first.zoom.filter { $0.origin == .auto }
        #expect(!autos.isEmpty, "expected auto segments to plan")
        for a in autos {
            #expect(a.start >= manual.end - 1e-6 || a.end <= manual.start + 1e-6,
                    Comment(rawValue: "auto [\(a.start),\(a.end)] overlaps manual [\(manual.start),\(manual.end)]"))
        }

        let victim = autos[0]
        var suppressed = tl
        suppressed.suppressedAuto = [victim.id.uuidString]
        let second = Director.derive(suppressed, input: input, revision: 1)
        #expect(!second.zoom.contains { $0.id == victim.id }, "suppressed auto segment came back")
        #expect(second.zoom.contains { $0.id == manual.id }, "manual segment lost after suppression")
        #expect(second.zoom.filter { $0.origin == .auto }.count == autos.count - 1,
                "wrong auto count after suppression")
    }
}
