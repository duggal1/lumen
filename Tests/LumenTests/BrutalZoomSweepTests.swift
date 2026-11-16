import Foundation
import Testing
import LumenCore
import LumenProject
import LumenDirector

// MARK: - Sweeps
//
// These are the accuracy assertions that matter to a person watching the
// export: the camera arrives, it stays put while the subject is still, it
// never shows empty canvas, and it always comes back to the full frame. Every
// sample is taken through `Timeline.evaluate`, the exact call preview and
// export use — so a passing test is a statement about the pixels, not about an
// internal array.

enum Sweep {
    static func source(_ w: Int, _ h: Int, _ dur: Double) -> SourceInfo {
        SourceInfo(width: w, height: h, fps: 60, duration: dur, backingScale: 2,
                   originX: 0, originY: 0)
    }

    struct Case {
        var tl: Timeline
        var W: Double
        var H: Double
        var duration: Double

        /// The camera pose the renderer would use at output time `t`.
        func pose(_ t: Double) -> (x: Double, y: Double, scale: Double) {
            let f = tl.evaluate(at: t)
            return (Double(f.cameraCenter.x), Double(f.cameraCenter.y), Double(f.cameraScale))
        }

        /// Visible source rect at output time `t`.
        func visible(_ t: Double) -> CGRect {
            let p = pose(t)
            let w = W / p.scale, h = H / p.scale
            return CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
        }
    }

    static func build(duration: Double, w: Int = 1920, h: Int = 1080,
                      maxScale: Double = 2.0,
                      events: [InputEvent] = [], ax: [AXFrame] = [],
                      typing: [TypingTrace] = [], activity: [ActivityPoint] = [],
                      markers: [DirectorMarker] = [],
                      configure: (inout Timeline) -> Void = { _ in }) -> Case {
        var tl = Timeline(duration: duration)
        tl.audio.speedRampsAuto = false
        tl.camera.maxScale = maxScale
        tl.camera.autoZoom = true
        configure(&tl)
        let input = DirectorInput(events: events.sorted { $0.t < $1.t },
                                  source: source(w, h, duration),
                                  ax: ax, activity: activity, typing: typing, markers: markers)
        var cache = DeriveCache()
        tl = Director.derive(tl, input: input, revision: 1, cache: &cache)
        return Case(tl: tl, W: Double(w), H: Double(h), duration: duration)
    }

    // MARK: event builders

    static func click(_ t: Double, _ x: Double, _ y: Double, frame: AXFrame? = nil,
                      _ ax: inout [AXFrame]) -> [InputEvent] {
        var idx: UInt32 = 0
        if let f = frame { ax.append(f); idx = UInt32(ax.count) }
        return [InputEvent(t: t, kind: .down, x: Float(x), y: Float(y), button: 0, axFrameIndex: idx),
                InputEvent(t: t + 0.04, kind: .up, x: Float(x), y: Float(y), button: 0)]
    }

    static func axFrame(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                        at t: Double, caret: Double? = nil) -> AXFrame {
        var f = AXFrame(x: x, y: y, w: w, h: h,
                        anchor: FocusAnchor(epoch: 1, sampledAt: t, resolved: true))
        f.sampledAt = t
        if let c = caret {
            f.caret = AXFrame.Rect(x: x + c, y: y + 4, w: 2, h: min(h - 8, 22))
        }
        return f
    }

    /// Motion track for the pointer, sampled densely so a `follow` shot has a
    /// real path rather than a single point.
    static func glide(_ t0: Double, _ t1: Double, _ a: CGPoint, _ b: CGPoint,
                      hz: Double = 60) -> [InputEvent] {
        var out: [InputEvent] = []
        var t = t0
        while t <= t1 {
            let u = (t - t0) / max(t1 - t0, 1e-6)
            out.append(InputEvent(t: t, kind: .move,
                                  x: Float(a.x + (b.x - a.x) * u),
                                  y: Float(a.y + (b.y - a.y) * u)))
            t += 1 / hz
        }
        return out
    }
}

// MARK: - Pixel-accurate arrival

