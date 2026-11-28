import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - Browser chrome default crop (headless)
//
// The browser-chrome detector was replaced by the AXWebArea viewport recorder.
// These tests now feed synthetic `ViewportSample` observations through
// `DirectorInput.viewportSamples` and assert the derived `FrameState.crop`.
// They drive `Director.derive` and `Timeline.evaluate(at:)`, the exact path
// preview and export use.

enum BCProbe {
    static let W = 1920.0, H = 1080.0
    static let bounds = CGRect(x: 0, y: 0, width: W, height: H)
    static let tab = CGRect(x: 0, y: 0, width: W, height: 36)
    static let address = CGRect(x: 300, y: 44, width: 800, height: 34)
    static let dropdown = CGRect(x: 300, y: 78, width: 800, height: 380)
    static let page = SmartCropPlanner.fitInside(CGRect(x: 0, y: 78, width: W, height: H - 78),
                                                  source: bounds)
    static let pageCentre = CGPoint(x: 960, y: 600)

    static func source(_ dur: Double = 8) -> SourceInfo {
        SourceInfo(width: Int(W), height: Int(H), fps: 60, duration: dur,
                   backingScale: 2, originX: 0, originY: 0)
    }

    /// A 10 Hz browser observation stream. `ui` intervals mark chrome focus
    /// (the address bar), which is the evidence `CropPlanner` uses to uncrop.
    static func samples(_ dur: Double = 8, ui: [(Double, Double)] = []) -> [ViewportSample] {
        let count = Int((dur * 10).rounded(.down))
        return (0...count).map { i in
            let t = Double(i) / 10
            let chromeFocus = ui.contains { t >= $0.0 - 1e-9 && t <= $0.1 + 1e-9 }
            var flags: ViewportRecord.Flags = [.browserFront, .webValid]
            if chromeFocus { flags.insert(.uiFocus) }
            return ViewportSample(ViewportRecord(
                t: t, flags: flags,
                window: PxRect(x: 0, y: 0, w: W, h: H),
                web: PxRect(x: page.minX, y: page.minY, w: page.width, h: page.height)))
        }
    }

    static func browserAX(addressAt: Double = 2) -> [AXFrame] {
        let web = "Google Chrome"
        let win = AXFrame(x: 0, y: 0, w: W, h: H,
                          label: "window|AXWindow|AXStandardWindow|Google Chrome",
                          anchor: FocusAnchor(epoch: 1, sampledAt: 0, appName: web, resolved: true))
        let tabFrame = AXFrame(x: tab.minX, y: tab.minY, w: tab.width, h: tab.height,
                               label: "New Tab",
                               anchor: FocusAnchor(epoch: 1, sampledAt: 0, appName: web, resolved: true))
        var addr = AXFrame(x: address.minX, y: address.minY, w: address.width, h: address.height,
                           label: "Address and search bar",
                           anchor: FocusAnchor(epoch: 2, sampledAt: addressAt, appName: web, resolved: true))
        addr.caret = AXFrame.Rect(x: address.minX + 6, y: address.minY + 8, w: 2, h: 20)
        addr.sampledAt = addressAt
        return [win, tabFrame, addr]
    }

    static func derive(_ events: [InputEvent], _ ax: [AXFrame] = [], _ dur: Double = 8,
                       ui: [(Double, Double)] = [], samples: [ViewportSample]? = nil) -> Timeline {
        var tl = Timeline(duration: dur)
        tl.audio.speedRampsAuto = false
        // Keep the geometric assertions exact: the default 2 px inset hides the
        // AX rounding at the page edge, which this suite does not measure.
        tl.cropSettings.insetPx = 0
        // Keep the legacy tab-click expectation: one chrome reveal that has
        // returned to the page by 3.6 s after a click at 2 s.
        tl.cropSettings.holdAfterUIClick = 0.8
        let observations = samples ?? Self.samples(dur, ui: ui)
        return Director.derive(tl, input: DirectorInput(events: events.sorted { $0.t < $1.t },
                                                        source: source(dur), ax: ax,
                                                        viewportSamples: observations), revision: 1)
    }

    static func crop(_ tl: Timeline, at t: Double) -> CGRect {
        let p = tl.evaluate(at: t).crop
        // Director maps a degenerate crop track to `.zero`, meaning "no
        // source-pixel crop" — the full source stays visible. Resolve that
        // sentinel to the source bounds so callers assert the semantic rect.
        guard p.w > 1, p.h > 1 else { return bounds }
        return CGRect(x: p.x, y: p.y, width: p.w, height: p.h)
    }

    static func near(_ a: CGRect, _ b: CGRect, tol: CGFloat = 3.0) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol &&
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// A zero-width/height touch at the page edge is not visible chrome.
    static func coversArea(_ a: CGRect, _ b: CGRect) -> Bool {
        let r = a.intersection(b)
        return !r.isNull && r.width > 0.5 && r.height > 0.5
    }
}

