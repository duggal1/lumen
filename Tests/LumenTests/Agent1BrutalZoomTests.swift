import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - HEADLESS BRUTAL TEST AGENT 1/3 — ZOOM / CROP ACCURACY
//
// Every assertion here drives the real derive + Timeline.evaluate path (the
// exact call preview and export use). No windows, no screenshots, no mocks.
// Browser evidence is now supplied as synthetic viewport observations rather
// than AX chrome labels; the geometric expectations are unchanged.

enum A1 {
    static let W = 1920.0, H = 1080.0
    static let bounds = CGRect(x: 0, y: 0, width: W, height: H)
    static let tab = CGRect(x: 0, y: 0, width: W, height: 36)
    static let address = CGRect(x: 300, y: 44, width: 800, height: 34)
    static let dropdown = CGRect(x: 300, y: 78, width: 800, height: 380)
    static let page = SmartCropPlanner.fitInside(
        CGRect(x: 0, y: 78, width: W, height: H - 78), source: bounds)

    static func source(_ dur: Double = 10, scale: Double = 2) -> SourceInfo {
        SourceInfo(width: Int(W), height: Int(H), fps: 60, duration: dur,
                   backingScale: scale, originX: 0, originY: 0)
    }

    /// A 10 Hz browser observation stream. `ui` intervals mark chrome focus;
    /// a UI click is derived from a pointer-down inside `window` but outside
    /// `web`, exactly as `CropInputs.make` does in production.
    static func samples(_ dur: Double = 10, ui: [(Double, Double)] = [],
                        web: CGRect? = nil, webValid: Bool = true,
                        front: Bool = true) -> [ViewportSample] {
        let page = web ?? Self.page
        let count = Int((dur * 10).rounded(.down))
        return (0...count).map { i in
            let t = Double(i) / 10
            let chromeFocus = ui.contains { t >= $0.0 - 1e-9 && t <= $0.1 + 1e-9 }
            var flags: ViewportRecord.Flags = []
            if front { flags.insert(.browserFront) }
            if chromeFocus { flags.insert(.uiFocus) }
            if webValid { flags.insert(.webValid) }
            return ViewportSample(ViewportRecord(
                t: t, flags: flags,
                window: PxRect(x: 0, y: 0, w: W, h: H),
                web: PxRect(x: page.minX, y: page.minY, w: page.width, h: page.height)))
        }
    }

    /// AX frames are still the evidence for typing and dialog subjects.
    static func browserAX(_ app: String, addressAt: Double = 2) -> [AXFrame] {
        let win = AXFrame(x: 0, y: 0, w: W, h: H,
                          label: "window|AXWindow|AXStandardWindow|\(app)",
                          anchor: FocusAnchor(epoch: 1, sampledAt: 0, appName: app, resolved: true))
        let tabFrame = AXFrame(x: tab.minX, y: tab.minY, w: tab.width, h: tab.height,
                               label: "New Tab",
                               anchor: FocusAnchor(epoch: 1, sampledAt: 0, appName: app, resolved: true))
        let addressLabel = app.lowercased().contains("safari")
            ? "Search or enter website name" : "Address and search bar"
        var addr = AXFrame(x: address.minX, y: address.minY, w: address.width, h: address.height,
                           label: addressLabel,
                           anchor: FocusAnchor(epoch: 2, sampledAt: addressAt, appName: app, resolved: true))
        addr.caret = AXFrame.Rect(x: address.minX + 6, y: address.minY + 8, w: 2, h: 20)
        addr.sampledAt = addressAt
        return [win, tabFrame, addr]
    }

    static func derive(_ duration: Double, events: [InputEvent] = [], ax: [AXFrame] = [],
                       typing: [TypingTrace] = [], activity: [ActivityPoint] = [],
                       markers: [DirectorMarker] = [], maxScale: Double = 2.0,
                       viewport: [ViewportSample]? = nil, ui: [(Double, Double)] = [],
                       tm: TimeMap? = nil, preset: ZoomPreset? = nil) -> Timeline {
        var tl = Timeline(duration: duration)
        tl.audio.speedRampsAuto = false
        tl.camera.autoZoom = true
        tl.camera.maxScale = maxScale
        tl.cropSettings.insetPx = 0
        if let preset { tl.camera.preset = preset }
        if let tm { tl.timeMap = tm }
        let observations = viewport ?? Self.samples(duration, ui: ui)
        let input = DirectorInput(events: events.sorted { $0.t < $1.t }, source: source(duration),
                                  ax: ax, activity: activity, viewportSamples: observations,
                                  typing: typing, markers: markers)
        return Director.derive(tl, input: input, revision: 1)
    }