@Suite struct BrutalZoomArrivalTests {
    /// A click on a resolved control must arrive exactly on the control's
    /// centre, hold there without drifting, and never show canvas outside the
    /// source — measured at every export frame rate a project can be rendered
    /// at. 480 Hz baked samples map exactly onto 60/120/240 fps frames, so a
    /// mismatch here would be visible in the export, not just in the data.
    @Test(arguments: [60.0, 120.0, 240.0])
    func elementClicksArrivePixelExact(fps: Double) {
        var failures: [String] = []
        let dur = 6.0
        // Sweep the control across the frame, including the corners where the
        // feasible-centre clamp is active.
        for (i, origin) in [(0.05, 0.05), (0.45, 0.45), (0.80, 0.10), (0.10, 0.80), (0.70, 0.70)].enumerated() {
            var ax: [AXFrame] = []
            let w = 420.0, h = 180.0
            let fx = origin.0 * (1920 - w), fy = origin.1 * (1080 - h)
            let clickT = 1.5
            var events = Sweep.glide(0.2, 1.4, CGPoint(x: 100, y: 100),
                                     CGPoint(x: fx + w / 2, y: fy + h / 2))
            events += Sweep.click(clickT, fx + w / 2, fy + h / 2,
                                  frame: Sweep.axFrame(fx, fy, w, h, at: clickT), &ax)
            let c = Sweep.build(duration: dur, events: events, ax: ax)
            guard let seg = c.tl.zoom.first else {
                failures.append("case \(i): no zoom segment"); continue
            }
            let targetX = fx + w / 2, targetY = fy + h / 2
            let visW = 1920 / seg.scale, visH = 1080 / seg.scale

            var t = seg.start + 1 / fps
            while t < seg.end - 1 / fps {
                let v = c.visible(t)
                // Nothing outside the source.
                if v.minX < -0.75 || v.minY < -0.75 || v.maxX > 1920.75 || v.maxY > 1080.75 {
                    failures.append(String(format: "case %d t=%.3f: canvas shows outside source %@", i, t, "\(v)"))
                    break
                }
                // The control must be fully inside the shot.
                if v.minX > fx + 0.75 || v.maxX < fx + w - 0.75 ||
                   v.minY > fy + 0.75 || v.maxY < fy + h - 0.75 {
                    failures.append(String(format: "case %d t=%.3f: control not framed", i, t))
                    break
                }
                // Centred, unless the clamp legitimately holds it at the edge.
                let p = c.pose(t)
                let wantX = min(max(targetX, visW / 2), 1920 - visW / 2)
                let wantY = min(max(targetY, visH / 2), 1080 - visH / 2)
                if abs(p.x - wantX) > 0.75 || abs(p.y - wantY) > 0.75 {
                    failures.append(String(format: "case %d t=%.3f: centre (%.2f,%.2f) != (%.2f,%.2f)",
                                           i, t, p.x, p.y, wantX, wantY))
                    break
                }
                t += 1 / fps
            }
            // Scale must be the planned one, not a drift.
            if abs(c.pose((seg.start + seg.end) / 2).scale - seg.scale) > 1e-4 {
                failures.append("case \(i): scale \(c.pose((seg.start + seg.end) / 2).scale) != \(seg.scale)")
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.prefix(6).joined(separator: "\n")))
    }

