// drive — CGEvent driver for the Lumen zoom scripted demo.
// Needs Accessibility + Input Monitoring. Posts to .cghidEventTap so
// Lumen's CGEventTap recorder sees every event.
// Build: swiftc -O -o Tools/Verify/drive Tools/Verify/drive.swift -framework CoreGraphics
import CoreGraphics
import Foundation

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

func returnKey() { key(36, flags: [], down: true); key(36, flags: [], down: false) }

func key(_ virtualKey: CGKeyCode, flags: CGEventFlags = [], down: Bool = true) {
    if let e = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: down) {
        e.flags = CGEventFlags(rawValue: flags.rawValue)
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

func sleepS(_ s: Double) { Thread.sleep(forTimeInterval: s) }

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
            glide(to: CGPoint(x: x, y: y))
            click(CGPoint(x: x, y: y))
        case "type":
            guard args.count >= 3 else { exit(2) }
            type(String(args[2...].joined(separator: " ")))
        case "demo":
            runDemo()
        default: exit(2)
        }
    }

    // The 60 s scripted demo (plan §9c), timed from drive start.
    // Points are absolute screen points, located by Tools/Verify/locate.
    static func runDemo() {
        let input = CGPoint(x: 320, y: 212)     // "type here" field
        let save = CGPoint(x: 164, y: 305)      // grid row 1
        let open = CGPoint(x: 164, y: 368)      // grid row 2
        let next = CGPoint(x: 522, y: 305)      // grid row 1, right
        let far = CGPoint(x: 1291, y: 703)      // far corner button
        // 0–6 s: wander with pauses + jitter, no clicks.
        for p in [CGPoint(x: 500, y: 300), CGPoint(x: 900, y: 250), CGPoint(x: 600, y: 500), CGPoint(x: 1100, y: 700)] {
            glide(to: p, dur: 0.6); sleepS(0.7)
        }
        sleepS(1.0)
        // 6–14 s: 4 clicks inside a ~500x300 region (grid rows 1–2).
        for p in [save, open, next, save] { glide(to: p, dur: 0.4); click(p); sleepS(0.8) }
        // 14–22 s: 30 chars into the input.
        glide(to: input, dur: 0.4); click(input); sleepS(0.3)
        type("lumen calibration 0123456789", gap: 120_000)
        // 22–28 s: scroll 3 times, no click.
        glide(to: CGPoint(x: 700, y: 450), dur: 0.4)
        for _ in 0..<3 { scroll(-6); sleepS(0.5) }
        // 28 s: far corner click (pan within the same scene).
        glide(to: far, dur: 0.7); click(far); sleepS(0.5)
        // 34–40 s: idle (zoom out).
        sleepS(6.0)
        // 41 s: cmd+L, type example.com/pricing, NO click.
        glide(to: CGPoint(x: 600, y: 200), dur: 0.3)
        cmdKey(37)   // L
        sleepS(0.8)
        type("example.com/pricing", gap: 120_000)
        // 48 s: click a small button; 52 s: click another nav-ish button.
        glide(to: save, dur: 0.6); click(save); sleepS(2.5)
        glide(to: next, dur: 0.6); click(next); sleepS(2.0)
        // 58 s: stop.
        print("drive demo complete")
    }
}