    static func crop(_ tl: Timeline, _ t: Double) -> CGRect {
        let p = tl.evaluate(at: t).crop
        return CGRect(x: p.x, y: p.y, width: p.w, height: p.h)
    }
    static func scale(_ tl: Timeline, _ t: Double) -> Double { Double(tl.evaluate(at: t).cameraScale) }
    static func near(_ a: CGRect, _ b: CGRect, tol: Double = 2.0) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol &&
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }
    static func insideSource(_ r: CGRect) -> Bool {
        r.origin.x.isFinite && r.origin.y.isFinite && r.width.isFinite && r.height.isFinite &&
        r.minX >= -1 && r.minY >= -1 && r.maxX <= W + 1 && r.maxY <= H + 1
    }
    /// True when the crop shows a positive area of `r`.
    static func shows(_ crop: CGRect, _ r: CGRect) -> Bool {
        let i = crop.intersection(r)
        return !i.isNull && i.width > 0.5 && i.height > 0.5
    }
}

// MARK: - 1. Browser chrome excluded by default

@Suite struct Agent1BrowserChromeTests {
    /// Crop is now app-agnostic: the AXWebArea observation is the evidence, so
    /// the parameterized app names label the same page-geometry expectation.
    @Test(arguments: ["Google Chrome", "Safari", "Arc", "Firefox"])
    func browserDefaultCropExcludesChrome(_ app: String) {
        let tl = A1.derive(8, viewport: A1.samples(8))
        let c = A1.crop(tl, 0.5)
        #expect(A1.near(c, A1.page), "\(app): default crop \(c)")
        #expect(!A1.shows(c, A1.tab), "\(app): tab strip visible")
        #expect(!A1.shows(c, A1.address), "\(app): address bar visible")
        #expect(c.minY >= A1.address.maxY - 0.6, "\(app): crop starts above the page")
        #expect(c.contains(CGPoint(x: 960, y: 600)), "\(app): page centre dropped")
    }

    /// Hostile/partial browser evidence must never invent a crop that eats the page.
    @Test func browserEvidenceNeverEatsThePage() {
        // Invalid web evidence (no AXWebArea, or a zero-size web area) leaves
        // the source uncroped — the safe outcome for garbage observations.
        let noWeb = A1.samples(8, webValid: false)
        let tl = A1.derive(8, viewport: noWeb)
        #expect(A1.near(A1.crop(tl, 0.5), A1.bounds), "bad evidence produced a non-full crop")
        let zeroWeb = A1.samples(8, web: .zero)
        let tl2 = A1.derive(8, viewport: zeroWeb)
        #expect(A1.near(A1.crop(tl2, 0.5), A1.bounds), "zero web area produced a crop")
    }
}

// MARK: - 2. Address-bar typing + mid-typing field change

@Suite struct Agent1TypingFocusTests {
    /// Address-bar typing reveals chrome on the FIRST key and restores after the
    /// last. The zoom shot starts on that same first keystroke.
    @Test func addressBarTypingRevealsOnFirstKeyAndRecrops() {
        let ax = A1.browserAX("Google Chrome", addressAt: 2)
        let keys = (0..<12).map { InputEvent(t: 2.0 + Double($0) * 0.11, kind: .keyDown,
                                             keyCode: UInt16($0 % 40), axFrameIndex: 3) }
        let tl = A1.derive(9, events: keys, ax: ax, ui: [(2.0, 3.4)])
        #expect(A1.near(A1.crop(tl, 1.0), A1.page), "before \(A1.crop(tl, 1.0))")
        #expect(A1.shows(A1.crop(tl, 2.02), A1.address), "not revealed on first key")
        #expect(A1.shows(A1.crop(tl, 2.4), A1.dropdown), "autocomplete not revealed")
        #expect(A1.near(A1.crop(tl, 5.5), A1.page), "after \(A1.crop(tl, 5.5))")
        let shots = tl.zoom.sorted { $0.start < $1.start }
        #expect(shots.count == 1, "made \(shots.count) shots")
        #expect(abs((shots.first?.start ?? -1) - 2.0) < 1e-6, "shot did not start on first key")
    }

