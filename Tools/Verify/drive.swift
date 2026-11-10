// drive — CGEvent driver for the Lumen zoom scripted demo (plan §9c).
// Needs Accessibility + Input Monitoring. Posts to .cghidEventTap so
// Lumen's CGEventTap recorder sees every event.
// Build: swiftc -O -o Tools/Verify/drive Tools/Verify/drive.swift -framework CoreGraphics -framework AppKit
//
// The demo runs against a browser window showing playground/calibration.html.
// Points are absolute screen points measured from the live window with
// Tools/Verify/locate (Safari at {0,0,1440,798} on the 1440x900 pt display).
import CoreGraphics
import Foundation
import AppKit

func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

// Interpolate from the current cursor to p with a smoothstep easing.
func glide(to p: CGPoint, dur: Double = 0.45) {
    let from = CGEvent(source: nil)?.location ?? .zero
    let n = max(Int(dur * 120), 1)
    for i in 1...n {
        let k = Double(i) / Double(n), s = k * k * (3 - 2 * k)
        let pt = CGPoint(x: from.x + (p.x - from.x) * s, y: from.y + (p.y - from.y) * s)
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left))
        usleep(UInt32(1e6 / 120))
    }
}

func click(_ p: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
    usleep(70_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
}

func type(_ s: String, gap: useconds_t = 80_000) {
    for var u in s.utf16 {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
            e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
            e?.flags = []   // never inherit a stuck modifier state
            post(e)
        }
        usleep(gap)
    }
}

func key(_ virtualKey: CGKeyCode, flags: CGEventFlags = [], down: Bool = true) {
    if let e = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: down) {
        e.flags = flags
        post(e)
    }
}

func cmdKey(_ virtualKey: CGKeyCode) {
    key(virtualKey, flags: .maskCommand, down: true)
    key(virtualKey, flags: [], down: false)   // key-up must clear the modifier
}

func scroll(_ dy: Double) {
    // No Swift scroll-wheel initializer on this SDK: call the C factory via
    // dlsym (variadic C function, fixed-argument signature is ABI-compatible
    // for the five fixed parameters we pass).
    typealias Factory = @convention(c) (UnsafeMutableRawPointer?, Int32, UInt32, Int32, Int32, Int32) -> CGEvent?
    let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
    guard let sym = dlsym(handle, "CGEventCreateScrollWheelEvent") else { return }
    let factory = unsafeBitCast(sym, to: Factory.self)
    if let e = factory(nil, 1, 1, Int32(dy), 0, 0) { e.post(tap: .cghidEventTap) }
}

// Absolute monotonic schedule. The demo's t=0 is the moment the recording
// says READY, so every action lands at the same source time every run.
let t0 = ProcessInfo.processInfo.systemUptime
func wait(until t: Double) {
    let d = t0 + t - ProcessInfo.processInfo.systemUptime
    if d > 0 { Thread.sleep(forTimeInterval: d) }
}

func activateSafari() {
    for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == "com.apple.Safari" {
        app.activate(options: [.activateIgnoringOtherApps])
    }
}

@main struct Drive {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("usage: drive demo | drive click x y | drive type s\n", stderr)
            exit(2)
        }
        switch args[1] {
        case "click":
            guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { exit(2) }
            glide(to: CGPoint(x: x, y: y)); click(CGPoint(x: x, y: y))
        case "type":
            guard args.count >= 3 else { exit(2) }
            type(String(args[2...].joined(separator: " ")))
        case "demo":
            runDemo()
        default: exit(2)
        }
    }

    // The 60 s scripted demo (plan §9c), timed from drive start.
    // Safari fixture points (locate-verified 2026-11-09):
    // input (320,174) · save (164,263) · open (164,326) · next (522,263)
    // far corner (1289,694) · nav Pricing (111,77) · scroll point (700,450)
    static func runDemo() {
        let input = CGPoint(x: 320, y: 174)
        let save  = CGPoint(x: 164, y: 263)
        let open  = CGPoint(x: 164, y: 326)
        let next  = CGPoint(x: 522, y: 263)
        let far   = CGPoint(x: 1289, y: 694)
        let nav   = CGPoint(x: 111, y: 77)
        activateSafari()

        // 0–6 s: wander with pauses + jitter, no clicks.
        wait(until: 0.2); glide(to: CGPoint(x: 500, y: 300), dur: 0.6)
        wait(until: 1.6); glide(to: CGPoint(x: 900, y: 250), dur: 0.6)
        wait(until: 3.0); glide(to: CGPoint(x: 600, y: 500), dur: 0.6)
        wait(until: 4.4); glide(to: CGPoint(x: 1100, y: 700), dur: 0.6)
        wait(until: 6.2)

        // 6–14 s: 4 clicks inside a ~500x300 pt region. First click at 7.0
        // keeps the 0–6 s hover-only span fully at 1.0x (leadIn 0.6).
        wait(until: 7.0); glide(to: save, dur: 0.35); click(save)
        wait(until: 8.0); glide(to: open, dur: 0.35); click(open)
        wait(until: 9.0); glide(to: next, dur: 0.35); click(next)
        wait(until: 10.0); glide(to: save, dur: 0.35); click(save)

        // 14–22 s: click the input, let the click marker fade, then type 28
        // characters. The marker must not overlap the typed line: that would
        // bias the pixel caret tracer.
        wait(until: 14.2); glide(to: input, dur: 0.35); click(input)
        wait(until: 17.5)
        type("lumen calibration 0123456789", gap: 120_000)

        // 22–28 s: 3 scrolls with no click; scrolls only keep the scene alive.
        wait(until: 21.4); glide(to: CGPoint(x: 700, y: 450), dur: 0.35)
        wait(until: 22.0); scroll(-6)
        wait(until: 24.0); scroll(-6)
        wait(until: 26.0); scroll(-6)

        // 28 s: far corner click (a PAN inside the first scene).
        wait(until: 28.3); glide(to: far, dur: 0.7); click(far)

        // 34–40 s: idle (the camera rests and zooms out).
        wait(until: 41.0)

        // 41 s: cmd+L, type example.com/pricing. NO click; this is the
        // no-click-anchor browser-chrome typing case.
        activateSafari()
        cmdKey(37)
        wait(until: 41.9)
        type("example.com/pricing", gap: 120_000)

        // 48 s: click a small button; 52 s: click a nav link.
        wait(until: 48.0); glide(to: save, dur: 0.5); click(save)
        wait(until: 52.0); glide(to: nav, dur: 0.5); click(nav)
        wait(until: 58.0)
        print("drive demo complete")
    }
}