@Suite struct TypingFocusBrowserCropTests {
    /// Full-display capture with no Area ROI: the browser page is cropped by
    /// default. Tabs, address bar and the autocomplete zone are all excluded.
    @Test func browserFullDisplayDefaultCropExcludesAllChrome() {
        let observations = BCProbe.samples(8)
        guard let web = observations.first?.web else {
            Issue.record("viewport stream is empty"); return
        }
        #expect(BCProbe.near(CGRect(x: web.x, y: web.y, width: web.w, height: web.h), BCProbe.page),
                "synthetic web area does not match the expected page")

        let tl = BCProbe.derive([], samples: observations)
        let at0 = BCProbe.crop(tl, at: 0.5)
        #expect(tl.derived?.viewportCrop.rects.isEmpty == false, "crop track is empty")
        #expect(BCProbe.near(at0, BCProbe.page), "default crop \(at0)")
        #expect(!BCProbe.coversArea(at0, BCProbe.tab), "tab strip is still visible")
        #expect(!BCProbe.coversArea(at0, BCProbe.address), "address bar is still visible")
        #expect(at0.minY >= BCProbe.address.maxY - 0.6, "crop starts above the page")
        #expect(at0.contains(BCProbe.pageCentre), "page content must stay in frame")

        // A non-browser recording has no viewport evidence: the source stays whole.
        let nonBrowser = BCProbe.derive([], samples: [])
        #expect(BCProbe.near(BCProbe.crop(nonBrowser, at: 0.5), BCProbe.bounds),
                "non-browser got a crop")
    }

    /// Typing in the address bar uncrops while the keys are being typed — and
    /// only then. The zoom shot and the crop start on the same first keystroke.
    @Test func addressBarTypingUncropsThenRecrops() {
        let ax = BCProbe.browserAX(addressAt: 2)
        let keys = (0..<10).map { InputEvent(t: 2.0 + Double($0) * 0.11,
                                             kind: .keyDown, keyCode: UInt16($0 % 40),
                                             axFrameIndex: 3) }
        let tl = BCProbe.derive(keys, ax, 9, ui: [(2.0, 3.1)])
        let before = BCProbe.crop(tl, at: 1.0)
        let during = BCProbe.crop(tl, at: 2.15)
        // Recrop is a 0.7 s quintic after a 0.8 s typing hold; assert after it settles.
        let after = BCProbe.crop(tl, at: 5.0)
        #expect(BCProbe.near(before, BCProbe.page), "before \(before)")
        #expect(during.contains(BCProbe.address), "address bar not revealed while typing: \(during)")
        #expect(BCProbe.coversArea(during, BCProbe.dropdown), "autocomplete was not revealed: \(during)")
        #expect(BCProbe.near(after, BCProbe.page), "after \(after)")

        let shots = tl.zoom.sorted { $0.start < $1.start }
        #expect(shots.count == 1, "address-bar typing made \(shots.count) shots")
        #expect(abs((shots.first?.start ?? -1) - 2.0) < 1e-6,
                "zoom did not start on the first key")
        guard case .element(let x, let y, let w, let h) = shots.first?.focus else {
            Issue.record("typing shot must frame the field"); return
        }
        let framed = CGRect(x: x * BCProbe.W, y: y * BCProbe.H,
                            width: w * BCProbe.W, height: h * BCProbe.H)
        #expect(BCProbe.near(framed, BCProbe.address), "framed \(framed)")
    }

    /// Clicking a tab reveals chrome, then the crop returns to the page.
    @Test func tabClickUncropsThenRecrops() {
        let click = InputEvent(t: 2.0, kind: .down, x: 500, y: 18, button: 0, axFrameIndex: 2)
        let ax = BCProbe.browserAX()
        let tl = BCProbe.derive([click], ax, 8)
        #expect(BCProbe.near(BCProbe.crop(tl, at: 1.0), BCProbe.page))
        #expect(BCProbe.coversArea(BCProbe.crop(tl, at: 2.1), BCProbe.tab),
                "tab click did not reveal chrome")
        #expect(BCProbe.near(BCProbe.crop(tl, at: 3.6), BCProbe.page), "chrome did not re-crop")
    }

    /// A click on the page never reveals chrome, no matter how long it holds.
    @Test func pageClickNeverUncrops() {
        let click = InputEvent(t: 2.0, kind: .down, x: 720, y: 440, button: 0, axFrameIndex: 4)
        let tl = BCProbe.derive([click], [], 8)
        for t in stride(from: 1.0, through: 4.0, by: 1 / 60) {
            #expect(BCProbe.near(BCProbe.crop(tl, at: t), BCProbe.page),
                    Comment(rawValue: "page click revealed chrome at \(t)"))
        }
    }

    /// A newly opened dialog stays a first-class subject while the page crop
    /// remains the default around it.
    @Test func dialogRemainsFirstClassSubjectUnderBrowserCrop() {
        var ax = BCProbe.browserAX()
        let dialog = CGRect(x: 620, y: 260, width: 680, height: 440)
        ax.append(AXFrame(x: dialog.minX, y: dialog.minY, w: dialog.width, h: dialog.height,
                          label: "window|AXSheet|AXStandardSheet|Share your card",
                          anchor: FocusAnchor(epoch: 4, sampledAt: 5, appName: "Google Chrome",
                                              resolved: true)))
        let click = InputEvent(t: 5.0, kind: .down, x: 960, y: 480, button: 0, axFrameIndex: 4)
        let tl = BCProbe.derive([click], ax, 9)
        let segs = tl.zoom.sorted { $0.start < $1.start }
        #expect(segs.count == 1, "dialog click produced \(segs.count) shots")
        guard let s = segs.first else { return }
        guard case .element(let x, let y, let w, let h) = s.focus else {
            Issue.record("dialog must be framed whole, got \(s.focus)"); return
        }
        let framed = CGRect(x: x * BCProbe.W, y: y * BCProbe.H,
                            width: w * BCProbe.W, height: h * BCProbe.H)
        #expect(BCProbe.near(framed, dialog), "dialog framed as \(framed)")
        let c = BCProbe.crop(tl, at: 5.2)
        #expect(c.width >= BCProbe.page.width - 0.6 && c.height >= BCProbe.page.height - 0.6,
                "dialog shrank the page crop: \(c)")
    }

    /// No teleport, no NaN and no canvas outside the source, over 60 seeded
    /// mixed sessions — and identical crops on repeated derivation.
    @Test func sixtySeedCropContinuityAndDeterminism() {
        var rng = BrutalRng(20261118)
        var failures: [String] = []
        for seed in 1...60 {
            var events: [InputEvent] = []
            var ui: [(Double, Double)] = []
            for _ in 0..<rng.i(1, 4) {
                let t = rng.d(0.5, 5.5)
                if rng.chance(0.5) {
                    let end = t + Double(rng.i(2, 5)) * 0.1
                    ui.append((t, end))
                    for k in 0..<4 {
                        events.append(InputEvent(t: t + Double(k) * 0.1, kind: .keyDown,
                                                 keyCode: UInt16(k)))
                    }
                } else {
                    events.append(InputEvent(t: t, kind: .down,
                                             x: Float(rng.d(100, 1500)),
                                             y: Float(rng.d(120, 800)), button: 0))
                }
            }
            let observations = BCProbe.samples(8, ui: ui)
            let a = BCProbe.derive(events, [], 8, samples: observations)
            let b = BCProbe.derive(events, [], 8, samples: observations)
            guard let ca = a.derived?.viewportCrop, let cb = b.derived?.viewportCrop else {
                failures.append("seed \(seed): no crop track"); continue
            }
            guard ca == cb else {
                failures.append("seed \(seed): nondeterministic crop track"); continue
            }
            var prev = BCProbe.crop(a, at: 0)
            for k in 1...Int(7.9 * 60) {
                let t = Double(k) / 60
                let c = BCProbe.crop(a, at: t)
                guard c.origin.x.isFinite, c.origin.y.isFinite,
                      c.width.isFinite, c.height.isFinite else {
                    failures.append("seed \(seed): non-finite crop at \(t)"); break
                }
                if c.minX < -0.5 || c.minY < -0.5 || c.maxX > BCProbe.W + 0.5 ||
                   c.maxY > BCProbe.H + 0.5 {
                    failures.append("seed \(seed): crop outside source at \(t)"); break
                }
                let jump = max(abs(c.minX - prev.minX), abs(c.minY - prev.minY),
                               abs(c.width - prev.width), abs(c.height - prev.height)) / BCProbe.W
                if jump > 0.02 {
                    failures.append("seed \(seed): crop jump \(jump) at \(t)"); break
                }
                prev = c
            }
            if failures.count > 6 { break }
        }
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
}