    /// Typing first in field A, then (after a real pause) in field B must produce
    /// two distinct shots, each framing its own field — and no camera teleport.
    @Test func midSessionFieldChangeMakesTwoCorrectShots() {
        let fA = CGRect(x: 300, y: 200, width: 500, height: 44)
        let fB = CGRect(x: 900, y: 700, width: 420, height: 44)
        var ax: [AXFrame] = []
        func field(_ r: CGRect, _ t: Double) -> UInt32 {
            var f = AXFrame(x: r.minX, y: r.minY, w: r.width, h: r.height,
                            anchor: FocusAnchor(epoch: 1, sampledAt: t, resolved: true))
            f.sampledAt = t
            f.caret = AXFrame.Rect(x: r.minX + 10, y: r.minY + 6, w: 2, h: 22)
            ax.append(f); return UInt32(ax.count)
        }
        let iA = field(fA, 1.5), iB = field(fB, 4.0)
        var events: [InputEvent] = []
        for k in 0..<8 { events.append(InputEvent(t: 1.5 + Double(k) * 0.12, kind: .keyDown,
                                                  keyCode: UInt16(k), axFrameIndex: iA)) }
        for k in 0..<8 { events.append(InputEvent(t: 4.0 + Double(k) * 0.12, kind: .keyDown,
                                                  keyCode: UInt16(k), axFrameIndex: iB)) }
        let tl = A1.derive(10, events: events, ax: ax, viewport: [])
        let shots = tl.zoom.sorted { $0.start < $1.start }
        #expect(shots.count == 2, "expected 2 field shots, got \(shots.count)")
        guard shots.count == 2 else { return }
        for (s, r) in zip(shots, [fA, fB]) {
            guard case .element(let x, let y, let w, let h) = s.focus else {
                Issue.record("field shot not framed: \(s.focus)"); continue
            }
            let framed = CGRect(x: x * A1.W, y: y * A1.H, width: w * A1.W, height: h * A1.H)
            #expect(A1.near(framed, r, tol: 3), "framed \(framed) != \(r)")
        }
        let last = tl.derived!.camera.lz.count - 1
        #expect(abs(Double(tl.derived!.camera.lz[last])) < 1e-4, "ends zoomed")
    }

    /// A caret jump within the same field must not move the frame at all.
    @Test func caretJumpInsideFieldKeepsFrameBitStill() {
        let r = CGRect(x: 400, y: 200, width: 600, height: 46)
        var f = AXFrame(x: r.minX, y: r.minY, w: r.width, h: r.height,
                        anchor: FocusAnchor(epoch: 1, sampledAt: 1, resolved: true))
        f.caret = AXFrame.Rect(x: r.minX + 8, y: r.minY + 6, w: 2, h: 22)
        var events: [InputEvent] = []
        for k in 0..<10 { events.append(InputEvent(t: 1.0 + Double(k) * 0.1, kind: .keyDown,
                                                   keyCode: UInt16(k), axFrameIndex: 1)) }
        let tl = A1.derive(8, events: events, ax: [f], viewport: [])
        let cam = tl.derived!.camera
        let a = min(cam.lz.count - 1, Int(2.2 * cam.rate)), b = min(cam.lz.count - 1, Int(2.6 * cam.rate))
        guard b > a else { Issue.record("no hold window"); return }
        for k in (a + 1)...b {
            #expect(cam.lz[k] == cam.lz[a], "log-zoom drifted at \(k)")
            #expect(cam.nx[k] == cam.nx[a], "x drifted at \(k)")
            #expect(cam.ny[k] == cam.ny[a], "y drifted at \(k)")
        }
    }
}

// MARK: - 3. Rapid tab switching

