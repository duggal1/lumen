import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import os
import Synchronization
import LumenCore
import LumenProject

/// Single-producer/single-consumer ring. Producer = event tap thread, consumer = writer queue.
final class EventRing: @unchecked Sendable {
    private let buf: UnsafeMutablePointer<InputEvent>
    private let cap: Int
    private let head = Atomic<Int>(0), tail = Atomic<Int>(0)
    init(capacity: Int) { cap = capacity; buf = .allocate(capacity: capacity); buf.initialize(repeating: InputEvent(), count: capacity) }
    deinit { buf.deallocate() }
    func push(_ e: InputEvent) {
        let h = head.load(ordering: .relaxed)
        if h - tail.load(ordering: .acquiring) >= cap { return }
        buf[h % cap] = e
        head.store(h + 1, ordering: .releasing)
    }
    func drain(_ body: (InputEvent) -> Void) {
        let h = head.load(ordering: .acquiring)
        var t = tail.load(ordering: .relaxed)
        while t < h { body(buf[t % cap]); t += 1 }
        tail.store(t, ordering: .releasing)
    }
}

extension StockCursor {
    var ns: NSCursor {
        switch self {
        case .arrow: .arrow; case .iBeam: .iBeam; case .pointingHand: .pointingHand; case .crosshair: .crosshair
        case .openHand: .openHand; case .closedHand: .closedHand; case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown; case .notAllowed: .operationNotAllowed; case .contextMenu: .contextualMenu
        }
    }
}

/// Classifies NSCursor.currentSystem against stock cursors by bitmap hash. Main-actor only (AppKit).
@MainActor public final class CursorCatalog {
    private var stock: [Int: UInt16] = [:], custom: [Int: UInt16] = [:]
    public private(set) var customs: [(id: UInt16, png: Data, hotX: Double, hotY: Double)] = []
    public init() {
        for s in StockCursor.allCases { if let h = Self.hash(s.ns) { stock[h] = s.rawValue } }
    }
    static func hash(_ c: NSCursor) -> Int? { c.image.tiffRepresentation?.hashValue }
    public func classify() -> UInt16 {
        guard let c = NSCursor.currentSystem, let h = Self.hash(c) else { return 0 }
        if let s = stock[h] { return s }
        if let s = custom[h] { return s }
        let id = UInt16(1000 + customs.count)
        custom[h] = id
        if let tiff = c.image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            customs.append((id, png, c.hotSpot.x, c.hotSpot.y))
        }
        return id
    }
    public func writeJSON(to url: URL) {
        struct C: Codable { var id: UInt16; var png: Data; var hotX: Double; var hotY: Double }
        let arr = customs.map { C(id: $0.id, png: $0.png, hotX: $0.hotX, hotY: $0.hotY) }
        try? JSONEncoder().encode(arr).write(to: url)
    }
}

public enum ClockCalibration {
    /// Samples CGEvent.timestamp against mach ticks and uptime-ns; picks the closer unit. (Spike 1: verify on hardware.)
    public static func eventUnit() -> EventTimeUnit {
        guard let e = CGEvent(source: nil) else { return .machTicks }
        let ts = Double(e.timestamp), mach = Double(mach_absolute_time()), ns = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        return abs(ts - mach) / mach <= abs(ts - ns) / ns ? .machTicks : .nanoseconds
    }
}