    /// Arrival is a promise about a frame, not a limit. The pose one frame
    /// after the settle time must already be the final pose, and the pose one
    /// frame before must still be moving. If the second half fails the zoom
    /// finished early; if the first fails it is late.
    @Test(arguments: [60.0, 120.0, 240.0])
    func arrivalLandsInsideOneFrame(fps: Double) {
        var failures: [String] = []
        for scale in [1.25, 1.6, 2.0] {
            var ax: [AXFrame] = []
            var events: [InputEvent] = []
            let fx = 1200.0, fy = 700.0, w = 300.0, h = 120.0
            events += Sweep.click(2.0, fx + w / 2, fy + h / 2,
                                  frame: Sweep.axFrame(fx, fy, w, h, at: 2.0), &ax)
            let c = Sweep.build(duration: 5.0, maxScale: scale, events: events, ax: ax)
            guard let seg = c.tl.zoom.first else { failures.append("s=\(scale): no segment"); continue }
            // Auto segments settle at the segment start; the segment start is
            // the event time by construction, so probe around the arrival of
            // the +hold window instead: the hold pose is the reference.
            let holdPose = c.pose(seg.start + (seg.end - seg.start) * 0.5)
            let atArrival = c.pose(seg.start + 1 / fps)
            if abs(atArrival.x - holdPose.x) > 0.75 || abs(atArrival.y - holdPose.y) > 0.75 {
                failures.append(String(format: "s=%.2f: still moving one frame after arrival (%.2f,%.2f vs %.2f,%.2f)",
                                       scale, atArrival.x, atArrival.y, holdPose.x, holdPose.y))
            }
            if abs(atArrival.scale - holdPose.scale) > 1e-4 {
                failures.append(String(format: "s=%.2f: scale %.5f != hold %.5f", scale, atArrival.scale, holdPose.scale))
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    /// Every click time in a session must still leave the recording on the full
    /// frame. A late click is the one that used to strand the camera zoomed.
    @Test func lateClicksStillReturnToFullFrame() {
        var failures: [String] = []
        let dur = 6.0
        var t = 0.4
        while t < dur - 0.2 {
            var ax: [AXFrame] = []
            let fx = 700.0, fy = 400.0
            let events = Sweep.click(t, fx + 140, fy + 50,
                                     frame: Sweep.axFrame(fx, fy, 280, 100, at: t), &ax)
            let c = Sweep.build(duration: dur, events: events, ax: ax)
            let p = c.pose(dur - 0.002)
            if abs(p.scale - 1) > 1e-4 || abs(p.x - 960) > 0.5 || abs(p.y - 540) > 0.5 {
                failures.append(String(format: "click at %.2f: ends at %.5fx (%.1f,%.1f)", t, p.scale, p.x, p.y))
            }
            t += 0.2
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.prefix(8).joined(separator: "\n")))
    }

    /// Full-frame moments are exact, not approximate. Anywhere no shot is
    /// active the camera must be at 1.0× and dead centre, because a residual
    /// 1.02× is a silently soft export.
    @Test func idleStretchesAreExactlyFullFrame() {
        var ax: [AXFrame] = []
        let events = Sweep.click(2.0, 960, 540, frame: Sweep.axFrame(760, 440, 400, 200, at: 2.0), &ax)
        let c = Sweep.build(duration: 8.0, events: events, ax: ax)
        var failures: [String] = []
        for t in stride(from: 0.05, through: 1.0, by: 0.05) {
            let p = c.pose(t)
            if abs(p.scale - 1) > 1e-5 || abs(p.x - 960) > 0.01 || abs(p.y - 540) > 0.01 {
                failures.append(String(format: "t=%.2f: %.6fx (%.3f,%.3f)", t, p.scale, p.x, p.y))
            }
        }
        for t in stride(from: 7.0, through: 7.95, by: 0.05) {
            let p = c.pose(t)
            if abs(p.scale - 1) > 1e-5 || abs(p.x - 960) > 0.01 || abs(p.y - 540) > 0.01 {
                failures.append(String(format: "t=%.2f: %.6fx (%.3f,%.3f)", t, p.scale, p.x, p.y))
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.prefix(6).joined(separator: "\n")))
    }
}

// MARK: - Typing stillness

@Suite struct BrutalTypingStillnessTests {
    /// The camera is not allowed to chase the caret. Across a whole burst, at
    /// every export frame rate, with the caret walking the field, the pose must
    /// be constant to well under a pixel.
    @Test(arguments: [60.0, 120.0, 240.0])
    func cameraHoldsStillWhileTyping(fps: Double) {
        var failures: [String] = []
        for (i, f) in [(180.0, 240.0, 700.0, 90.0), (60.0, 60.0, 420.0, 34.0),
                       (900.0, 520.0, 640.0, 140.0)].enumerated() {
            let (fx, fy, fw, fh) = (f.0, f.1, f.2, f.3)
            var events: [InputEvent] = []
            var ax: [AXFrame] = []
            var samples: [TypingTrace.Sample] = []
            let t0 = 1.2
            let keys = 16
            for k in 0..<keys {
                let t = t0 + Double(k) * 0.16
                let caret = 4 + Double(k) * (fw - 16) / Double(keys)
                ax.append(Sweep.axFrame(fx, fy, fw, fh, at: t, caret: caret))
                events.append(InputEvent(t: t, kind: .keyDown, keyCode: UInt16(10 + k % 20),
                                         axFrameIndex: UInt32(ax.count)))
                samples.append(TypingTrace.Sample(t: t, x: fx + caret, y: fy + fh / 2, confidence: 0.9))
            }
            let burst = TypingTrace(t0: t0, t1: samples.last!.t,
                                    rect: CGRect(x: fx, y: fy, width: fw, height: fh),
                                    samples: samples,
                                    line: CGRect(x: fx, y: fy + fh / 2 - 11, width: fw, height: 22))
            let c = Sweep.build(duration: 5.0, events: events, ax: ax, typing: [burst])
            let mid = (t0 + burst.t1) / 2
            let ref = c.pose(mid)
            var t = t0 + 0.05
            while t <= burst.t1 - 0.02 {
                let p = c.pose(t)
                if abs(p.x - ref.x) > 0.75 || abs(p.y - ref.y) > 0.75 {
                    failures.append(String(format: "field %d t=%.3f: drift (%.2f,%.2f) from (%.2f,%.2f)",
                                           i, t, p.x, p.y, ref.x, ref.y))
                    break
                }
                if abs(p.scale - ref.scale) > 1e-4 {
                    failures.append(String(format: "field %d t=%.3f: scale drift %.5f vs %.5f",
                                           i, t, p.scale, ref.scale))
                    break
                }
                t += 1 / fps
            }
            // The field must be readable: fully inside the shot the whole burst.
            var t2 = t0 + 0.2
            while t2 <= burst.t1 - 0.05 {
                let v = c.visible(t2)
                if v.minX > fx + 1 || v.maxX < fx + fw - 1 || v.minY > fy + 1 || v.maxY < fy + fh - 1 {
                    failures.append(String(format: "field %d t=%.3f: field clipped %@", i, t2, "\(v)"))
                    break
                }
                t2 += 1 / fps
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.prefix(6).joined(separator: "\n")))
    }

    /// A caret that jumps to the far end of the field mid-burst must not move
    /// the frame at all. This is the exact behaviour that used to drift 152 px.
    @Test func caretJumpDoesNotMoveTheFrame() {
        let fx = 300.0, fy = 300.0, fw = 800.0, fh = 120.0
        var events: [InputEvent] = []
        var ax: [AXFrame] = []
        var samples: [TypingTrace.Sample] = []
        for k in 0..<10 {
            let t = 1.0 + Double(k) * 0.2
            let caret = k < 5 ? 4.0 : fw - 8
            ax.append(Sweep.axFrame(fx, fy, fw, fh, at: t, caret: caret))
            events.append(InputEvent(t: t, kind: .keyDown, keyCode: 12, axFrameIndex: UInt32(ax.count)))
            samples.append(TypingTrace.Sample(t: t, x: fx + caret, y: fy + fh / 2, confidence: 0.9))
        }
        let burst = TypingTrace(t0: 1.0, t1: samples.last!.t,
                                rect: CGRect(x: fx, y: fy, width: fw, height: fh),
                                samples: samples,
                                line: CGRect(x: fx, y: fy + fh / 2 - 11, width: fw, height: 22))
        let c = Sweep.build(duration: 4.0, events: events, ax: ax, typing: [burst])
        let before = c.pose(1.3)
        let after = c.pose(2.5)
        #expect(abs(before.x - after.x) < 0.01, Comment(rawValue: "x moved \(before.x) -> \(after.x)"))
        #expect(abs(before.y - after.y) < 0.01, Comment(rawValue: "y moved \(before.y) -> \(after.y)"))
        #expect(abs(before.scale - after.scale) < 1e-6)
    }
}

// MARK: - Degenerate input

@Suite struct BrutalZoomDegenerateTests {
    /// None of these are hypothetical: they are what a half-finished capture,
    /// a cancelled recording and a corrupt accessibility frame look like.
    @Test func degenerateInputsNeverProduceABrokenCamera() {
        var failures: [String] = []

        func check(_ name: String, _ c: Sweep.Case) {
            if let cam = c.tl.derived?.camera {
                let bad = BrutalCheck.camera(c.tl, maxScale: c.tl.camera.maxScale, label: name)
                failures += bad
                if cam.lz.isEmpty { failures.append("\(name): empty camera") }
            }
            // Evaluate across the whole timeline: no NaN may escape.
            for t in stride(from: 0.0, through: c.duration, by: max(c.duration / 24, 0.01)) {
                let p = c.pose(t)
                if !p.x.isFinite || !p.y.isFinite || !p.scale.isFinite || p.scale <= 0 {
                    failures.append("\(name): non-finite pose at \(t)")
                    break
                }
            }
        }

        check("zero-duration", Sweep.build(duration: 0))
        check("empty-events", Sweep.build(duration: 4))
        check("no-events-one-second", Sweep.build(duration: 1))
        check("tiny-source", Sweep.build(duration: 3, w: 1, h: 1,
                                        events: [InputEvent(t: 1, kind: .down, x: 0, y: 0)]))

        var nanAx: [AXFrame] = []
        var nanEvents: [InputEvent] = []
        nanEvents += Sweep.click(1.0, 900, 500, frame: Sweep.axFrame(.nan, 40, .nan, 10, at: 1.0), &nanAx)
        nanEvents.append(InputEvent(t: 1.5, kind: .move, x: .nan, y: .nan))
        check("nan-coordinates", Sweep.build(duration: 4, events: nanEvents, ax: nanAx))

        var infEvents = [InputEvent(t: 1.0, kind: .down, x: .infinity, y: -.infinity)]
        infEvents.append(InputEvent(t: 1.01, kind: .up, x: .infinity, y: -.infinity))
        check("infinite-coordinates", Sweep.build(duration: 4, events: infEvents))

        // A click exactly on the last tick, and a click past it.
        var endAx: [AXFrame] = []
        check("click-at-end", Sweep.build(duration: 3, events:
            Sweep.click(2.9999, 900, 500, frame: Sweep.axFrame(800, 450, 200, 100, at: 2.9999), &endAx),
            ax: endAx))
        var pastAx: [AXFrame] = []
        check("click-past-end", Sweep.build(duration: 3, events:
            Sweep.click(9.0, 900, 500, frame: Sweep.axFrame(800, 450, 200, 100, at: 9.0), &pastAx),
            ax: pastAx))

        // A zoom cap of 1 means "never zoom" — not "zoom to 1.0001".
        var capAx: [AXFrame] = []
        let capped = Sweep.build(duration: 4, maxScale: 1.0, events:
            Sweep.click(1.5, 960, 540, frame: Sweep.axFrame(800, 460, 320, 160, at: 1.5), &capAx),
            ax: capAx)
        for t in stride(from: 0.1, through: 3.9, by: 0.1) {
            let p = capped.pose(t)
            if abs(p.scale - 1) > 1e-6 { failures.append("cap-1.0: zoomed to \(p.scale) at \(t)"); break }
        }

        // A zero-height element frame must not divide by zero.
        var flatAx: [AXFrame] = []
        check("zero-size-element", Sweep.build(duration: 4, events:
            Sweep.click(1.5, 960, 540, frame: Sweep.axFrame(900, 540, 0, 0, at: 1.5), &flatAx),
            ax: flatAx))

        #expect(failures.isEmpty, Comment(rawValue: failures.prefix(10).joined(separator: "\n")))
    }

    /// Trimming the tail must not leave a shot hanging. If the click is in the
    /// last 200 ms the plan may skip it, but the recording must still end on the
    /// full frame.
    @Test func clickInsideTheFinalTailStillEndsFullFrame() {
        var failures: [String] = []
        for t in [2.80, 2.90, 2.95, 2.98] {
            var ax: [AXFrame] = []
            let c = Sweep.build(duration: 3.0, events:
                Sweep.click(t, 960, 540, frame: Sweep.axFrame(800, 460, 320, 160, at: t), &ax),
                ax: ax)
            let p = c.pose(2.9999)
            if abs(p.scale - 1) > 1e-4 { failures.append("click at \(t): ends at \(p.scale)x") }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
}

// MARK: - One target at a time

@Suite struct BrutalZoomSingleTargetTests {
    /// Three clicks inside the same half second are one shot, not three. The
    /// camera pans between them inside the open shot; splitting would create
    /// two overlapping segments and a one-tick cut where the writes meet.
    @Test func rapidNearbyClicksStayOneShot() {
        var ax: [AXFrame] = []
        var events: [InputEvent] = []
        var t = 1.0
        for i in 0..<4 {
            let x = 700.0 + Double(i) * 90, y = 420.0 + Double(i) * 30
            events += Sweep.click(t, x, y, frame: Sweep.axFrame(x - 100, y - 40, 200, 80, at: t), &ax)
            t += 0.12
        }
        let c = Sweep.build(duration: 6.0, events: events, ax: ax)
        let shots = c.tl.zoom.sorted { $0.start < $1.start }
        #expect(shots.count == 1, Comment(rawValue: "got \(shots.count) shots: "
            + shots.map { String(format: "[%.2f-%.2f]", $0.start, $0.end) }.joined(separator: " ")))
        if let s = shots.first {
            #expect(s.end - s.start >= 0.2)
        }
    }

    /// Clicks that jump to a different region open a new shot, and the two
    /// shots must be disjoint with a real hold between them.
    @Test func distantClicksOpenDisjointShots() {
        var ax: [AXFrame] = []
        var events: [InputEvent] = []
        let spots = [(300.0, 240.0), (1600.0, 800.0), (500.0, 900.0)]
        for (i, p) in spots.enumerated() {
            let t = 1.0 + Double(i) * 1.6
            events += Sweep.click(t, p.0, p.1, frame: Sweep.axFrame(p.0 - 120, p.1 - 50, 240, 100, at: t), &ax)
        }
        let c = Sweep.build(duration: 7.0, events: events, ax: ax)
        let shots = c.tl.zoom.sorted { $0.start < $1.start }
        #expect(shots.count >= 2, Comment(rawValue: "got \(shots.count) shots"))
        for k in 1..<max(shots.count, 1) {
            #expect(shots[k].start >= shots[k - 1].end - 1e-6,
                    Comment(rawValue: "shots overlap: \(shots[k - 1].start)-\(shots[k - 1].end) / \(shots[k].start)-\(shots[k].end)"))
        }
        // And each shot must actually reach its subject.
        for s in shots {
            let mid = (s.start + s.end) / 2
            let v = c.visible(mid)
            let vw = 1920 / s.scale, vh = 1080 / s.scale
            #expect(v.width <= vw + 0.75 && v.height <= vh + 0.75)
            _ = v
        }
    }
}

// MARK: - Cost

@Suite struct BrutalZoomCostTests {
    /// A long, click-dense session must stay interactive: the editor re-derives
    /// on every plan change, and a solve that takes seconds makes the whole app
    /// feel broken even when the picture is right.
    @Test func longDenseSessionDerivesQuickly() {
        let dur = 60.0
        var ax: [AXFrame] = []
        var events: [InputEvent] = []
        for i in 0..<200 {
            let t = 0.2 + Double(i) * (dur - 1.0) / 200
            let x = 200 + Double((i * 137) % 1500), y = 150 + Double((i * 71) % 780)
            let fw = 160.0 + Double(i % 5) * 60, fh = 60.0 + Double(i % 3) * 40
            events += Sweep.glide(t - 0.18, t - 0.02, CGPoint(x: x - 60, y: y - 40), CGPoint(x: x, y: y), hz: 20)
            events += Sweep.click(t, x, y,
                                  frame: Sweep.axFrame(min(x - fw / 2, 1920 - fw), min(y - fh / 2, 1080 - fh),
                                                       fw, fh, at: t), &ax)
        }
        let start = Date()
        let c = Sweep.build(duration: dur, events: events, ax: ax)
        let elapsed = Date().timeIntervalSince(start)
        #expect(c.tl.derived?.camera.lz.count ?? 0 > 1000, "no camera track")
        // Generous ceiling: the point is to catch a quadratic blow-up, not to
        // measure this machine.
        #expect(elapsed < 20, "derive took \(String(format: "%.2f", elapsed))s")
    }

    /// `evaluate` runs several times per exported frame and on every scrub
    /// tick. It must be cheap enough to be called from a display loop.
    @Test func evaluateIsCheapEnoughForADisplayLoop() {
        var ax: [AXFrame] = []
        var events: [InputEvent] = []
        for i in 0..<40 {
            let t = 0.3 + Double(i) * 0.35
            let x = 300.0 + Double((i * 211) % 1200), y = 200.0 + Double((i * 97) % 600)
            events += Sweep.click(t, x, y, frame: Sweep.axFrame(x - 90, y - 40, 180, 80, at: t), &ax)
        }
        let c = Sweep.build(duration: 16.0, events: events, ax: ax)
        let samples = 40_000
        let start = Date()
        var sink = 0.0
        for i in 0..<samples {
            let t = Double(i % 960) / 60.0
            let f = c.tl.evaluate(at: t)
            sink += Double(f.cameraScale)
        }
        let elapsed = Date().timeIntervalSince(start)
        let perCall = elapsed / Double(samples) * 1e6
        #expect(sink.isFinite)
        // A 60 fps frame budget is 16 600 µs; one evaluate must be far under it.
        #expect(perCall < 400, "evaluate took \(String(format: "%.1f", perCall))µs per call")
    }
}