@Suite struct Agent1RapidTabTests {
    @Test func rapidTabSwitchingRevealsOnceAndStaysContinuous() {
        var events: [InputEvent] = []
        var t = 1.5
        for i in 0..<12 {
            events.append(InputEvent(t: t, kind: .down, x: 300 + Float(i % 4) * 200,
                                     y: 18, button: 0, axFrameIndex: 2))
            t += 0.13
        }
        let ax = A1.browserAX("Google Chrome")
        let tl = A1.derive(9, events: events, ax: ax)
        #expect(A1.shows(A1.crop(tl, 1.7), A1.tab), "tab not revealed during rapid switching")
        var returns = 0
        var prev = A1.crop(tl, 1.4)
        for k in 0..<Int(6.0 * 480) {
            let tt = 1.4 + Double(k) / 480
            let c = A1.crop(tl, tt)
            #expect(A1.insideSource(c), Comment(rawValue: "crop outside source at \(tt): \(c)"))
            if A1.near(c, A1.page, tol: 1) && !A1.near(prev, A1.page, tol: 1) { returns += 1 }
            let jump = max(abs(c.minX - prev.minX), abs(c.minY - prev.minY),
                           abs(c.width - prev.width), abs(c.height - prev.height)) / A1.W
            #expect(jump < 0.02, Comment(rawValue: "crop jump \(jump) at \(tt)"))
            prev = c
        }
        #expect(returns <= 1, "crop pumped \(returns) times")
        #expect(A1.near(A1.crop(tl, 8.0), A1.page), "did not re-crop at the end")
        #expect(tl.zoom.allSatisfy { $0.end - $0.start <= 4.0 }, "shot > 4s: \(tl.zoom)")
    }
}

// MARK: - 4. Hostile frames + 1x1 source + cap = 1.0

@Suite struct Agent1DegenerateTests {
    @Test func hostileAXFramesNeverCorruptCameraOrCrop() {
        var ax: [AXFrame] = []
        let nan = AXFrame(x: .nan, y: .nan, w: .nan, h: .nan,
                          label: "Address and search bar",
                          anchor: FocusAnchor(epoch: 1, sampledAt: .nan, appName: "Google Chrome", resolved: true))
        let inf = AXFrame(x: .infinity, y: -.infinity, w: 1e300, h: 1e300,
                          label: "window|huge", anchor: FocusAnchor(epoch: 2, sampledAt: 1, resolved: true))
        let negative = AXFrame(x: -5000, y: -5000, w: -20, h: -20,
                               anchor: FocusAnchor(epoch: 3, sampledAt: 2, resolved: true))
        ax += [nan, inf, negative]
        var events: [InputEvent] = [
            InputEvent(t: 1, kind: .down, x: 100, y: 20, button: 0, axFrameIndex: 1),
            InputEvent(t: 2, kind: .keyDown, keyCode: 3, axFrameIndex: 2),
            InputEvent(t: 3, kind: .down, x: 900, y: 500, button: 0, axFrameIndex: 3),
        ]
        events.append(contentsOf: (0..<8).map { InputEvent(t: 4 + Double($0) * 0.1,
            kind: .keyDown, keyCode: UInt16($0), axFrameIndex: 1) })

        // Hostile viewport evidence: an invalid web area is flagged webValid=false
        // and a non-finite window is rejected by PxRect.isValid in the planner.
        var bad = A1.samples(9)
        bad[3] = ViewportSample(ViewportRecord(t: 0.3, flags: [.browserFront],
                                window: PxRect(x: .nan, y: .nan, w: .nan, h: .nan),
                                web: PxRect(x: .nan, y: .nan, w: .nan, h: .nan)))
        bad[4].window = PxRect(x: .infinity, y: -.infinity, w: 1e300, h: 1e300)
        bad[5] = ViewportSample(ViewportRecord(t: 0.5, flags: [.browserFront],
                                window: PxRect(x: -5000, y: -5000, w: -20, h: -20),
                                web: PxRect(x: -5000, y: -5000, w: -20, h: -20)))
        let tl = A1.derive(9, events: events, ax: ax, viewport: bad)
        let cam = tl.derived!.camera
        for k in cam.lz.indices {
            let z = Double(cam.lz[k]), x = Double(cam.nx[k]), y = Double(cam.ny[k])
            #expect(z.isFinite && x.isFinite && y.isFinite, Comment(rawValue: "non-finite pose at \(k)"))
            #expect(z >= -1e-6 && z <= log(2.0) + 1e-4, Comment(rawValue: "cap at \(k): \(z)"))
            let half = 0.5 / exp(max(z, 0))
            #expect(x >= half - 1e-5 && x <= 1 - half + 1e-5, Comment(rawValue: "x infeasible at \(k)"))
            #expect(y >= half - 1e-5 && y <= 1 - half + 1e-5, Comment(rawValue: "y infeasible at \(k)"))
        }
        for k in 0..<300 {
            let c = A1.crop(tl, Double(k) / 30)
            #expect(A1.insideSource(c), Comment(rawValue: "bad crop at \(k): \(c)"))
        }
    }