/// Listen-only CGEventTap on its own high-QoS thread. Coordinates converted to source pixels once, here.
public final class InputRecorder: @unchecked Sendable {
    private let ring = EventRing(capacity: 1 << 16)
    private let url: URL, origin: CGPoint, scale: Double, clock: RecordingClock, axURL: URL
    private let shape = OSAllocatedUnfairLock<UInt16>(initialState: 0)
    private let loop = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)
    private let axFrames = OSAllocatedUnfairLock<[AXFrame]>(initialState: [])
    private var tap: CFMachPort?
    private var fh: FileHandle?
    private var timer: DispatchSourceTimer?
    private let writeQ = DispatchQueue(label: "lumen.events.write")
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let catalog: CursorCatalog

    @MainActor public init(url: URL, axURL: URL, origin: CGPoint, scale: Double, clock: RecordingClock) {
        self.url = url; self.axURL = axURL; self.origin = origin; self.scale = scale; self.clock = clock; catalog = CursorCatalog()
    }

    @MainActor public func start() throws {
        FileManager.default.createFile(atPath: url.path, contents: EventCodec.header())
        fh = try FileHandle(forWritingTo: url); try fh?.seekToEnd()
        running.withLock { $0 = true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon { Unmanaged<InputRecorder>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                                        callback: cb, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw CaptureError.writer("event tap denied (Input Monitoring)") }
        tap = t
        let th = Thread { [self] in
            guard let t = self.tap else { return }
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            loop.withLock { $0 = CFRunLoopGetCurrent() }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.qualityOfService = .userInteractive; th.start()
        let tm = DispatchSource.makeTimerSource(queue: writeQ)
        tm.schedule(deadline: .now() + 0.25, repeating: 0.25)
        tm.setEventHandler { [self] in flush() }
        tm.resume(); timer = tm
        Task { @MainActor [weak self] in           // cursor shape poll @ 30 Hz
            while let self, self.running.withLock({ $0 }) {
                let cursorShape = self.catalog.classify()
                self.shape.withLock { $0 = cursorShape }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    @MainActor public func stop() {
        running.withLock { $0 = false }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        loop.withLock { if let l = $0 { CFRunLoopStop(l) } }
        timer?.cancel()
        writeQ.sync { flush(); try? fh?.close() }
        catalog.writeJSON(to: url.deletingLastPathComponent().appendingPathComponent("cursors.json"))
        if let d = try? JSONEncoder().encode(axFrames.withLock { $0 }) { try? d.write(to: axURL) }
    }

    private func flush() {
        var b: [UInt8] = []
        ring.drain { EventCodec.encode($0, into: &b) }
        if !b.isEmpty { try? fh?.write(contentsOf: Data(b)) }
    }

    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        var ev = InputEvent(t: clock.hostSeconds(eventTimestamp: e.timestamp))
        let loc = e.location                                   // Quartz global space: already top-left origin
        ev.x = Float((loc.x - origin.x) * scale); ev.y = Float((loc.y - origin.y) * scale)
        ev.cursorShape = shape.withLock { $0 }
        ev.flags = UInt16(truncatingIfNeeded: e.flags.rawValue >> 16)
        switch type {
        case .mouseMoved: ev.kind = .move
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: ev.kind = .drag
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            ev.kind = .down; ev.button = UInt8(truncatingIfNeeded: e.getIntegerValueField(.mouseEventButtonNumber))
            ev.axFrameIndex = probeAX(loc)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            ev.kind = .up; ev.button = UInt8(truncatingIfNeeded: e.getIntegerValueField(.mouseEventButtonNumber))
        case .scrollWheel: ev.kind = .scroll
        case .keyDown:
            guard e.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            ev.kind = .keyDown; ev.keyCode = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))   // key codes only, never characters
        case .keyUp: ev.kind = .keyUp; ev.keyCode = UInt16(truncatingIfNeeded: e.getIntegerValueField(.keyboardEventKeycode))
        case .flagsChanged: ev.kind = .flagsChanged
        default: return
        }
        ring.push(ev)
    }

    /// Optional AX probe on mouse-down; 1-based index into ax.json, 0 = none.
    private func probeAX(_ p: CGPoint) -> UInt32 {
        guard AXIsProcessTrusted() else { return 0 }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.05)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, let el else { return 0 }
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success else { return 0 }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pos), AXValueGetValue(sv as! AXValue, .cgSize, &size) else { return 0 }
        let f = AXFrame(x: (pos.x - origin.x) * scale, y: (pos.y - origin.y) * scale, w: size.width * scale, h: size.height * scale)
        return axFrames.withLock { $0.append(f); return UInt32($0.count) }
    }
}
