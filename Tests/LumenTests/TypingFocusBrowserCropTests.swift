import Foundation
import Testing
import CoreGraphics
import LumenCore
import LumenProject
@testable import LumenDirector

// MARK: - Browser chrome default crop (headless)
//
// Evidence: all 18 screenshots show tabs, the address bar and the autocomplete
// panel inside the zoomed frame. These tests drive `Director.derive` and
// `Timeline.evaluate(at:)`, the exact path preview and export use.

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

    static func derive(_ events: [InputEvent], _ ax: [AXFrame], _ dur: Double = 8) -> Timeline {
        var tl = Timeline(duration: dur)
        tl.audio.speedRampsAuto = false
        return Director.derive(tl, input: DirectorInput(events: events.sorted { $0.t < $1.t },
                                                       source: source(dur), ax: ax), revision: 1)
    }

    static func crop(_ tl: Timeline, at t: Double) -> CGRect { tl.evaluate(at: t).cropRect }

    static func near(_ a: CGRect, _ b: CGRect, tol: CGFloat = 2.0) -> Bool {
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
        let ax = BCProbe.browserAX()
        guard let detected = BrowserChrome.detect(ax: ax, source: BCProbe.source()) else {
            Issue.record("browser chrome was not detected from AX labels"); return
        }
        #expect(BCProbe.near(detected, BCProbe.page), "detected \(detected)")

        let tl = BCProbe.derive([], ax)
        #expect(tl.derived?.crop.keys.isEmpty == false, "crop track is empty")
        let at0 = BCProbe.crop(tl, at: 0.5)
        #expect(BCProbe.near(at0, BCProbe.page), "default crop \(at0)")
        #expect(!BCProbe.coversArea(at0, BCProbe.tab), "tab strip is still visible")
        #expect(!BCProbe.coversArea(at0, BCProbe.address), "address bar is still visible")
        #expect(at0.minY >= BCProbe.address.maxY - 0.6, "crop starts above the page")
        #expect(at0.contains(BCProbe.pageCentre), "page content must stay in frame")

        // A non-browser recording must be untouched: no crop keys at all.
        let plain = [AXFrame(x: 100, y: 100, w: 200, h: 40,
                             anchor: FocusAnchor(epoch: 1, sampledAt: 1, resolved: true))]
        let nonBrowser = BCProbe.derive([], plain)
        #expect(nonBrowser.derived?.crop.keys.isEmpty == true, "non-browser got a crop")
    }

    /// Typing in the address bar uncrops while the keys are being typed — and
    /// only then. The zoom shot and the crop start on the same first keystroke.
    @Test func addressBarTypingUncropsThenRecrops() {
        let ax = BCProbe.browserAX(addressAt: 2)
        let keys = (0..<10).map { InputEvent(t: 2.0 + Double($0) * 0.11,
                                            kind: .keyDown, keyCode: UInt16($0 % 40),
                                            axFrameIndex: 3) }
        let tl = BCProbe.derive(keys, ax, 9)
        let before = BCProbe.crop(tl, at: 1.0)
        let during = BCProbe.crop(tl, at: 2.15)
        let after = BCProbe.crop(tl, at: 4.5)
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
        let ax = BCProbe.browserAX()
        let click = InputEvent(t: 2.0, kind: .down, x: 500, y: 18, button: 0, axFrameIndex: 2)
        let tl = BCProbe.derive([click], ax, 8)
        #expect(BCProbe.near(BCProbe.crop(tl, at: 1.0), BCProbe.page))
        #expect(BCProbe.crop(tl, at: 2.1).intersects(BCProbe.tab), "tab click did not reveal chrome")
        #expect(BCProbe.near(BCProbe.crop(tl, at: 3.6), BCProbe.page), "chrome did not re-crop")
    }

    /// A click on the page never reveals chrome, no matter how long it holds.
    @Test func pageClickNeverUncrops() {
        var ax = BCProbe.browserAX()
        let inside = CGRect(x: 600, y: 400, width: 240, height: 80)
        ax.append(AXFrame(x: inside.minX, y: inside.minY, w: inside.width, h: inside.height,
                          anchor: FocusAnchor(epoch: 3, sampledAt: 2, resolved: true)))
        let click = InputEvent(t: 2.0, kind: .down, x: 720, y: 440, button: 0, axFrameIndex: 4)
        let tl = BCProbe.derive([click], ax, 8)
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
            var ax = BCProbe.browserAX(addressAt: 2)
            var events: [InputEvent] = []
            for _ in 0..<rng.i(1, 4) {
                let t = rng.d(0.5, 5.5)
                if rng.chance(0.5) {
                    let r = CGRect(x: rng.d(320, 1050), y: 44, width: 120, height: 34)
                    ax.append(AXFrame(x: r.minX, y: r.minY, w: r.width, h: r.height,
                                      label: "Address and search bar",
                                      anchor: FocusAnchor(epoch: 5, sampledAt: t, resolved: true)))
                    let idx = UInt32(ax.count)
                    for k in 0..<4 {
                        events.append(InputEvent(t: t + Double(k) * 0.1, kind: .keyDown,
                                                 keyCode: UInt16(k), axFrameIndex: idx))
                    }
                } else {
                    let r = CGRect(x: rng.d(100, 1500), y: rng.d(120, 800),
                                   width: 160, height: 60)
                    ax.append(AXFrame(x: r.minX, y: r.minY, w: r.width, h: r.height,
                                      anchor: FocusAnchor(epoch: 6, sampledAt: t, resolved: true)))
                    events.append(InputEvent(t: t, kind: .down, x: Float(r.midX),
                                             y: Float(r.midY), button: 0, axFrameIndex: UInt32(ax.count)))
                }
            }
            let a = BCProbe.derive(events, ax, 8)
            let b = BCProbe.derive(events, ax, 8)
            guard let ka = a.derived?.crop.keys, let kb = b.derived?.crop.keys else {
                failures.append("seed \(seed): no crop track"); continue
            }
            guard ka.count == kb.count else {
                failures.append("seed \(seed): nondeterministic key count"); continue
            }
            for (p, q) in zip(ka, kb) where !BCProbe.near(p.rect, q.rect) || abs(p.t - q.t) > 1e-9 {
                failures.append("seed \(seed): crop differs"); break
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