    @Test func oneByOneSourceDegradesToFullFrame() {
        let src = SourceInfo(width: 1, height: 1, fps: 60, duration: 4,
                             backingScale: 1, originX: 0, originY: 0)
        var tl = Timeline(duration: 4)
        tl.audio.speedRampsAuto = false
        let ev = [InputEvent(t: 1, kind: .down, x: 0.5, y: 0.5, button: 0, axFrameIndex: 1)]
        let ax = [AXFrame(x: 0, y: 0, w: 1, h: 1, anchor: FocusAnchor(epoch: 1, sampledAt: 1, resolved: true))]
        tl = Director.derive(tl, input: DirectorInput(events: ev, source: src, ax: ax), revision: 1)
        for t in stride(from: 0.0, through: 3.9, by: 0.1) {
            let f = tl.evaluate(at: t)
            #expect(f.cameraScale.isFinite && f.cameraScale >= 1, "bad scale at \(t)")
            #expect(f.crop.x.isFinite && f.crop.y.isFinite &&
                    f.crop.w.isFinite && f.crop.h.isFinite, "bad crop at \(t)")
            #expect(f.cropRect.width.isFinite && f.cropRect.height.isFinite, "bad legacy crop at \(t)")
        }
    }

    @Test(arguments: [ZoomPreset.balanced, .fixed])
    func maxScaleCapOfOneProducesNoZoom(_ preset: ZoomPreset) {
        let ev = [InputEvent(t: 2, kind: .down, x: 700, y: 400, button: 0)]
        let tl = A1.derive(8, events: ev, maxScale: 1.0, viewport: [], preset: preset)
        let cam = tl.derived!.camera
        for k in cam.lz.indices {
            let z = Double(cam.lz[k])
            #expect(z >= -1e-6 && z <= 0.0002, Comment(rawValue: "\(preset): zoomed past cap=1 at \(k): \(z)"))
        }
        #expect(abs(Double(cam.lz[cam.lz.count - 1])) < 1e-5, "\(preset): ends zoomed")
    }
}

// MARK: - 5. Trim / cut / ramp time maps

@Suite struct Agent1TimeMapTests {
    @Test func trimCutAndRampKeepRevealOnItsFrame() {
        let chrome = CGRect(x: 520, y: 24, width: 700, height: 34)
        let events = [InputEvent(t: 5, kind: .down, x: Float(chrome.midX), y: Float(chrome.midY),
                                 button: 0, axFrameIndex: 1)]
        var tm = TimeMap(sourceDuration: 12, trimStart: 2, trimEnd: 12,
                         ramps: [SpeedRamp(start: 6, end: 8, speed: 2)],
                         cuts: [CutRange(start: 9, end: 10)])
        let tl = A1.derive(12, events: events, viewport: A1.samples(12), tm: tm)
        let outAtClick = tl.timeMap.output(atSource: 5)
        #expect(A1.shows(A1.crop(tl, outAtClick), chrome),
                Comment(rawValue: "reveal off frame: out=\(outAtClick), crop=\(A1.crop(tl, outAtClick))"))
        let cam = tl.derived!.camera
        for k in cam.lz.indices {
            #expect(Double(cam.lz[k]).isFinite && Double(cam.lz[k]) >= -1e-6,
                    Comment(rawValue: "bad camera at \(k)"))
        }
        #expect(abs(Double(cam.lz[cam.lz.count - 1])) < 1e-4, "ends zoomed under trim/cut/ramp")
        for k in 0..<200 {
            let c = A1.crop(tl, Double(k) / 20)
            #expect(A1.insideSource(c), Comment(rawValue: "crop outside source at \(k): \(c)"))
        }
    }
}