@Test func browserChromeClicksRequireFreshCausalEvidence() {
    let click = InputEvent(t: 2, kind: .down, x: 500, y: 18, button: 0)
    let samples = BCProbe.samples()
    let stale = samples.filter { $0.t == 0 }
    let future = samples.filter { $0.t == 3 }
    let fresh = samples.filter { $0.t == 1.9 }
    #expect(CropInputs.make(events: [click], samples: stale).uiClicks.isEmpty)
    #expect(CropInputs.make(events: [click], samples: future).uiClicks.isEmpty)
    #expect(CropInputs.make(events: [click], samples: fresh).uiClicks == [2])
}

@Test func pageTypingKeepsChromeHiddenByDefault() {
    let duration = 8.0
    let observations = BCProbe.samples(duration)
    let inputs = CropInputs(keys: [2, 2.1, 2.2, 2.3, 2.4], uiClicks: [])
    let source = PxRect(x: 0, y: 0, w: BCProbe.W, h: BCProbe.H)
    var settings = CropSettings()
    #expect(settings.uncrop == .chromeTyping)
    let page = CropPlanner.plan(samples: observations, inputs: inputs, duration: duration,
                                source: source, settings: settings)
    #expect(!page.changes.contains { $0.mode == .window })
    settings.uncrop = .anyTyping
    let legacy = CropPlanner.plan(samples: observations, inputs: inputs, duration: duration,
                                  source: source, settings: settings)
    #expect(legacy.changes.contains { $0.mode == .window })
}