// MARK: - 6. 500 seeded mixed browser + typing + dialog + activity scenarios

enum A1Mixed {
    static func make(seed: UInt64) -> (dur: Double, events: [InputEvent], ax: [AXFrame],
                                       activity: [ActivityPoint], markers: [DirectorMarker]) {
        var r = BrutalRng(seed &* 0xBF58476D1CE4E5B9)
        let dur = r.d(5.0, 9.0)
        var ax = A1.browserAX(r.chance(0.5) ? "Google Chrome" : "Safari", addressAt: 1.5)
        var events: [InputEvent] = []
        var activity: [ActivityPoint] = []
        var markers: [DirectorMarker] = []
        var t = 0.6
        while t < dur - 0.5 {
            switch r.i(0, 3) {
            case 0:
                let idx = UInt32(ax.count)
                for k in 0..<r.i(3, 9) {
                    events.append(InputEvent(t: t + Double(k) * 0.11, kind: .keyDown,
                                             keyCode: UInt16(k % 40), axFrameIndex: idx))
                }
                t += 1.2
            case 1:
                events.append(InputEvent(t: t, kind: .down, x: Float(r.d(200, 1600)),
                                         y: Float(r.d(0, 70)), button: 0, axFrameIndex: 2))
                t += r.d(0.4, 1.0)
            case 2:
                var d = AXFrame(x: r.d(500, 900), y: r.d(250, 500), w: r.d(400, 700), h: r.d(300, 500),
                                label: "window|AXSheet|dialog",
                                anchor: FocusAnchor(epoch: UInt32(r.i(1, 9)), sampledAt: t,
                                                    appName: "Google Chrome", resolved: true))
                d.sampledAt = t
                ax.append(d)
                events.append(InputEvent(t: t, kind: .down, x: Float(d.x + 10), y: Float(d.y + 10),
                                         button: 0, axFrameIndex: UInt32(ax.count)))
                markers.append(DirectorMarker(start: t, end: t + 0.5))
                t += r.d(1.0, 1.6)
            default:
                activity.append(ActivityPoint(t: t, x: r.d(200, 1700), y: r.d(120, 1000),
                                              region: CGRect(x: r.d(200, 1200), y: r.d(120, 700),
                                                             width: r.d(80, 400), height: r.d(80, 300)),
                                              coverage: r.d(0, 1)))
                events.append(InputEvent(t: t, kind: .down, x: Float(r.d(200, 1700)),
                                         y: Float(r.d(120, 1000)), button: 0))
                t += r.d(0.5, 1.2)
            }
        }
        return (dur, events, ax, activity, markers)
    }
}

@Suite struct Agent1FiveHundredSeedTests {
    /// 500 deterministic mixed sessions. Every one must: stay finite and capped,
    /// never show canvas outside the source, never teleport, end on the full
    /// frame, and keep long shots tied to a resolved field subject. A sampled
    /// subset also checks warm/cold byte-identical replays.
    @Test func fiveHundredSeededMixedSessionsHoldEveryInvariant() {
        var failures: [String] = []
        for seed in UInt64(1)...500 {
            let s = A1Mixed.make(seed: seed)
            let dur = s.dur, events = s.events, ax = s.ax, activity = s.activity, markers = s.markers
            let observations = A1.samples(dur)
            let tl = A1.derive(dur, events: events, ax: ax, activity: activity,
                               markers: markers, viewport: observations)
            guard let cam = tl.derived?.camera else {
                failures.append("seed \(seed): no camera"); continue
            }
            let n = cam.lz.count
            for k in cam.lz.indices {
                let z = Double(cam.lz[k]), x = Double(cam.nx[k]), y = Double(cam.ny[k])
                if !z.isFinite || !x.isFinite || !y.isFinite {
                    failures.append("seed \(seed): non-finite at \(k)"); break
                }
                if z < -1e-6 || z > log(2.0) + 1e-4 {
                    failures.append("seed \(seed): cap/under at \(k): \(z)"); break
                }
                let half = 0.5 / exp(max(z, 0))
                if x < half - 2e-5 || x > 1 - half + 2e-5 || y < half - 2e-5 || y > 1 - half + 2e-5 {
                    failures.append("seed \(seed): infeasible centre at \(k)"); break
                }
            }
            if abs(Double(cam.lz[n - 1])) > 1e-4 { failures.append("seed \(seed): ends zoomed") }
            for k in 1..<n {
                if abs(Double(cam.nx[k]) - Double(cam.nx[k - 1])) > 0.02 ||
                   abs(Double(cam.ny[k]) - Double(cam.ny[k - 1])) > 0.02 {
                    failures.append("seed \(seed): teleport at \(k)"); break
                }
            }
            for sh in tl.zoom where sh.end - sh.start > 4.0 {
                if sh.end - sh.start > 6.7 {
                    failures.append(String(format: "seed %llu: shot %.2f-%.2f exceeds 6.5s cap",
                                           seed, sh.start, sh.end)); break
                }
                guard case .element = sh.focus else {
                    failures.append(String(format: "seed %llu: long shot %.2f-%.2f has no field subject",
                                           seed, sh.start, sh.end)); break
                }
            }
            for k in 0..<Int((dur - 0.1) * 60) {
                let c = A1.crop(tl, Double(k) / 60)
                if !A1.insideSource(c) {
                    failures.append("seed \(seed): crop outside source at \(k): \(c)"); break
                }
                if !c.origin.x.isFinite || !c.width.isFinite {
                    failures.append("seed \(seed): non-finite crop at \(k)"); break
                }
            }
            if seed % 5 == 0 {
                let again = A1.derive(dur, events: events, ax: ax, activity: activity,
                                      markers: markers, viewport: observations)
                if tl.derived?.camera != again.derived?.camera {
                    failures.append("seed \(seed): camera not byte-identical on replay")
                }
            }
            if failures.count > 12 { break }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
}

// MARK: - 7. Hover-only and long-session regressions

@Suite struct Agent1HoverAndLongTests {
    @Test func denseHoverAndScrollOnlyNeverZooms() {
        var events: [InputEvent] = []
        for i in 0..<400 {
            let t = 0.1 + Double(i) * 0.02
            events.append(InputEvent(t: t, kind: i % 5 == 0 ? .scroll : .move,
                                     x: Float(400 + (i * 37) % 1100), y: Float(200 + (i * 53) % 700),
                                     scrollDelta: i % 5 == 0 ? 3 : 0))
        }
        let tl = A1.derive(9, events: events, viewport: [])
        #expect(tl.zoom.isEmpty, "hover/scroll created \(tl.zoom.count) shots")
        let cam = tl.derived!.camera
        for k in cam.lz.indices {
            #expect(abs(Double(cam.lz[k])) < 1e-6, Comment(rawValue: "hover zoomed at \(k)"))
        }
    }

    @Test func sixtySecondDenseSessionHasNoShotOverFourSeconds() {
        var events: [InputEvent] = []
        var t = 0.5
        var i = 0
        while t < 59.0 {
            events.append(InputEvent(t: t, kind: .down,
                                     x: Float(200 + (i * 277) % 1500), y: Float(120 + (i * 191) % 800),
                                     button: 0))
            t += 0.35; i += 1
        }
        let tl = A1.derive(60, events: events, viewport: [])
        for s in tl.zoom {
            #expect(s.end - s.start <= 4.0, Comment(rawValue: "shot \(s.start)-\(s.end) exceeds 4s"))
        }
        let cam = tl.derived!.camera
        #expect(abs(Double(cam.lz[cam.lz.count - 1])) < 1e-4, "60s session did not end full frame")
        let finalTick = Double(cam.lz.count - 1) / cam.rate
        #expect(A1.scale(tl, finalTick) <= 1.001, "not full frame at final tick \(finalTick)")
    }
}
